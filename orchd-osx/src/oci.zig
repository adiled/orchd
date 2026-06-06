//! oci.zig — image reference -> local rootfs directory + process config.
//!
//! Boundary: "given an image ref, produce an unpacked rootfs dir and the
//! process defaults (entrypoint/cmd/env/cwd) from the OCI config". Feeds
//! ext4.zig (rootfs -> disk) and the ExecSpec (process to run). Knows nothing
//! about VMs.
//!
//! STATUS: stub. Implementation: resolve the ref against a registry (or a local
//! cache), pull the manifest + layers, unpack the layers into a rootfs dir, and
//! parse the OCI config for Entrypoint/Cmd/Env/WorkingDir. We own this end to
//! end (no daemon), so it is a from-scratch registry client + layer unpacker.

const std = @import("std");

pub const Error = error{ NotImplemented, ImageNotFound };

/// A resolved image: an unpacked rootfs plus the process defaults from its
/// OCI config. `argv` is Entrypoint ++ Cmd.
pub const Image = struct {
    rootfs_dir: []const u8,
    argv: []const []const u8,
    env: []const []const u8,
    cwd: []const u8,
};

/// Resolve and unpack `reference` into a rootfs under `work_dir`.
pub fn resolve(
    allocator: std.mem.Allocator,
    io: std.Io,
    work_dir: []const u8,
    reference: []const u8,
) Error!Image {
    _ = allocator;
    _ = io;
    _ = work_dir;
    _ = reference;
    return Error.NotImplemented;
}
