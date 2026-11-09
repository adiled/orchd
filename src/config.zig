const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const Scope = enum {
    system,
    user,

    pub fn parse(s: []const u8) ?Scope {
        if (std.ascii.eqlIgnoreCase(s, "system")) return .system;
        if (std.ascii.eqlIgnoreCase(s, "user")) return .user;
        return null;
    }
};

pub const Config = struct {
    orchfile: []const u8,
    overlays: []const []const u8 = &.{},
    rootstock: []const u8 = "bare",
    platform: []const u8,
    scope: Scope = .system,
    state_dir: []const u8,
    project_dir: []const u8,
    data_dir: []const u8,
    grove: []const u8 = "orch",
    home: []const u8 = "/root",
    args: []const []const u8 = &.{},
    verbose: bool = false,
    quiet: bool = false,

    pub fn unitsDir(config: Config, arena: Allocator) ![]const u8 {
        return std.fs.path.join(arena, &.{ config.state_dir, "units" });
    }

    pub fn unitName(config: Config, arena: Allocator, service_name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s}-{s}.service", .{ config.grove, service_name });
    }

    pub fn targetName(config: Config, arena: Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s}.target", .{config.grove});
    }
};

pub fn forTest(dir: []const u8) Config {
    return .{
        .orchfile = "/test/Orchfile",
        .platform = "launchd",
        .scope = .user,
        .state_dir = dir,
        .project_dir = "/test/project",
        .data_dir = "/test/.orch/data",
        .home = "/Users/test",
    };
}

test "a scope reads either case" {
    try testing.expectEqual(.user, Scope.parse("USER"));
    try testing.expectEqual(.system, Scope.parse("system"));
    try testing.expectEqual(null, Scope.parse("global"));
}

test "units, unit names and the target are named for the grove" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var config = forTest("/test/.orch");
    config.grove = "hum";
    try testing.expectEqualStrings("/test/.orch/units", try config.unitsDir(arena.allocator()));
    try testing.expectEqualStrings("hum-web.service", try config.unitName(arena.allocator(), "web"));
    try testing.expectEqualStrings("hum.target", try config.targetName(arena.allocator()));
}
