const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const posix = std.posix;
const Environ = std.process.Environ;
const grpc = @import("grpc");
const network = @import("network");
const cd = @import("containerd.zig");
const image = @import("image.zig");
const oci = @import("oci.zig");
const plugin = @import("plugin.zig");

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

var stop_requested: std.atomic.Value(bool) = .init(false);
var stop_signal: std.atomic.Value(u8) = .init(0);

fn onSignal(sig: posix.SIG) callconv(.c) void {
    stop_signal.store(@intCast(@backingInt(sig)), .seq_cst);
    stop_requested.store(true, .seq_cst);
}

fn listen() void {
    const act: posix.Sigaction = .{ .handler = .{ .handler = onSignal }, .mask = posix.sigemptyset(), .flags = 0 };
    posix.sigaction(.TERM, &act, null);
    posix.sigaction(.INT, &act, null);
}

const user_agent: [2][]const u8 = .{ "user-agent", "orchd-rootstock-containerd" };

const sigterm: u32 = 15;
const sigkill: u32 = 9;

const Runner = struct {
    arena: Allocator,
    io: Io,
    environ: *const Environ.Map,
    spec: plugin.RunSpec,
    log: *Io.Writer,
    publisher: *?network.Publisher,

    fn say(r: Runner, comptime fmt: []const u8, args: anytype) void {
        r.log.print("containerd-run[{s}]: " ++ fmt ++ "\n", .{r.spec.container_id} ++ args) catch {};
        r.log.flush() catch {};
    }

    fn connect(r: Runner) !*grpc.Conn {
        return grpc.Conn.open(r.arena, r.io, r.spec.socket, &.{ .{ "containerd-namespace", r.spec.namespace }, user_agent });
    }

    fn call(r: Runner, conn: *grpc.Conn, step: []const u8, path: []const u8, request: []const u8, options: grpc.Options) ![]const u8 {
        return conn.unary(path, request, options) catch |err| {
            if (err == error.GrpcStatus) {
                r.say("{s}: {s} (code {d})", .{ step, conn.status.message, conn.status.code });
            } else if (err != error.Interrupted and err != error.Timeout) {
                r.say("{s}: {t}", .{ step, err });
            }
            return err;
        };
    }

    fn content(r: Runner, conn: *grpc.Conn, digest: []const u8) ![]const u8 {
        const chunks = conn.serverStream(cd.method.read_content, try cd.readContentRequest(r.arena, digest), .{}) catch |err| {
            if (err == error.GrpcStatus) r.say("content.read {s}: {s}", .{ digest, conn.status.message });
            return err;
        };
        var out: std.ArrayList(u8) = .empty;
        for (chunks) |chunk| try out.appendSlice(r.arena, try cd.readContentData(chunk));
        return out.items;
    }

    fn readImage(r: Runner, conn: *grpc.Conn) !image.Config {
        const a = r.arena;
        const target = try cd.parseGetImageResponse(try r.call(conn, "images.get", cd.method.get_image, try cd.getImageRequest(a, r.spec.image), .{}));
        const top = try image.parse(a, try r.content(conn, target.digest));
        const manifest = if (image.isIndex(top))
            try image.parse(a, try r.content(conn, image.manifestFromIndex(top, image.arch) orelse return error.NoManifest))
        else
            top;
        const config_digest = image.configDigest(manifest) orelse return error.NoConfig;
        return image.parseConfig(a, try image.parse(a, try r.content(conn, config_digest)));
    }

    fn processFor(r: Runner, config: image.Config) !oci.Process {
        const user_text = if (r.spec.user.len > 0) r.spec.user else config.user;
        const user = image.parseUser(user_text);
        if (user.named) r.say("USER '{s}' is a name; running as root (numeric uid[:gid] only)", .{user_text});
        return .{
            .args = try image.argv(r.arena, config, r.spec.entrypoint, r.spec.cmd),
            .env = try image.mergeEnv(r.arena, config.env, r.spec.env),
            .cwd = if (r.spec.cwd.len > 0) r.spec.cwd else if (config.working_dir.len > 0) config.working_dir else "/",
            .uid = user.uid,
            .gid = user.gid,
        };
    }

    fn stdio(r: Runner) ![2][]const u8 {
        const cwd = Io.Dir.cwd();
        try cwd.createDirPath(r.io, r.spec.fifo_dir);
        var paths: [2][]const u8 = undefined;
        for ([_][]const u8{ "stdout", "stderr" }, 0..) |name, i| {
            const path = try std.fs.path.joinZ(r.arena, &.{ r.spec.fifo_dir, name });
            cwd.deleteFile(r.io, path) catch {};
            if (mkfifo(path, 0o600) != 0) return error.FifoFailed;
            const thread = try std.Thread.spawn(.{}, copy, .{ path, @as(posix.fd_t, @intCast(i + 1)) });
            thread.detach();
            paths[i] = path;
        }
        return paths;
    }

    const definition_label = "orchd.definition";

    fn plant(r: Runner, conn: *grpc.Conn) ![]const cd.Mount {
        const a = r.arena;
        const id = r.spec.container_id;
        _ = try r.call(conn, "pull", cd.method.transfer, try cd.transferRequest(a, r.spec.image, image.arch, r.spec.snapshotter), .{ .interrupt = &stop_requested });
        const config = try r.readImage(conn);
        const chain = try image.chainId(a, config.diff_ids);
        const mounts = try cd.parsePrepareSnapshotResponse(a, try r.call(conn, "snapshots.prepare", cd.method.prepare_snapshot, try cd.prepareSnapshotRequest(a, r.spec.snapshotter, id, chain), .{}));
        const resolv = if (r.spec.host_network) try network.resolv.forHostNetwork(a, r.io) else try network.resolv.forOwnNetwork(a, r.io);
        const net: oci.Net = .{ .netns = if (r.spec.host_network) null else try r.netnsPath(), .resolv = resolv.path };
        const spec_json = try oci.json(a, id, try r.processFor(config), r.spec.mounts, r.spec.resources, net);
        const labels: []const [2][]const u8 = &.{.{ definition_label, r.spec.definition }};
        _ = try r.call(conn, "containers.create", cd.method.create_container, try cd.createContainerRequest(a, id, r.spec.image, spec_json, r.spec.snapshotter, r.spec.no_pivot_root, labels), .{});
        return mounts;
    }

    fn kept(r: Runner, conn: *grpc.Conn) !?[]const cd.Mount {
        const a = r.arena;
        const id = r.spec.container_id;
        const found = conn.unary(cd.method.get_container, try cd.getContainerRequest(a, id), .{ .timeout = .fromSeconds(10) }) catch |err| {
            if (err == error.GrpcStatus and conn.status.code == 5) return null;
            return err;
        };
        const container = try cd.parseGetContainerResponse(a, found);
        const definition = container.label(definition_label) orelse return null;
        if (!std.mem.eql(u8, definition, r.spec.definition)) {
            r.say("its definition changed; replanting", .{});
            return null;
        }
        const mounts = conn.unary(cd.method.snapshot_mounts, try cd.snapshotMountsRequest(a, r.spec.snapshotter, id), .{ .timeout = .fromSeconds(10) }) catch return null;
        return try cd.parsePrepareSnapshotResponse(a, mounts);
    }

    fn startTask(r: Runner, conn: *grpc.Conn, mounts: []const cd.Mount) !void {
        const a = r.arena;
        const id = r.spec.container_id;
        const out, const err = r.stdio() catch |e| blk: {
            r.say("no container output: {t}", .{e});
            break :blk .{ "", "" };
        };
        _ = try r.call(conn, "tasks.create", cd.method.create_task, try cd.createTaskRequest(a, id, mounts, out, err), .{});
        _ = try r.call(conn, "tasks.start", cd.method.start_task, try cd.startRequest(a, id), .{});
    }

    fn netnsPath(r: Runner) ![:0]const u8 {
        return network.netns.pathFor(r.arena, r.spec.container_id);
    }

    fn publish(r: Runner) !void {
        if (r.spec.ports.len == 0) return;
        var failure: ?network.Publisher.Failure = null;
        r.publisher.* = network.Publisher.bind(r.arena, r.io, r.spec.ports, &failure) catch |err| {
            if (failure) |f| r.say("PUBLISH {s}{s}{d}:{d}: {t}", .{ f.port.address, if (f.port.address.len > 0) ":" else "", f.port.host, f.port.container, f.err }) else r.say("PUBLISH: {t}", .{err});
            return err;
        };
    }

    fn unpublish(r: Runner) void {
        if (r.publisher.*) |*p| p.close(r.arena);
        r.publisher.* = null;
    }

    fn joinNetwork(r: Runner) ![]const u8 {
        const path = try r.netnsPath();
        r.leaveNetwork();
        network.netns.create(path) catch |err| {
            r.say("cannot make the tree's network namespace at {s}: {t}", .{ path, err });
            return err;
        };
        return network.cni.add(r.arena, r.io, r.environ, r.spec.cni_dirs, .{ .container_id = r.spec.container_id, .netns = path }) catch |err| {
            r.say("cni add on {s} (plugins in {s}): {t}", .{ network.cni.subnet, r.spec.cni_dirs, err });
            return err;
        };
    }

    fn leaveNetwork(r: Runner) void {
        if (r.spec.host_network) return;
        const path = r.netnsPath() catch return;
        network.cni.del(r.arena, r.io, r.environ, r.spec.cni_dirs, .{ .container_id = r.spec.container_id, .netns = path });
        network.netns.remove(path);
    }

    fn keep(r: Runner) !u8 {
        const a = r.arena;
        try r.publish();
        const conn = try r.connect();
        defer conn.close();
        const mounts = switch (r.spec.recreate) {
            .never => if (try r.kept(conn)) |m| blk: {
                r.clearTask();
                r.say("woke {s}, kept from its last run", .{r.spec.image});
                break :blk m;
            } else blk: {
                r.clearAll();
                break :blk try r.plant(conn);
            },
            .always => blk: {
                r.clearAll();
                break :blk try r.plant(conn);
            },
        };
        const ip = if (r.spec.host_network) "" else try r.joinNetwork();
        try r.startTask(conn, mounts);
        if (r.publisher.*) |*p| try p.serve(ip);
        r.say("started {s}{s}{s}", .{ r.spec.image, if (ip.len > 0) " at " else "", ip });
        const waited = try r.call(conn, "tasks.wait", cd.method.wait_task, try cd.waitRequest(a, r.spec.container_id), .{ .interrupt = &stop_requested });
        return @truncate(try cd.parseWaitResponse(waited));
    }

    fn settle(r: Runner) void {
        switch (r.spec.recreate) {
            .never => r.clearTask(),
            .always => r.clearAll(),
        }
    }

    fn clearTask(r: Runner) void {
        var conn = r.connect() catch return;
        defer conn.close();
        r.clearTaskOn(&conn);
        Io.Dir.cwd().deleteTree(r.io, r.spec.fifo_dir) catch {};
    }

    fn clearTaskOn(r: Runner, conn: **grpc.Conn) void {
        const a = r.arena;
        const id = r.spec.container_id;
        const had_task = if (cd.killRequest(a, id, sigterm)) |req| blk: {
            _ = conn.*.unary(cd.method.kill_task, req, .{ .timeout = .fromSeconds(5) }) catch break :blk false;
            break :blk true;
        } else |_| false;
        if (had_task) {
            const wait = cd.waitRequest(a, id) catch return;
            if (conn.*.unary(cd.method.wait_task, wait, .{ .timeout = .fromSeconds(5) })) |_| {} else |_| {
                conn.*.close();
                conn.* = r.connect() catch return;
                if (cd.killRequest(a, id, sigkill)) |req| _ = conn.*.unary(cd.method.kill_task, req, .{ .timeout = .fromSeconds(5) }) catch {} else |_| {}
                if (conn.*.unary(cd.method.wait_task, wait, .{ .timeout = .fromSeconds(2) })) |_| {} else |_| {
                    conn.*.close();
                    conn.* = r.connect() catch return;
                }
            }
        }
        if (cd.deleteTaskRequest(a, id)) |req| _ = conn.*.unary(cd.method.delete_task, req, .{ .timeout = .fromSeconds(10) }) catch {} else |_| {}
        r.leaveNetwork();
    }

    fn clearAll(r: Runner) void {
        const a = r.arena;
        const id = r.spec.container_id;
        var conn = r.connect() catch return;
        defer conn.close();
        r.clearTaskOn(&conn);
        if (cd.deleteContainerRequest(a, id)) |req| _ = conn.unary(cd.method.delete_container, req, .{ .timeout = .fromSeconds(10) }) catch {} else |_| {}
        if (cd.removeSnapshotRequest(a, r.spec.snapshotter, id)) |req| _ = conn.unary(cd.method.remove_snapshot, req, .{ .timeout = .fromSeconds(10) }) catch {} else |_| {}
        Io.Dir.cwd().deleteTree(r.io, r.spec.fifo_dir) catch {};
    }
};

fn copy(path: [:0]const u8, to: posix.fd_t) void {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = posix.read(fd, &buf) catch return;
        if (n == 0) return;
        var rest = buf[0..n];
        while (rest.len > 0) {
            const wrote = std.c.write(to, rest.ptr, rest.len);
            if (wrote <= 0) return;
            rest = rest[@intCast(wrote)..];
        }
    }
}

pub fn run(arena: Allocator, io: Io, environ: *const Environ.Map, spec: plugin.RunSpec, log: *Io.Writer) u8 {
    listen();
    var publisher: ?network.Publisher = null;
    const r: Runner = .{ .arena = arena, .io = io, .environ = environ, .spec = spec, .log = log, .publisher = &publisher };
    defer r.unpublish();
    const code = r.keep() catch |err| {
        r.unpublish();
        if (err == error.Interrupted) {
            const sig = stop_signal.load(.seq_cst);
            r.say("signal {d}, stopping", .{sig});
            r.settle();
            return 128 +| sig;
        }
        r.settle();
        return 1;
    };
    r.settle();
    return code;
}

pub fn remove(arena: Allocator, io: Io, environ: *const Environ.Map, spec: plugin.RunSpec, log: *Io.Writer) void {
    var publisher: ?network.Publisher = null;
    const r: Runner = .{ .arena = arena, .io = io, .environ = environ, .spec = spec, .log = log, .publisher = &publisher };
    r.clearAll();
}

pub fn version(arena: Allocator, io: Io, socket: []const u8) !cd.Version {
    const conn = try grpc.Conn.open(arena, io, socket, &.{ .{ "containerd-namespace", "default" }, user_agent });
    defer conn.close();
    return cd.parseVersionResponse(try conn.unary(cd.method.version, "", .{ .timeout = .fromSeconds(5) }));
}
