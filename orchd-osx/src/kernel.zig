//! kernel.zig — provide orchd-osx's OWN Linux kernel asset.
//!
//! macOS ships no Linux kernel and VZLinuxBootLoader requires one, so this is
//! the single unavoidable external artifact. We do NOT reuse the container
//! daemon's downloaded kernel. orchd-osx manages its own pinned, reproducible
//! kernel as an asset.
//!
//! Pin (see ORCHD_OSX.md): a known-good upstream aarch64 Linux kernel built with
//! virtio_blk, virtio_console, vsock + vmw_vsock_virtio_transport, and ext4 all
//! built in (=y, not modules), so no initramfs is needed; the ext4 rootfs on
//! /dev/vda is mounted directly.
//!
//! Resolution order:
//!   1. $ORCHD_OSX_KERNEL                (explicit override)
//!   2. $HOME/.orch/osx/kernel/vmlinux   (managed asset store)

const std = @import("std");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;

pub const Error = error{ KernelMissing, NoHome, OutOfMemory };

/// Pinned kernel version. The matching build recipe/config lives alongside the
/// asset store; this string documents what we expect.
pub const PINNED_VERSION = "kata-6.18.28-194-arm64 (uncompressed Image, virtio-pci+ext4 builtin)";

/// Resolve the path to our kernel asset. Caller owns the returned slice.
/// Returns Error.KernelMissing (with guidance printed) if it is not present.
pub fn kernelPath(allocator: std.mem.Allocator) Error![]u8 {
    if (getenv("ORCHD_OSX_KERNEL")) |override| {
        return allocator.dupe(u8, std.mem.span(override)) catch return Error.OutOfMemory;
    }
    const home_z = getenv("HOME") orelse return Error.NoHome;
    const home = std.mem.span(home_z);
    const path = std.fmt.allocPrint(allocator, "{s}/.orch/osx/kernel/vmlinux", .{home}) catch
        return Error.OutOfMemory;

    const path_z = allocator.dupeZ(u8, path) catch return Error.OutOfMemory;
    defer allocator.free(path_z);
    if (access(path_z, 0) != 0) { // F_OK
        std.debug.print(
            "error: kernel asset missing at {s}\n" ++
                "       provide our pinned kernel ({s}) there, or set ORCHD_OSX_KERNEL\n",
            .{ path, PINNED_VERSION },
        );
        allocator.free(path);
        return Error.KernelMissing;
    }
    return path;
}
