const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const posix = std.posix;
const grpc = @import("grpc");
const publish = @import("publish");
const cri = @import("cri.zig");
const log = @import("log.zig");
const plugin = @import("plugin.zig");

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

const metadata = [_][2][]const u8{.{ "user-agent", "orchd-rootstock-cri" }};
const tick: Io.Duration = .fromMilliseconds(200);
const ticks_per_poll = 5;
const not_found: u32 = 5;

const Runner = struct {
    arena: Allocator,
    io: Io,
    spec: plugin.RunSpec,
    err: *Io.Writer,
    scratch: std.heap.ArenaAllocator,
    publisher: ?publish.Publisher = null,

    fn say(r: *Runner, comptime fmt: []const u8, args: anytype) void {
        r.err.print("cri-run[{s}]: " ++ fmt ++ "\n", .{r.spec.pod} ++ args) catch {};
        r.err.flush() catch {};
    }

    fn connect(r: *Runner, arena: Allocator) !*grpc.Conn {
        return grpc.Conn.open(arena, r.io, r.spec.endpoint, &metadata) catch |err| {
            r.say("cannot reach the runtime at {s}: {t}", .{ r.spec.endpoint, err });
            return err;
        };
    }

    fn fresh(r: *Runner) !*grpc.Conn {
        _ = r.scratch.reset(.retain_capacity);
        return r.connect(r.scratch.allocator());
    }

    fn call(r: *Runner, conn: *grpc.Conn, step: []const u8, path: []const u8, request: []const u8, options: grpc.Options) ![]const u8 {
        return conn.unary(path, request, options) catch |err| {
            if (err == error.GrpcStatus) {
                r.say("{s}: {s} (code {d})", .{ step, conn.status.message, conn.status.code });
            } else if (err != error.Interrupted) {
                r.say("{s}: {t}", .{ step, err });
            }
            return err;
        };
    }

    fn grow(r: *Runner) !u8 {
        const a = r.arena;
        const spec = r.spec;
        const conn = try r.connect(a);
        defer conn.close();
        r.sweepOn(conn);

        const interruptible: grpc.Options = .{ .interrupt = &stop_requested };
        const image = try cri.imageRequest(a, spec.image);
        if (!try cri.imagePresent(try r.call(conn, "image status", cri.method.image_status, image, interruptible))) {
            r.say("pulling {s}", .{spec.image});
            _ = try r.call(conn, "pull", cri.method.pull_image, image, interruptible);
        }

        if (spec.ports.len > 0) {
            var failure: ?publish.Publisher.Failure = null;
            r.publisher = publish.Publisher.bind(a, r.io, spec.ports, &failure) catch |err| {
                if (failure) |f| r.say("PUBLISH {s}{s}{d}:{d}: {t}", .{ f.port.address, if (f.port.address.len > 0) ":" else "", f.port.host, f.port.container, f.err }) else r.say("PUBLISH: {t}", .{err});
                return err;
            };
        }
        try Io.Dir.cwd().createDirPath(r.io, spec.log_dir);
        const labels = spec.labels();
        const sandbox = try cri.podSandboxConfig(a, .{
            .name = spec.pod,
            .namespace = spec.grove,
            .log_directory = spec.log_dir,
            .hostname = spec.service,
            .host_network = spec.host_network,
            .labels = &labels,
            .dns = try r.dns(),
        });
        const pod_id = try cri.parseId(try r.call(conn, "run pod", cri.method.run_pod, try cri.runPodSandboxRequest(a, sandbox), interruptible));
        const created = try r.call(conn, "create", cri.method.create_container, try cri.createContainerRequest(a, pod_id, try spec.container(a), sandbox), interruptible);
        const container_id = try cri.parseId(created);
        _ = try r.call(conn, "start", cri.method.start_container, try cri.containerRequest(a, container_id), interruptible);
        if (r.publisher) |*publisher| {
            const ip = try cri.parsePodIp(try r.call(conn, "pod status", cri.method.pod_status, try cri.podRequest(a, pod_id), interruptible));
            if (ip.len == 0) {
                r.say("the pod has no IP to publish to", .{});
                return error.NoPodIp;
            }
            try publisher.serve(ip);
        }
        return r.follow(container_id);
    }

    fn dns(r: *Runner) !cri.Dns {
        const read = struct {
            fn read(io: Io, arena: Allocator, path: []const u8) !cri.Dns {
                return cri.parseResolvConf(arena, Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 10)) catch "");
            }
        }.read;
        const host = try read(r.io, r.arena, "/etc/resolv.conf");
        if (r.spec.host_network or !cri.onlyLoopback(host)) return host;
        const upstream = try read(r.io, r.arena, "/run/systemd/resolve/resolv.conf");
        return if (upstream.servers.len > 0 and !cri.onlyLoopback(upstream)) upstream else host;
    }

    fn follow(r: *Runner, container_id: []const u8) !u8 {
        const path = try std.fmt.allocPrintSentinel(r.arena, "{s}/{s}", .{ r.spec.log_dir, try plugin.logName(r.arena, r.spec) }, 0);
        var tail: log.Tail = .{ .path = path };
        defer tail.close();
        var stopping = false;
        var ticks: usize = 0;
        while (true) : (ticks += 1) {
            tail.pump(posix.STDOUT_FILENO, posix.STDERR_FILENO);
            if (!stopping and stop_requested.load(.seq_cst)) {
                stopping = true;
                r.stopContainer(container_id);
            }
            if (stopping or ticks % ticks_per_poll == 0) {
                if (r.status(container_id)) |got| {
                    if (got.state == .exited) {
                        tail.pump(posix.STDOUT_FILENO, posix.STDERR_FILENO);
                        if (stopping) return error.Interrupted;
                        if (got.exit_code != 0) r.say("exited {d}{s}{s}", .{ got.exit_code, if (got.reason.len > 0) ": " else "", got.reason });
                        return @truncate(@as(u32, @bitCast(got.exit_code)));
                    }
                } else |err| if (err == error.Gone) return 1;
            }
            r.io.sleep(tick, .awake) catch {};
        }
    }

    fn status(r: *Runner, container_id: []const u8) !cri.Status {
        const conn = try r.fresh();
        defer conn.close();
        const reply = conn.unary(cri.method.container_status, try cri.containerRequest(r.scratch.allocator(), container_id), .{ .timeout = .fromSeconds(10) }) catch |err| {
            if (err == error.GrpcStatus and conn.status.code == not_found) {
                r.say("the container is gone from the runtime", .{});
                return error.Gone;
            }
            return err;
        };
        return cri.parseContainerStatus(reply);
    }

    fn stopContainer(r: *Runner, container_id: []const u8) void {
        const conn = r.fresh() catch return;
        defer conn.close();
        const request = cri.stopContainerRequest(r.scratch.allocator(), container_id, plugin.stop_timeout_s) catch return;
        _ = r.call(conn, "stop", cri.method.stop_container, request, .{ .timeout = .fromSeconds(plugin.stop_timeout_s + 5) }) catch {};
    }

    fn sweepOn(r: *Runner, conn: *grpc.Conn) void {
        const a = r.scratch.allocator();
        const labels = r.spec.labels();
        const request = cri.listPodSandboxRequest(a, &labels) catch return;
        const reply = conn.unary(cri.method.list_pods, request, .{ .timeout = .fromSeconds(10) }) catch return;
        const ids = cri.parsePodIds(a, reply) catch return;
        for (ids) |id| {
            const pod = cri.podRequest(a, id) catch continue;
            _ = r.call(conn, "stop pod", cri.method.stop_pod, pod, .{ .timeout = .fromSeconds(10) }) catch {};
            _ = r.call(conn, "remove pod", cri.method.remove_pod, pod, .{ .timeout = .fromSeconds(10) }) catch {};
        }
    }

    fn teardown(r: *Runner) void {
        if (r.publisher) |*publisher| publisher.close(r.arena);
        r.publisher = null;
        const conn = r.fresh() catch return;
        defer conn.close();
        r.sweepOn(conn);
        Io.Dir.cwd().deleteTree(r.io, r.spec.log_dir) catch {};
    }
};

pub fn run(arena: Allocator, io: Io, spec: plugin.RunSpec, err: *Io.Writer) u8 {
    listen();
    var r: Runner = .{ .arena = arena, .io = io, .spec = spec, .err = err, .scratch = .init(std.heap.page_allocator) };
    defer r.scratch.deinit();
    const code = r.grow() catch |e| {
        r.teardown();
        if (e == error.Interrupted) {
            const sig = stop_signal.load(.seq_cst);
            r.say("signal {d}, stopped", .{sig});
            return 128 +| sig;
        }
        return 1;
    };
    r.teardown();
    return code;
}

pub fn remove(arena: Allocator, io: Io, spec: plugin.RunSpec, err: *Io.Writer) void {
    var r: Runner = .{ .arena = arena, .io = io, .spec = spec, .err = err, .scratch = .init(std.heap.page_allocator) };
    defer r.scratch.deinit();
    r.teardown();
}

pub fn speaksCri(arena: Allocator, io: Io, endpoint: []const u8) bool {
    const conn = grpc.Conn.open(arena, io, endpoint, &metadata) catch return false;
    defer conn.close();
    _ = conn.unary(cri.method.version, "", .{ .timeout = .fromSeconds(2) }) catch return false;
    return true;
}

pub fn findEndpoint(arena: Allocator, io: Io, configured: ?[]const u8) ![]const u8 {
    if (configured) |value| if (value.len > 0) return plugin.endpointPath(value);
    for (plugin.default_endpoints) |path| {
        Io.Dir.cwd().access(io, path, .{}) catch continue;
        if (speaksCri(arena, io, path)) return path;
    }
    return error.NoEndpoint;
}

pub const Health = struct {
    version: cri.Version,
    readiness: cri.Readiness,
};

pub fn check(arena: Allocator, io: Io, endpoint: []const u8) !Health {
    const conn = try grpc.Conn.open(arena, io, endpoint, &metadata);
    defer conn.close();
    const version = try cri.parseVersion(try conn.unary(cri.method.version, "", .{ .timeout = .fromSeconds(5) }));
    const readiness = try cri.parseReadiness(try conn.unary(cri.method.status, "", .{ .timeout = .fromSeconds(5) }));
    return .{ .version = version, .readiness = readiness };
}
