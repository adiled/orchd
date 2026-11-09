const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const posix = std.posix;
const testing = std.testing;
const types = @import("types.zig");
const supervise = @import("supervise.zig");
const SuperviseSpec = supervise.SuperviseSpec;

var term_requested: std.atomic.Value(bool) = .init(false);
var hup_requested: std.atomic.Value(bool) = .init(false);

fn onTerm(_: posix.SIG) callconv(.c) void {
    term_requested.store(true, .seq_cst);
}

fn onHup(_: posix.SIG) callconv(.c) void {
    hup_requested.store(true, .seq_cst);
}

fn listen() void {
    const term: posix.Sigaction = .{ .handler = .{ .handler = onTerm }, .mask = posix.sigemptyset(), .flags = 0 };
    const hup: posix.Sigaction = .{ .handler = .{ .handler = onHup }, .mask = posix.sigemptyset(), .flags = 0 };
    posix.sigaction(.TERM, &term, null);
    posix.sigaction(.INT, &term, null);
    posix.sigaction(.HUP, &hup, null);
}

const poll_interval: Io.Duration = .fromMilliseconds(100);
const gate_interval: Io.Duration = .fromSeconds(2);

const Keeper = struct {
    arena: Allocator,
    io: Io,
    environ: *const Environ.Map,
    spec: SuperviseSpec,
    log: *Io.Writer,

    fn say(k: Keeper, comptime fmt: []const u8, args: anytype) void {
        k.log.print("supervise[{s}]: " ++ fmt ++ "\n", .{k.spec.label} ++ args) catch {};
        k.log.flush() catch {};
    }

    fn treeEnviron(k: Keeper) !?*Environ.Map {
        const env = k.spec.env orelse return null;
        const map = try k.arena.create(Environ.Map);
        map.* = try k.environ.clone(k.arena);
        for (env.map.keys(), env.map.values()) |key, value| try map.put(key, value);
        return map;
    }

    fn waitGate(k: Keeper, gate: supervise.DepSpec) bool {
        const deadline = Io.Timestamp.now(k.io, .awake).addDuration(.fromSeconds(gate.timeout_secs));
        while (true) {
            if (shell(k.io, gate.poll_cmd, null, null)) return true;
            if (Io.Timestamp.now(k.io, .awake).nanoseconds >= deadline.nanoseconds) return false;
            k.io.sleep(gate_interval, .awake) catch return false;
        }
    }

    fn runOptional(k: Keeper, cmd: ?[]const u8) void {
        if (cmd) |c| _ = shell(k.io, c, null, null);
    }

    fn reload(k: Keeper, pid: posix.pid_t) void {
        const cmd = k.spec.reload orelse return k.say("SIGHUP, but the service has no RELOAD", .{});
        var diag: types.Diagnostic = .{};
        runReload(k.arena, k.io, k.environ, cmd, pid, k.spec.env, k.spec.workdir, &diag) catch
            return k.say("{s}", .{diag.message});
        k.say("reloaded", .{});
    }

    fn teardown(k: Keeper, pid: posix.pid_t) bool {
        if (k.spec.stop) |stop| {
            _ = shell(k.io, stop, null, null);
        } else {
            signalGroup(pid, .TERM);
        }
        const budget: i64 = @max(k.spec.stop_timeout_secs, 1);
        const deadline = Io.Timestamp.now(k.io, .awake).addDuration(.fromSeconds(budget));
        var child_gone = false;
        const graceful = while (true) {
            if (!child_gone and exited(pid) != null) child_gone = true;
            if (child_gone and !groupAlive(pid)) break true;
            if (Io.Timestamp.now(k.io, .awake).nanoseconds >= deadline.nanoseconds) {
                signalGroup(pid, .KILL);
                if (!child_gone) _ = reap(pid);
                break false;
            }
            k.io.sleep(poll_interval, .awake) catch {};
        };
        k.runOptional(k.spec.post_stop);
        return graceful;
    }

    fn markReady(k: Keeper, code: u8) void {
        const marker = k.spec.ready_marker orelse return;
        const cwd = Io.Dir.cwd();
        if (code != 0) {
            cwd.deleteFile(k.io, marker) catch {};
            return;
        }
        if (std.fs.path.dirname(marker)) |dir| cwd.createDirPath(k.io, dir) catch {};
        cwd.writeFile(k.io, .{ .sub_path = marker, .data = "" }) catch {};
    }

    fn keep(k: Keeper) u8 {
        for (k.spec.deps) |gate| {
            if (k.waitGate(gate)) continue;
            if (gate.required) {
                k.say("required dependency not ready: {s}", .{gate.poll_cmd});
                return 1;
            }
            k.say("dependency not ready (proceeding): {s}", .{gate.poll_cmd});
        }
        if (k.spec.pre_start) |pre| {
            if (!shell(k.io, pre, null, null)) {
                k.say("pre_start failed: {s}", .{pre});
                return 1;
            }
        }

        listen();
        const tree_environ = k.treeEnviron() catch |err| {
            k.say("failed to start: {t}", .{err});
            return 1;
        };
        const child = std.process.spawn(k.io, .{
            .argv = &.{ "/bin/sh", "-c", k.spec.start },
            .environ_map = tree_environ,
            .cwd = if (k.spec.workdir) |w| .{ .path = w } else .inherit,
            .pgid = 0,
        }) catch |err| {
            k.say("failed to start: {t}", .{err});
            return 1;
        };
        const pid = child.id.?;

        while (true) {
            if (term_requested.load(.seq_cst)) {
                if (k.teardown(pid)) return 0;
                k.say("did not exit within {d}s; killed", .{k.spec.stop_timeout_secs});
                return 1;
            }
            if (hup_requested.swap(false, .seq_cst)) k.reload(pid);
            if (exited(pid)) |code| {
                k.runOptional(k.spec.post_stop);
                k.markReady(code);
                return code;
            }
            k.io.sleep(poll_interval, .awake) catch {};
        }
    }
};

pub fn run(arena: Allocator, io: Io, environ: *const Environ.Map, spec_path: []const u8, log: *Io.Writer) u8 {
    const bytes = Io.Dir.cwd().readFileAlloc(io, spec_path, arena, .limited(1 << 20)) catch |err| {
        log.print("supervise: cannot read spec {s}: {t}\n", .{ spec_path, err }) catch {};
        log.flush() catch {};
        return 1;
    };
    const spec = std.json.parseFromSliceLeaky(SuperviseSpec, arena, bytes, .{ .ignore_unknown_fields = true }) catch |err| {
        log.print("supervise: invalid spec {s}: {t}\n", .{ spec_path, err }) catch {};
        log.flush() catch {};
        return 1;
    };
    const keeper: Keeper = .{ .arena = arena, .io = io, .environ = environ, .spec = spec, .log = log };
    return keeper.keep();
}

pub fn runReload(
    arena: Allocator,
    io: Io,
    environ: *const Environ.Map,
    cmd: []const u8,
    main_pid: posix.pid_t,
    env: ?types.Env,
    workdir: ?[]const u8,
    diag: *types.Diagnostic,
) !void {
    var map = try environ.clone(arena);
    if (env) |e| {
        for (e.map.keys(), e.map.values()) |key, value| try map.put(key, value);
    }
    try map.put("MAINPID", try std.fmt.allocPrint(arena, "{d}", .{main_pid}));
    var child = std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", cmd },
        .environ_map = &map,
        .cwd = if (workdir) |w| .{ .path = w } else .inherit,
    }) catch |err| {
        diag.set(arena, "RELOAD could not run: {t}", .{err});
        return error.ReloadFailed;
    };
    const term = child.wait(io) catch |err| {
        diag.set(arena, "RELOAD could not run: {t}", .{err});
        return error.ReloadFailed;
    };
    switch (term) {
        .exited => |code| if (code != 0) {
            diag.set(arena, "RELOAD exited {d}", .{code});
            return error.ReloadFailed;
        },
        else => {
            diag.set(arena, "RELOAD exited -1", .{});
            return error.ReloadFailed;
        },
    }
}

fn shell(io: Io, cmd: []const u8, environ: ?*const Environ.Map, workdir: ?[]const u8) bool {
    var child = std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", cmd },
        .environ_map = environ,
        .cwd = if (workdir) |w| .{ .path = w } else .inherit,
    }) catch return false;
    const term = child.wait(io) catch return false;
    return term.success();
}

fn signalGroup(pgid: posix.pid_t, sig: posix.SIG) void {
    posix.kill(-pgid, sig) catch {};
}

fn groupAlive(pgid: posix.pid_t) bool {
    return std.c.kill(-pgid, @fromBackingInt(0)) == 0;
}

fn exited(pid: posix.pid_t) ?u8 {
    var status: c_int = 0;
    if (std.c.waitpid(pid, &status, std.c.W.NOHANG) != pid) return null;
    return exitCode(@bitCast(status));
}

fn reap(pid: posix.pid_t) ?u8 {
    var status: c_int = 0;
    if (std.c.waitpid(pid, &status, 0) != pid) return null;
    return exitCode(@bitCast(status));
}

fn exitCode(status: u32) u8 {
    if (std.c.W.IFEXITED(status)) return std.c.W.EXITSTATUS(status);
    return 128 +| @as(u8, @intCast(@backingInt(std.c.W.TERMSIG(status)) & 0x7f));
}

test "exit codes are the child's own, or 128 plus the signal that ended it" {
    try testing.expectEqual(0, exitCode(0));
    try testing.expectEqual(3, exitCode(3 << 8));
    try testing.expectEqual(128 + 9, exitCode(9));
    try testing.expectEqual(128 + 15, exitCode(15));
}

test "a reload runs with MAINPID, the service's env and its workdir" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);

    var environ: Environ.Map = .init(a);
    try environ.put("PATH", "/usr/bin:/bin");
    var env: types.Env = .{};
    try env.map.put(a, "GREETING", "hello");
    var diag: types.Diagnostic = .{};
    try runReload(a, testing.io, &environ, "echo \"$MAINPID $GREETING $(pwd -P)\" > seen", 4242, env, dir, &diag);

    const seen = try tmp.dir.readFileAlloc(testing.io, "seen", a, .limited(1024));
    const want = try std.fmt.allocPrint(a, "4242 hello {s}\n", .{dir});
    try testing.expectEqualStrings(want, seen);
}

test "a failing reload says how it exited" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var environ: Environ.Map = .init(arena.allocator());
    var diag: types.Diagnostic = .{};
    try testing.expectError(error.ReloadFailed, runReload(arena.allocator(), testing.io, &environ, "exit 7", 1, null, null, &diag));
    try testing.expectEqualStrings("RELOAD exited 7", diag.message);
}
