//! Virtualization.framework backend for orchd-osx (the host VMM side).
//!
//! This is the from-scratch runtime that replaces the container daemon. The
//! design (validated by research; see ORCHD_OSX.md) is a two-layer stack:
//!
//!   [host, macOS]                         [guest, Linux VM]
//!   Virtualization.framework  ── vsock ── vminitd (PID 1, gRPC server)
//!     driven via objc_msgSend               process/exec/wait/kill/IO/mount
//!     boots: kernel + ext4 rootfs
//!
//! We own everything host-side in Zig (proven feasible: Code-Hex/vz and vfkit
//! drive the same framework from Go). We reuse only Apple ARTIFACTS as data,
//! never linked Swift: the Linux kernel and the vminitd guest binary that the
//! container daemon already fetches.
//!
//! Build-out order (each step independently testable):
//!   1. objc.zig — Objective-C runtime helpers (class lookup, msgSend shims).
//!      We already drive ObjC from Zig for XPC, so this is known ground.
//!   2. boot a bare VZ Linux VM with a VZVirtioSocketDevice attached.
//!   3. vsock.zig — a minimal gRPC-over-vsock client to vminitd; goal: exec
//!      `echo` inside the guest and read its output.
//!   4. ext4.zig — OCI image -> ext4 rootfs. Reuse the daemon's prepared
//!      artifacts first; own the builder later (parity with ContainerizationEXT4).
//!   5. full lifecycle wired into the run/wait/stop/delete entry points below.
//!
//! Requires the `com.apple.security.virtualization` entitlement at runtime
//! (codesign), same as the container daemon and vfkit.

const std = @import("std");

pub const Error = error{
    /// The backend is scaffolded but the operation is not built yet.
    NotImplemented,
};

/// Create and boot a VM for `image`, then start the container's init process.
/// Returns once the container is running (the supervisor then calls `wait`).
pub fn run(allocator: std.mem.Allocator, id: []const u8, image: []const u8) Error!void {
    _ = allocator;
    _ = id;
    _ = image;
    // TODO(step 2-5): VZVirtualMachineConfiguration -> boot loader + ext4 block
    // device + vsock device -> start VM -> vminitd: configure + spawn process.
    return Error.NotImplemented;
}

/// Block until the container's init process exits; return its exit code.
/// This is the foreground process the launchd supervisor tracks.
pub fn wait(allocator: std.mem.Allocator, id: []const u8) Error!i64 {
    _ = allocator;
    _ = id;
    // TODO: vminitd wait RPC over vsock.
    return Error.NotImplemented;
}

/// Graceful stop: signal the container's init process and shut the VM down.
pub fn stop(allocator: std.mem.Allocator, id: []const u8) Error!void {
    _ = allocator;
    _ = id;
    return Error.NotImplemented;
}

/// Remove the container's VM and any backing state.
pub fn delete(allocator: std.mem.Allocator, id: []const u8) Error!void {
    _ = allocator;
    _ = id;
    return Error.NotImplemented;
}

/// Whether the VZ backend is usable on this host (entitlement, framework).
/// For the scaffold this is always true so the envelope wiring is testable;
/// step 2 replaces it with a real VZVirtualMachine.supportedConfiguration probe.
pub fn available() bool {
    return true;
}
