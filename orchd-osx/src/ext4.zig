//! ext4.zig — rootfs directory -> ext4 image file (the VM's /dev/vda).
//!
//! Boundary: "given an unpacked rootfs dir, produce an ext4 image at out_path".
//! Knows nothing about VMs or OCI. Parity with what ContainerizationEXT4 does,
//! built from scratch in Zig.
//!
//! STATUS: stub. Implementation: create a sparse file of size_bytes, write an
//! ext4 superblock + block/inode bitmaps + inode table + directory tree, and
//! copy the rootfs files in. Also place our guest init binary at the path named
//! by the kernel cmdline (init=/orchd-init).

const std = @import("std");

pub const Error = error{ NotImplemented, TooSmall };

/// Build an ext4 image at `out_path` from the files under `rootfs_dir`,
/// sized `size_bytes`. `init_path`/`init_bytes` install our guest init into the
/// image at the location the kernel cmdline boots (e.g. /orchd-init).
pub fn build(
    allocator: std.mem.Allocator,
    rootfs_dir: []const u8,
    out_path: []const u8,
    size_bytes: u64,
    init_path: []const u8,
    init_bytes: []const u8,
) Error!void {
    _ = allocator;
    _ = rootfs_dir;
    _ = out_path;
    _ = size_bytes;
    _ = init_path;
    _ = init_bytes;
    return Error.NotImplemented;
}
