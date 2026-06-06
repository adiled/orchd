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

pub const Error = error{ KernelMissing, NoHome, OutOfMemory };

/// Pinned kernel version. The matching build recipe/config lives alongside the
/// asset store; this string documents what we expect.
pub const PINNED_VERSION = "6.12-lts-aarch64-virtio";

/// Resolve the path to our kernel asset. Caller owns the returned slice.
/// Returns Error.KernelMissing (with guidance printed) if it is not present.
pub fn kernelPath(allocator: std.mem.Allocator) Error![]u8 {
    if (std.posix.getenv("ORCHD_OSX_KERNEL")) |override| {
        return allocator.dupe(u8, override) catch return Error.OutOfMemory;
    }
    const home = std.posix.getenv("HOME") orelse return Error.NoHome;
    const path = std.fmt.allocPrint(allocator, "{s}/.orch/osx/kernel/vmlinux", .{home}) catch
        return Error.OutOfMemory;

    std.fs.accessAbsolute(path, .{}) catch {
        std.debug.print(
            "error: kernel asset missing at {s}\n" ++
                "       provide our pinned kernel ({s}) there, or set ORCHD_OSX_KERNEL\n",
            .{ path, PINNED_VERSION },
        );
        allocator.free(path);
        return Error.KernelMissing;
    };
    return path;
}
