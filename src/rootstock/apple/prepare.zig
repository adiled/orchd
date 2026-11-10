//! Image pull via subprocess.
//!
//! Shell out to `container image pull <image>` rather than reimplement the OCI
//! pull protocol — pull is infrequent, network-bound, and best left to the
//! container daemon which owns the content store.

const std = @import("std");

pub const PullError = error{
    SpawnFailed,
    PullFailed,
};

/// Pull `image` using the system `container` binary, inheriting stdout/stderr
/// so orchd sees progress. Blocks until complete.
pub fn pullImage(io: std.Io, image: []const u8) PullError!void {
    var child = std.process.spawn(io, .{
        .argv = &.{ "container", "image", "pull", image },
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch return PullError.SpawnFailed;

    const term = child.wait(io) catch return PullError.SpawnFailed;
    switch (term) {
        .exited => |code| if (code != 0) return PullError.PullFailed,
        else => return PullError.PullFailed,
    }
}

/// The backing file of the named volume `name`, made first if it is missing.
/// Like image pull, volume create goes through the `container` binary.
pub fn volume(arena: std.mem.Allocator, io: std.Io, name: []const u8) ![]const u8 {
    if (try volumeSource(arena, io, name)) |source| return source;
    const made = std.process.run(arena, io, .{ .argv = &.{ "container", "volume", "create", name } }) catch return error.VolumeCreateFailed;
    if (!made.term.success()) return error.VolumeCreateFailed;
    return try volumeSource(arena, io, name) orelse error.VolumeCreateFailed;
}

fn volumeSource(arena: std.mem.Allocator, io: std.Io, name: []const u8) !?[]const u8 {
    const out = std.process.run(arena, io, .{ .argv = &.{ "container", "volume", "inspect", name } }) catch return null;
    if (!out.term.success()) return null;
    return sourceIn(arena, out.stdout);
}

pub fn sourceIn(arena: std.mem.Allocator, inspect_json: []const u8) ?[]const u8 {
    const doc = std.json.parseFromSliceLeaky(std.json.Value, arena, inspect_json, .{}) catch return null;
    if (doc != .array or doc.array.items.len == 0) return null;
    const first = doc.array.items[0];
    if (first != .object) return null;
    const config = first.object.get("configuration") orelse return null;
    if (config != .object) return null;
    const source = config.object.get("source") orelse return null;
    return if (source == .string) source.string else null;
}

test "a volume's backing file is read from what inspect prints" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("/Users/a/volumes/pg/volume.img", sourceIn(a,
        \\[{"configuration":{"format":"ext4","name":"pg","source":"\/Users\/a\/volumes\/pg\/volume.img"},"id":"pg"}]
    ).?);
    try std.testing.expectEqual(null, sourceIn(a, "[]"));
    try std.testing.expectEqual(null, sourceIn(a, "not json"));
}
