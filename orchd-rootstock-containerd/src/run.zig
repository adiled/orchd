const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const posix = std.posix;
const grpc = @import("grpc.zig");
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

const sigterm: u32 = 15;
const sigkill: u32 = 9;

const Runner = struct {
    arena: Allocator,
    io: Io,
    spec: plugin.RunSpec,
    log: *Io.Writer,

    fn say(r: Runner, comptime fmt: []const u8, args: anytype) void {
        r.log.print("containerd-run[{s}]: " ++ fmt ++ "\n", .{r.spec.container_id} ++ args) catch {};
        r.log.flush() catch {};
    }

    fn connect(r: Runner) !*grpc.Conn {
        return grpc.Conn.open(r.arena, r.io, r.spec.socket, r.spec.namespace);
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

    fn create(r: Runner, conn: *grpc.Conn) !void {
        const a = r.arena;
        const id = r.spec.container_id;
        const config = try r.readImage(conn);
        const chain = try image.chainId(a, config.diff_ids);
        const mounts = try cd.parsePrepareSnapshotResponse(a, try r.call(conn, "snapshots.prepare", cd.method.prepare_snapshot, try cd.prepareSnapshotRequest(a, r.spec.snapshotter, id, chain), .{}));
        const spec_json = try oci.json(a, id, try r.processFor(config), r.spec.mounts, r.spec.resources);
        _ = try r.call(conn, "containers.create", cd.method.create_container, try cd.createContainerRequest(a, id, r.spec.image, spec_json, r.spec.snapshotter, r.spec.no_pivot_root), .{});
        const out, const err = r.stdio() catch |e| blk: {
            r.say("no container output: {t}", .{e});
            break :blk .{ "", "" };
        };
        _ = try r.call(conn, "tasks.create", cd.method.create_task, try cd.createTaskRequest(a, id, mounts, out, err), .{});
        _ = try r.call(conn, "tasks.start", cd.method.start_task, try cd.startRequest(a, id), .{});
    }

    fn keep(r: Runner) !u8 {
        const a = r.arena;
        const conn = try r.connect();
        defer conn.close();
        _ = try r.call(conn, "pull", cd.method.transfer, try cd.transferRequest(a, r.spec.image, image.arch, r.spec.snapshotter), .{ .interrupt = &stop_requested });
        try r.create(conn);
        r.say("started {s}", .{r.spec.image});
        const waited = try r.call(conn, "tasks.wait", cd.method.wait_task, try cd.waitRequest(a, r.spec.container_id), .{ .interrupt = &stop_requested });
        return @truncate(try cd.parseWaitResponse(waited));
    }

    fn teardown(r: Runner) void {
        const a = r.arena;
        const id = r.spec.container_id;
        var conn = r.connect() catch return;
        defer conn.close();
        const had_task = if (cd.killRequest(a, id, sigterm)) |req| blk: {
            _ = conn.unary(cd.method.kill_task, req, .{ .timeout = .fromSeconds(5) }) catch break :blk false;
            break :blk true;
        } else |_| false;
        if (had_task) {
            const wait = cd.waitRequest(a, id) catch return;
            if (conn.unary(cd.method.wait_task, wait, .{ .timeout = .fromSeconds(8) })) |_| {} else |_| {
                conn.close();
                conn = r.connect() catch return;
                if (cd.killRequest(a, id, sigkill)) |req| _ = conn.unary(cd.method.kill_task, req, .{ .timeout = .fromSeconds(5) }) catch {} else |_| {}
                if (conn.unary(cd.method.wait_task, wait, .{ .timeout = .fromSeconds(3) })) |_| {} else |_| {
                    conn.close();
                    conn = r.connect() catch return;
                }
            }
        }
        if (cd.deleteTaskRequest(a, id)) |req| _ = conn.unary(cd.method.delete_task, req, .{ .timeout = .fromSeconds(10) }) catch {} else |_| {}
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

pub fn run(arena: Allocator, io: Io, spec: plugin.RunSpec, log: *Io.Writer) u8 {
    listen();
    const r: Runner = .{ .arena = arena, .io = io, .spec = spec, .log = log };
    r.teardown();
    const code = r.keep() catch |err| {
        if (err == error.Interrupted) {
            const sig = stop_signal.load(.seq_cst);
            r.say("signal {d}, stopping", .{sig});
            r.teardown();
            return 128 +| sig;
        }
        r.teardown();
        return 1;
    };
    r.teardown();
    return code;
}

pub fn version(arena: Allocator, io: Io, socket: []const u8) !cd.Version {
    const conn = try grpc.Conn.open(arena, io, socket, "default");
    defer conn.close();
    return cd.parseVersionResponse(try conn.unary(cd.method.version, "", .{ .timeout = .fromSeconds(5) }));
}
