const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const posix = std.posix;
const testing = std.testing;
const types = @import("../types.zig");
const Config = @import("../config.zig").Config;
const supervise = @import("../supervise.zig");
const exe = @import("../exe.zig");
const Diagnostic = types.Diagnostic;

fn statePath(arena: Allocator, config: Config, parts: []const []const u8) ![]const u8 {
    var all: std.ArrayList([]const u8) = .empty;
    try all.append(arena, config.state_dir);
    try all.appendSlice(arena, parts);
    return std.fs.path.join(arena, all.items);
}

fn labelFile(arena: Allocator, config: Config, dir: []const []const u8, label: []const u8, ext: []const u8) ![]const u8 {
    const file = try std.fmt.allocPrint(arena, "{s}.{s}", .{ label, ext });
    var parts: std.ArrayList([]const u8) = .empty;
    try parts.appendSlice(arena, dir);
    try parts.append(arena, file);
    return statePath(arena, config, parts.items);
}

pub fn disabledSpecPath(arena: Allocator, config: Config, label: []const u8) ![]const u8 {
    return labelFile(arena, config, &.{ "supervise", "disabled" }, label, "json");
}

fn pidfile(arena: Allocator, config: Config, label: []const u8) ![]const u8 {
    return labelFile(arena, config, &.{"run"}, label, "pid");
}

fn logfile(arena: Allocator, config: Config, label: []const u8) ![]const u8 {
    return labelFile(arena, config, &.{"logs"}, label, "log");
}

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn specFor(arena: Allocator, io: Io, config: Config, label: []const u8) !?[]const u8 {
    const enabled = try supervise.superviseSpecPath(arena, config, label);
    if (exists(io, enabled)) return enabled;
    const disabled = try disabledSpecPath(arena, config, label);
    if (exists(io, disabled)) return disabled;
    return null;
}

fn readPid(arena: Allocator, io: Io, path: []const u8) ?posix.pid_t {
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64)) catch return null;
    return std.fmt.parseInt(posix.pid_t, std.mem.trim(u8, text, " \t\r\n"), 10) catch null;
}

fn alive(pid: posix.pid_t) bool {
    return std.c.kill(pid, @fromBackingInt(0)) == 0;
}

pub fn keeperPid(arena: Allocator, io: Io, config: Config, label: []const u8) !?posix.pid_t {
    const pid = readPid(arena, io, try pidfile(arena, config, label)) orelse return null;
    return if (alive(pid)) pid else null;
}

fn stems(arena: Allocator, io: Io, dir_path: []const u8, ext: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return out.items;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ext)) continue;
        try out.append(arena, try arena.dupe(u8, entry.name[0 .. entry.name.len - ext.len]));
    }
    std.mem.sort([]const u8, out.items, {}, lessThan);
    return out.items;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn labels(arena: Allocator, config: Config, names: []const []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, names.len);
    for (names, out) |name, *label| label.* = try supervise.serviceLabel(arena, config, name);
    return out;
}

pub fn generate(
    arena: Allocator,
    io: Io,
    config: Config,
    all: []const types.Service,
    planted: []const types.Planted,
) ![]const []const u8 {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, try statePath(arena, config, &.{ "supervise", "disabled" }));
    var written: std.ArrayList([]const u8) = .empty;
    for (planted) |p| {
        const label = try supervise.serviceLabel(arena, config, p.service.name);
        const deps = try supervise.buildDepGates(arena, config, p.service, all);
        const spec = try supervise.buildSuperviseSpec(arena, config, p.service, p.set, deps);
        const enabled = try supervise.superviseSpecPath(arena, config, label);
        const disabled = try disabledSpecPath(arena, config, label);
        const path, const other = if (p.service.disabled) .{ disabled, enabled } else .{ enabled, disabled };
        cwd.deleteFile(io, other) catch {};
        try cwd.writeFile(io, .{
            .sub_path = path,
            .data = try std.json.Stringify.valueAlloc(arena, spec, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }),
        });
        try written.append(arena, path);
    }
    return written.items;
}

pub fn clean(arena: Allocator, io: Io, config: Config) !void {
    stop(arena, io, config, &.{}) catch {};
    const cwd = Io.Dir.cwd();
    cwd.deleteTree(io, try statePath(arena, config, &.{"supervise"})) catch {};
    cwd.deleteTree(io, try statePath(arena, config, &.{"run"})) catch {};
}

pub fn remove(arena: Allocator, io: Io, config: Config, names: []const []const u8) !void {
    stop(arena, io, config, names) catch {};
    for (try labels(arena, config, names)) |label| {
        Io.Dir.cwd().deleteFile(io, try supervise.superviseSpecPath(arena, config, label)) catch {};
        Io.Dir.cwd().deleteFile(io, try disabledSpecPath(arena, config, label)) catch {};
    }
}

pub fn start(arena: Allocator, io: Io, config: Config, names: []const []const u8, diag: *Diagnostic) !void {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, try statePath(arena, config, &.{"run"}));
    try cwd.createDirPath(io, try statePath(arena, config, &.{"logs"}));
    const wanted = if (names.len == 0)
        try stems(arena, io, try statePath(arena, config, &.{"supervise"}), ".json")
    else
        try labels(arena, config, names);
    const self = exe.selfPath(arena, io);

    for (wanted) |label| {
        if (try keeperPid(arena, io, config, label) != null) continue;
        const spec = try specFor(arena, io, config, label) orelse {
            diag.set(arena, "no bed is planted for {s}", .{label});
            return error.NotPlanted;
        };
        const log = try cwd.createFile(io, try logfile(arena, config, label), .{});
        defer log.close(io);
        const keeper = std.process.spawn(io, .{
            .argv = &.{ self, "tend", "--spec", spec },
            .stdin = .ignore,
            .stdout = .{ .file = log },
            .stderr = .{ .file = log },
            .pgid = 0,
        }) catch |err| {
            diag.set(arena, "spawn keeper for {s}: {t}", .{ label, err });
            return error.SpawnFailed;
        };
        try cwd.writeFile(io, .{
            .sub_path = try pidfile(arena, config, label),
            .data = try std.fmt.allocPrint(arena, "{d}", .{keeper.id.?}),
        });
    }
}

pub fn stop(arena: Allocator, io: Io, config: Config, names: []const []const u8) !void {
    const Kept = struct { pidfile: []const u8, pid: posix.pid_t, deadline: Io.Timestamp };
    const wanted = if (names.len == 0)
        try stems(arena, io, try statePath(arena, config, &.{"run"}), ".pid")
    else
        try labels(arena, config, names);

    var kept: std.ArrayList(Kept) = .empty;
    for (wanted) |label| {
        const pf = try pidfile(arena, config, label);
        const pid = readPid(arena, io, pf) orelse {
            Io.Dir.cwd().deleteFile(io, pf) catch {};
            continue;
        };
        posix.kill(pid, .TERM) catch {};
        try kept.append(arena, .{ .pidfile = pf, .pid = pid, .deadline = Io.Timestamp.now(io, .awake).addDuration(try budget(arena, io, config, label)) });
    }
    for (kept.items) |k| {
        while (alive(k.pid) and Io.Timestamp.now(io, .awake).nanoseconds < k.deadline.nanoseconds) {
            try io.sleep(.fromMilliseconds(100), .awake);
        }
        if (alive(k.pid)) posix.kill(k.pid, .KILL) catch {};
        Io.Dir.cwd().deleteFile(io, k.pidfile) catch {};
    }
}

fn budget(arena: Allocator, io: Io, config: Config, label: []const u8) !Io.Duration {
    const secs: u32 = blk: {
        const path = try specFor(arena, io, config, label) orelse break :blk 30;
        const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch break :blk 30;
        const spec = std.json.parseFromSliceLeaky(supervise.SuperviseSpec, arena, bytes, .{ .ignore_unknown_fields = true }) catch break :blk 30;
        break :blk spec.stop_timeout_secs;
    };
    return .fromSeconds(secs + supervise.keeper_grace_secs);
}

pub fn status(arena: Allocator, io: Io, config: Config, w: *Io.Writer, as_json: bool) !void {
    const found = try stems(arena, io, try statePath(arena, config, &.{"run"}), ".pid");
    if (as_json) {
        try w.writeAll("[");
        for (found, 0..) |label, i| {
            const pid = readPid(arena, io, try pidfile(arena, config, label));
            if (i > 0) try w.writeAll(",");
            try w.print("{{\"label\":\"{s}\",\"pid\":{d},\"running\":{}}}", .{ label, pid orelse 0, if (pid) |p| alive(p) else false });
        }
        try w.writeAll("]\n");
        return;
    }
    if (found.len == 0) return w.writeAll("no orchdi services\n");
    for (found) |label| {
        const pid = readPid(arena, io, try pidfile(arena, config, label));
        var pid_buf: [16]u8 = undefined;
        const pid_text = if (pid) |p| try std.fmt.bufPrint(&pid_buf, "{d}", .{p}) else "-";
        try w.print("{s:<28} {s:<8} {s}\n", .{ label, pid_text, if (pid != null and alive(pid.?)) "running" else "stopped" });
    }
}

pub fn logs(arena: Allocator, io: Io, config: Config, service: []const u8, follow: bool, lines: u32) !void {
    const label = try supervise.serviceLabel(arena, config, service);
    const n = try std.fmt.allocPrint(arena, "{d}", .{lines});
    const log = try logfile(arena, config, label);
    var child = try std.process.spawn(io, .{
        .argv = if (follow) &.{ "tail", "-n", n, "-f", log } else &.{ "tail", "-n", n, log },
    });
    _ = try child.wait(io);
}

test "a tree with no bed is refused, not started" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var config = @import("../config.zig").forTest(try tmp.dir.realPathFileAlloc(testing.io, ".", a));
    config.grove = "unplanted";
    var diag: Diagnostic = .{};
    try testing.expectError(error.NotPlanted, start(a, testing.io, config, &.{"pg"}, &diag));
    try testing.expectEqualStrings("no bed is planted for unplanted.pg", diag.message);
    try testing.expectEqual(null, try keeperPid(a, testing.io, config, "unplanted.pg"));
    try testing.expect(!exists(testing.io, try pidfile(a, config, "unplanted.pg")));
}

test "enabled trees are planted in supervise, disabled ones aside, and a bed moves when that changes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const config = @import("../config.zig").forTest(try tmp.dir.realPathFileAlloc(testing.io, ".", a));
    const web: types.Service = .{ .name = "web", .mode = .host, .run_command = "sleep 1" };
    var off = web;
    off.name = "off";
    off.disabled = true;
    const all = [_]types.Service{ web, off };
    const written = try generate(a, testing.io, config, &all, &.{ .{ .service = web, .set = .{ .start = "sleep 1" } }, .{ .service = off, .set = .{ .start = "sleep 2" } } });
    try testing.expectEqual(2, written.len);
    try testing.expect(exists(testing.io, try supervise.superviseSpecPath(a, config, "orch.web")));
    try testing.expect(exists(testing.io, try disabledSpecPath(a, config, "orch.off")));

    var on = off;
    on.disabled = false;
    _ = try generate(a, testing.io, config, &.{ web, on }, &.{.{ .service = on, .set = .{ .start = "sleep 2" } }});
    try testing.expect(exists(testing.io, try supervise.superviseSpecPath(a, config, "orch.off")));
    try testing.expect(!exists(testing.io, try disabledSpecPath(a, config, "orch.off")));

    const bytes = try tmp.dir.readFileAlloc(testing.io, "supervise/orch.web.json", a, .limited(1 << 16));
    const spec = try std.json.parseFromSliceLeaky(supervise.SuperviseSpec, a, bytes, .{});
    try testing.expectEqualStrings("orch.web", spec.label);
    try testing.expectEqual(10, spec.stop_timeout_secs);
}
