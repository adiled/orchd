//! vm.zig — host VMM: build a VZVirtualMachineConfiguration, boot it, and hand
//! back the vsock connection fd. The ONLY consumer of objc.zig's VZ surface.
//!
//! Boundary: speaks "boot this kernel + ext4 rootfs, connect to this vsock
//! port, give me an fd". Knows nothing about containers, OCI, or the protocol.
//!
//! STATUS: stub. See ORCHD_OSX.md "Scouted: the boot contract" for the exact
//! selectors. Implementation order: build VZVirtualMachineConfiguration
//! (VZLinuxBootLoader + VZVirtioBlockDeviceConfiguration over a
//! VZDiskImageStorageDeviceAttachment + VZVirtioSocketDeviceConfiguration +
//! a serial console), validateWithError:, init the VM on a serial
//! dispatch_queue, startWithCompletionHandler: (block on a dispatch_semaphore
//! via a global completion block), then connectToPort: for the vsock fd.

const std = @import("std");
const objc = @import("objc.zig");

pub const Error = error{ NotImplemented, BootFailed, ConnectFailed };

pub const BootSpec = struct {
    kernel_path: [:0]const u8,
    cmdline: [:0]const u8,
    rootfs_path: [:0]const u8,
    cpu_count: usize,
    memory_bytes: u64,
    vsock_port: u32,
};

/// A running VM handle. Fields filled in by the implementation (the VZ objects
/// must be retained for the VM's lifetime).
pub const Vm = struct {
    handle: ?objc.Id = null,
    queue: ?objc.dispatch_queue_t = null,

    /// Connect to the guest's vsock port; returns a raw fd for proto framing.
    pub fn connect(self: *Vm, port: u32) Error!std.posix.fd_t {
        _ = self;
        _ = port;
        return Error.NotImplemented;
    }

    /// Request guest stop and tear the VM down.
    pub fn shutdown(self: *Vm) void {
        _ = self;
    }
};

/// Build + start a VM per `spec`. Returns once the VM is running.
pub fn boot(spec: BootSpec) Error!Vm {
    _ = spec;
    return Error.NotImplemented;
}
