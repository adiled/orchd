const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const Artifact = struct {
    kind: []const u8,
    path: []const u8,
    content: []const u8,
};

pub const Bed = struct {
    label: []const u8,
    name: ?[]const u8 = null,
    artifacts: []const Artifact,
    stale: []const []const u8 = &.{},
};

pub fn render(arena: Allocator, comptime write: anytype, args: anytype) ![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    try @call(.auto, write, .{&out.writer} ++ args);
    return out.written();
}

pub fn plant(arena: Allocator, io: Io, beds: []const Bed) ![]const []const u8 {
    const cwd = Io.Dir.cwd();
    var written: std.ArrayList([]const u8) = .empty;
    for (beds) |bed| {
        for (bed.stale) |path| cwd.deleteFile(io, path) catch {};
        for (bed.artifacts) |a| {
            if (std.fs.path.dirname(a.path)) |dir| try cwd.createDirPath(io, dir);
            try cwd.writeFile(io, .{ .sub_path = a.path, .data = a.content });
            try written.append(arena, a.path);
        }
    }
    return written.items;
}

test "planting a bed clears its stale counterpart and writes every artifact" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "old.plist", .data = "old" });
    const written = try plant(a, testing.io, &.{.{
        .label = "orch.web",
        .name = "web",
        .artifacts = &.{.{ .kind = "plist", .path = try std.fs.path.join(a, &.{ root, "units", "deep", "orch.web.plist" }), .content = "new" }},
        .stale = &.{try std.fs.path.join(a, &.{ root, "old.plist" })},
    }});
    try testing.expectEqual(1, written.len);
    try testing.expectEqualStrings("new", try tmp.dir.readFileAlloc(testing.io, "units/deep/orch.web.plist", a, .limited(64)));
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "old.plist", .{}));
}
