const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const testing = std.testing;
const config_mod = @import("config.zig");
const Config = config_mod.Config;
const Scope = config_mod.Scope;
const Global = @import("cli.zig").Global;

pub const Rc = std.StringHashMapUnmanaged([]const u8);

const Sources = struct {
    environ: *const Environ.Map,
    rc: Rc,

    fn pick(s: Sources, flag: ?[]const u8, env: []const u8, key: []const u8) ?[]const u8 {
        if (flag) |v| return v;
        if (s.environ.get(env)) |v| return v;
        return s.rc.get(key);
    }
};

pub fn load(arena: Allocator, io: Io, environ: *const Environ.Map, global: Global) !Config {
    const home = environ.get("HOME") orelse "/root";
    const project_dir = global.project_dir orelse environ.get("ORCH_PROJECT") orelse
        try std.process.currentPathAlloc(io, arena);
    const sources: Sources = .{ .environ = environ, .rc = try loadRc(arena, io, project_dir, home) };

    const state_dir = sources.pick(global.state_dir, "ORCH_STATE_DIR", "state_dir") orelse
        try std.fs.path.join(arena, &.{ home, ".orch" });
    const grove = sources.pick(global.grove, "ORCH_GROVE", "grove") orelse "orch";
    const scope: Scope = if (global.user)
        .user
    else if (global.system)
        .system
    else if (environ.get("ORCH_SCOPE") orelse sources.rc.get("scope")) |s|
        Scope.parse(s) orelse .system
    else
        .system;

    return .{
        .orchfile = sources.pick(global.orchfile, "ORCH_ORCHFILE", "orchfile") orelse
            try std.fs.path.join(arena, &.{ project_dir, "Orchfile" }),
        .overlays = global.overlay,
        .rootstock = sources.pick(global.rootstock, "ORCH_ROOTSTOCK", "rootstock") orelse "bare",
        .platform = sources.pick(global.platform, "ORCH_PLATFORM", "platform") orelse detectPlatform(),
        .scope = scope,
        .state_dir = state_dir,
        .project_dir = project_dir,
        .data_dir = sources.pick(global.data_dir, "ORCH_DATA", "data_dir") orelse
            try std.fs.path.join(arena, &.{ state_dir, "data", grove }),
        .grove = grove,
        .home = home,
        .xdg_config_home = environ.get("XDG_CONFIG_HOME"),
        .args = global.arg,
        .verbose = global.verbose,
        .quiet = global.quiet,
    };
}

fn detectPlatform() []const u8 {
    return if (builtin.os.tag == .macos) "launchd" else "systemd";
}

fn loadRc(arena: Allocator, io: Io, project_dir: []const u8, home: []const u8) !Rc {
    for ([_][]const u8{ project_dir, home }) |dir| {
        const path = try std.fs.path.join(arena, &.{ dir, ".orchrc" });
        const content = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch continue;
        return parseRc(arena, content);
    }
    return .empty;
}

pub fn parseRc(arena: Allocator, content: []const u8) !Rc {
    var rc: Rc = .empty;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (key.len == 0) continue;
        try rc.put(arena, key, std.mem.trim(u8, line[eq + 1 ..], " \t"));
    }
    return rc;
}

test "an .orchrc takes key = value lines and passes over the rest" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const rc = try parseRc(arena.allocator(), "# c\n rootstock = apple \nnoise\n=x\ngrove=hum\n");
    try testing.expectEqualStrings("apple", rc.get("rootstock").?);
    try testing.expectEqualStrings("hum", rc.get("grove").?);
    try testing.expectEqual(2, rc.count());
}

test "flags win over env, env over .orchrc, and defaults fill the rest" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".orchrc", .data = "rootstock=apple\ngrove=fromrc\nscope=user\nplatform=orchdi\n" });

    var environ: Environ.Map = .init(a);
    try environ.put("HOME", "/home/test");
    try environ.put("ORCH_GROVE", "fromenv");

    const config = try load(a, testing.io, &environ, .{ .project_dir = project, .platform = "systemd" });
    try testing.expectEqualStrings("systemd", config.platform);
    try testing.expectEqualStrings("fromenv", config.grove);
    try testing.expectEqualStrings("apple", config.rootstock);
    try testing.expectEqual(.user, config.scope);
    try testing.expectEqualStrings("/home/test/.orch", config.state_dir);
    try testing.expectEqualStrings("/home/test/.orch/data/fromenv", config.data_dir);
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ project, "Orchfile" }), config.orchfile);

    const system = try load(a, testing.io, &environ, .{ .project_dir = project, .system = true, .state_dir = "/s", .grove = "g" });
    try testing.expectEqual(.system, system.scope);
    try testing.expectEqualStrings("/s/data/g", system.data_dir);
}

test "with nothing set, a grove is orch, the rootstock bare, the scope system" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var environ: Environ.Map = .init(a);
    try environ.put("HOME", "/nonexistent-home");
    const config = try load(a, testing.io, &environ, .{ .project_dir = "/nonexistent-project" });
    try testing.expectEqualStrings("orch", config.grove);
    try testing.expectEqualStrings("bare", config.rootstock);
    try testing.expectEqual(.system, config.scope);
    try testing.expectEqualStrings(detectPlatform(), config.platform);
}
