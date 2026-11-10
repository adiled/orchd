const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const testing = std.testing;

pub const dir = "/run/orchd/netns";

pub fn pathFor(arena: Allocator, id: []const u8) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(arena, dir ++ "/{s}", .{id}, 0);
}

pub fn create(path: [:0]const u8) !void {
    if (builtin.os.tag != .linux) return error.Unsupported;
    remove(path);
    _ = std.c.mkdir("/run/orchd", 0o755);
    _ = std.c.mkdir(dir, 0o755);
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CREAT = true, .EXCL = true }, @as(c_uint, 0o444));
    if (fd < 0) return error.CreateFailed;
    _ = std.c.close(fd);
    var result: anyerror!void = {};
    const thread = try std.Thread.spawn(.{}, pin, .{ path, &result });
    thread.join();
    result catch |err| {
        _ = std.c.unlink(path);
        return err;
    };
}

fn pin(path: [:0]const u8, result: *anyerror!void) void {
    if (linux.errno(linux.unshare(linux.CLONE.NEWNET)) != .SUCCESS) {
        result.* = error.UnshareFailed;
        return;
    }
    if (linux.errno(linux.mount("/proc/thread-self/ns/net", path, null, linux.MS.BIND, 0)) != .SUCCESS) result.* = error.MountFailed;
}

pub fn remove(path: [:0]const u8) void {
    if (builtin.os.tag != .linux) return;
    _ = linux.umount2(path, linux.MNT.DETACH);
    _ = std.c.unlink(path);
}

pub fn exists(path: [:0]const u8) bool {
    return std.c.access(path, 0) == 0;
}

test "each tree's namespace is pinned under one directory, by its id" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("/run/orchd/netns/hum-web", try pathFor(arena.allocator(), "hum-web"));
}
