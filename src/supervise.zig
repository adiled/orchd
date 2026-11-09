const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const types = @import("types.zig");
const Config = @import("config.zig").Config;
const Service = types.Service;
const ExecSet = types.ExecSet;
const Env = types.Env;

pub const keeper_grace_secs: u32 = 10;

pub const DepSpec = struct {
    poll_cmd: []const u8,
    timeout_secs: u32,
    required: bool,
};

pub const SuperviseSpec = struct {
    label: []const u8,
    pre_start: ?[]const u8 = null,
    start: []const u8,
    stop: ?[]const u8 = null,
    post_stop: ?[]const u8 = null,
    reload: ?[]const u8 = null,
    deps: []const DepSpec = &.{},
    ready_marker: ?[]const u8 = null,
    stop_timeout_secs: u32,
    env: ?Env = null,
    workdir: ?[]const u8 = null,
};

pub fn needsKeeper(deps: []const DepSpec, set: ExecSet) bool {
    return deps.len > 0 or set.stop != null or set.post_stop != null;
}

pub fn serviceLabel(arena: Allocator, config: Config, service_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ config.grove, service_name });
}

pub fn superviseSpecPath(arena: Allocator, config: Config, label: []const u8) ![]const u8 {
    const file = try std.fmt.allocPrint(arena, "{s}.json", .{label});
    return std.fs.path.join(arena, &.{ config.state_dir, "supervise", file });
}

pub fn readyMarkerPath(arena: Allocator, config: Config, service_name: []const u8) ![]const u8 {
    const file = try std.fmt.allocPrint(arena, "{s}.{s}.ready", .{ config.grove, service_name });
    return std.fs.path.join(arena, &.{ config.state_dir, "ready", file });
}

pub fn parseDurationSecs(s: []const u8) ?u32 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (std.mem.endsWith(u8, t, "s")) {
        return std.fmt.parseInt(u32, t[0 .. t.len - 1], 10) catch null;
    }
    if (std.mem.endsWith(u8, t, "m")) {
        const minutes = std.fmt.parseInt(u32, t[0 .. t.len - 1], 10) catch return null;
        return std.math.mul(u32, minutes, 60) catch null;
    }
    return null;
}

pub fn parseMemoryBytes(s: []const u8) ?u64 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len < 2) return null;
    const mult: u64 = switch (t[t.len - 1]) {
        'K' => 1024,
        'M' => 1024 * 1024,
        'G' => 1024 * 1024 * 1024,
        else => return null,
    };
    const digits = t[0 .. t.len - 1];
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    const n = std.fmt.parseInt(u64, digits, 10) catch return null;
    return std.math.mul(u64, n, mult) catch null;
}

pub fn resolvePath(arena: Allocator, path: []const u8, project_dir: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return path;
    return std.fs.path.join(arena, &.{ project_dir, path });
}

pub fn healthcheckToCmd(arena: Allocator, hc: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, hc, "http://") or std.mem.startsWith(u8, hc, "https://")) {
        return std.fmt.allocPrint(arena, "curl -sf '{s}'", .{hc});
    }
    return hc;
}

pub fn keeperStopTimeout(service: Service, set: ExecSet) u32 {
    if (service.timeouts.stop) |stop| {
        if (parseDurationSecs(stop)) |secs| return secs;
    }
    return if (set.stop != null or set.post_stop != null) 30 else 10;
}

pub fn buildSuperviseSpec(
    arena: Allocator,
    config: Config,
    service: Service,
    set: ExecSet,
    deps: []const DepSpec,
) !SuperviseSpec {
    return .{
        .label = try serviceLabel(arena, config, service.name),
        .pre_start = set.pre_start,
        .start = set.start,
        .stop = set.stop,
        .post_stop = set.post_stop,
        .reload = set.reload,
        .deps = deps,
        .ready_marker = if (service.oneshot) try readyMarkerPath(arena, config, service.name) else null,
        .stop_timeout_secs = keeperStopTimeout(service, set),
        .env = if (service.env.map.count() == 0) null else service.env,
        .workdir = if (service.workdir) |w| try resolvePath(arena, w, config.project_dir) else null,
    };
}

pub fn buildDepGates(arena: Allocator, config: Config, service: Service, all: []const Service) ![]const DepSpec {
    var gates: std.ArrayList(DepSpec) = .empty;
    for (service.requires) |name| {
        const dep = enabledService(all, name) orelse continue;
        const started = if (dep.oneshot)
            try std.fmt.allocPrint(arena, "test -f {s}", .{try readyMarkerPath(arena, config, dep.name)})
        else
            "true";
        try gates.append(arena, .{
            .poll_cmd = if (dep.healthcheck) |hc|
                try std.fmt.allocPrint(arena, "{s} && {s}", .{ started, try healthcheckToCmd(arena, hc) })
            else
                started,
            .timeout_secs = readinessSecs(dep),
            .required = true,
        });
    }
    for (service.after) |name| {
        const dep = enabledService(all, name) orelse continue;
        const hc = dep.healthcheck orelse continue;
        try gates.append(arena, .{
            .poll_cmd = try healthcheckToCmd(arena, hc),
            .timeout_secs = readinessSecs(dep),
            .required = false,
        });
    }
    return gates.toOwnedSlice(arena);
}

fn readinessSecs(dep: Service) u32 {
    const t = dep.readiness_timeout orelse return 90;
    return parseDurationSecs(t) orelse 90;
}

fn enabledService(all: []const Service, name: []const u8) ?Service {
    for (all) |s| {
        if (!s.disabled and std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

pub const EnvFileError = error{ MissingEquals, EmptyKey } || Allocator.Error;

pub fn parseEnvFile(arena: Allocator, content: []const u8, bad_line: *usize) EnvFileError!Env {
    var env: Env = .{};
    var lines = std.mem.splitScalar(u8, content, '\n');
    var n: usize = 0;
    while (lines.next()) |raw| {
        n += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const body = if (std.mem.startsWith(u8, line, "export "))
            std.mem.trimStart(u8, line["export ".len..], " \t")
        else
            line;
        const eq = std.mem.indexOfScalar(u8, body, '=') orelse {
            bad_line.* = n;
            return error.MissingEquals;
        };
        const key = std.mem.trim(u8, body[0..eq], " \t");
        if (key.len == 0) {
            bad_line.* = n;
            return error.EmptyKey;
        }
        var value = std.mem.trim(u8, body[eq + 1 ..], " \t");
        if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or
            (value[0] == '\'' and value[value.len - 1] == '\'')))
        {
            value = value[1 .. value.len - 1];
        }
        try env.map.put(arena, key, value);
    }
    return env;
}

fn hostService(name: []const u8) Service {
    return .{ .name = name, .mode = .host, .run_command = "sleep 1" };
}

test "a tree needs a keeper for deps or teardown, not otherwise" {
    try testing.expect(!needsKeeper(&.{}, .{ .start = "x" }));
    try testing.expect(needsKeeper(&.{}, .{ .start = "x", .stop = "y" }));
    try testing.expect(needsKeeper(&.{}, .{ .start = "x", .post_stop = "y" }));
    try testing.expect(needsKeeper(&.{.{ .poll_cmd = "true", .timeout_secs = 1, .required = true }}, .{ .start = "x" }));
}

test "labels, spec paths and ready markers are named for the grove" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = @import("config.zig").forTest("/s");
    try testing.expectEqualStrings("orch.web", try serviceLabel(a, config, "web"));
    try testing.expectEqualStrings("/s/supervise/orch.web.json", try superviseSpecPath(a, config, "orch.web"));
    try testing.expectEqualStrings("/s/ready/orch.web.ready", try readyMarkerPath(a, config, "web"));
}

test "durations are seconds or minutes" {
    try testing.expectEqual(30, parseDurationSecs("30s"));
    try testing.expectEqual(120, parseDurationSecs(" 2m "));
    try testing.expectEqual(null, parseDurationSecs("2h"));
    try testing.expectEqual(null, parseDurationSecs("s"));
}

test "memory is K, M or G and nothing else" {
    try testing.expectEqual(512 * 1024 * 1024, parseMemoryBytes("512M"));
    try testing.expectEqual(2 * 1024, parseMemoryBytes("2K"));
    try testing.expectEqual(1024 * 1024 * 1024, parseMemoryBytes("1G"));
    try testing.expectEqual(null, parseMemoryBytes("512"));
    try testing.expectEqual(null, parseMemoryBytes("M"));
    try testing.expectEqual(null, parseMemoryBytes("-1M"));
    try testing.expectEqual(null, parseMemoryBytes("1.5G"));
    try testing.expectEqual(null, parseMemoryBytes("99999999999999999999G"));
}

test "an http healthcheck becomes curl, anything else is a command" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("curl -sf 'http://localhost/h'", try healthcheckToCmd(arena.allocator(), "http://localhost/h"));
    try testing.expectEqualStrings("pg_isready", try healthcheckToCmd(arena.allocator(), "pg_isready"));
}

test "the stop timeout is TIMEOUT_STOP, else 30 with teardown, else 10" {
    var s = hostService("web");
    try testing.expectEqual(10, keeperStopTimeout(s, .{ .start = "x" }));
    try testing.expectEqual(30, keeperStopTimeout(s, .{ .start = "x", .stop = "y" }));
    s.timeouts.stop = "45s";
    try testing.expectEqual(45, keeperStopTimeout(s, .{ .start = "x", .stop = "y" }));
}

test "a supervise spec carries the exec set, env, workdir and a ready marker for oneshots" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = @import("config.zig").forTest("/s");
    var s = hostService("init");
    s.oneshot = true;
    s.workdir = "app";
    try s.env.map.put(a, "A", "b");
    const spec = try buildSuperviseSpec(a, config, s, .{ .start = "run", .reload = "kill -HUP $MAINPID" }, &.{});
    try testing.expectEqualStrings("orch.init", spec.label);
    try testing.expectEqualStrings("run", spec.start);
    try testing.expectEqualStrings("kill -HUP $MAINPID", spec.reload.?);
    try testing.expectEqualStrings("/s/ready/orch.init.ready", spec.ready_marker.?);
    try testing.expectEqualStrings("/test/project/app", spec.workdir.?);
    try testing.expectEqualStrings("b", spec.env.?.map.get("A").?);
    try testing.expectEqual(10, spec.stop_timeout_secs);

    const plain = try buildSuperviseSpec(a, config, hostService("web"), .{ .start = "run" }, &.{});
    try testing.expectEqual(null, plain.env);
    try testing.expectEqual(null, plain.workdir);
    try testing.expectEqual(null, plain.ready_marker);
}

test "requires gates on start and health, after gates only on health, disabled deps not at all" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = @import("config.zig").forTest("/s");
    var db = hostService("db");
    db.healthcheck = "pg_isready";
    db.readiness_timeout = "30s";
    var migrate = hostService("migrate");
    migrate.oneshot = true;
    var cache = hostService("cache");
    cache.healthcheck = "http://localhost:6379";
    var off = hostService("off");
    off.disabled = true;
    var web = hostService("web");
    web.requires = &.{ "db", "migrate", "off" };
    web.after = &.{ "cache", "migrate" };
    const all = [_]Service{ db, migrate, cache, off, web };

    const gates = try buildDepGates(a, config, web, &all);
    try testing.expectEqual(3, gates.len);
    try testing.expectEqualStrings("true && pg_isready", gates[0].poll_cmd);
    try testing.expectEqual(30, gates[0].timeout_secs);
    try testing.expect(gates[0].required);
    try testing.expectEqualStrings("test -f /s/ready/orch.migrate.ready", gates[1].poll_cmd);
    try testing.expectEqual(90, gates[1].timeout_secs);
    try testing.expectEqualStrings("curl -sf 'http://localhost:6379'", gates[2].poll_cmd);
    try testing.expect(!gates[2].required);
}

test "an env file takes comments, export, quotes and the last of a repeated key" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var bad: usize = 0;
    const env = try parseEnvFile(arena.allocator(),
        \\# comment
        \\
        \\export A = 1
        \\B="two words"
        \\C='three'
        \\A=4
    , &bad);
    try testing.expectEqualStrings("4", env.map.get("A").?);
    try testing.expectEqualStrings("two words", env.map.get("B").?);
    try testing.expectEqualStrings("three", env.map.get("C").?);
    try testing.expectEqual(3, env.map.count());
}

test "an env file line without = or with an empty key names its line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var bad: usize = 0;
    try testing.expectError(error.MissingEquals, parseEnvFile(arena.allocator(), "A=1\nnope\n", &bad));
    try testing.expectEqual(2, bad);
    try testing.expectError(error.EmptyKey, parseEnvFile(arena.allocator(), "=1\n", &bad));
    try testing.expectEqual(1, bad);
}
