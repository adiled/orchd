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
