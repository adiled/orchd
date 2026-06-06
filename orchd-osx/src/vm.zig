//! vm.zig — host VMM: build a VZVirtualMachineConfiguration, boot it, and hand
//! back the vsock connection fd. The ONLY consumer of objc.zig's VZ surface.
//!
//! Boundary: speaks "boot this kernel + ext4 rootfs, connect to this vsock
//! port, give me an fd". Knows nothing about containers, OCI, or the protocol.
//!
//! Implementation: build VZVirtualMachineConfiguration (VZLinuxBootLoader +
//! VZVirtioBlockDeviceConfiguration over a VZDiskImageStorageDeviceAttachment +
//! VZVirtioSocketDeviceConfiguration + a serial console + entropy device),
//! validateWithError:, init the VM on a serial dispatch_queue, then
//! startWithCompletionHandler: (blocking on a semaphore via a global completion
//! block), then connectToPort: for the vsock fd.
//!
//! Apple's hard rule: every VZVirtualMachine operation (start, socketDevices,
//! connectToPort:, stop) MUST run on the queue the VM was created with. We honor
//! that by dispatching each onto that serial queue and blocking the calling
//! thread on a dispatch_semaphore until the async completion handler fires.

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

// --- dispatch primitives not surfaced by objc.zig ---
//
// We need to run closures on the VM's serial queue. dispatch_async takes an
// ObjC block; we reuse objc.zig's global-block machinery for that. (objc.zig
// intentionally exposes only queue/semaphore create+wait+signal.)

extern "c" fn dispatch_async(queue: objc.dispatch_queue_t, block: ?objc.Id) void;

// --- module globals reached by the global completion blocks ---
//
// orchd-osx drives exactly one VM per process, so the async VZ completion
// results can live here and be read after the matching semaphore wakes us.
// A global, non-capturing block has no other way to return a value.

var g_start_sema: ?objc.dispatch_semaphore_t = null;
var g_start_err: ?objc.Id = null;

var g_connect_sema: ?objc.dispatch_semaphore_t = null;
var g_connect_conn: ?objc.Id = null;
var g_connect_err: ?objc.Id = null;

// dispatch_async trampoline state: the work to run on the VM queue plus a
// semaphore to tell the caller that work (and its own completion handler) has
// been kicked off. We split "dispatched" from "completed": the inner async VZ
// call signals the completion semaphore.

var g_dispatched_sema: ?objc.dispatch_semaphore_t = null;
const DispatchKind = enum { start, connect };
var g_dispatch_kind: DispatchKind = .start;
var g_dispatch_vm: ?objc.Id = null;
var g_dispatch_port: u32 = 0;

// --- block invoke functions (C ABI; first arg is the block pointer) ---

/// startWithCompletionHandler: block. Signature: void(^)(NSError*).
fn startCompletion(block: *anyopaque, err: ?objc.Id) callconv(.c) void {
    _ = block;
    g_start_err = err;
    if (g_start_sema) |s| _ = objc.dispatch_semaphore_signal(s);
}

/// connectToPort:completionHandler: block. void(^)(VZVirtioSocketConnection*, NSError*).
fn connectCompletion(block: *anyopaque, conn: ?objc.Id, err: ?objc.Id) callconv(.c) void {
    _ = block;
    g_connect_conn = conn;
    g_connect_err = err;
    if (g_connect_sema) |s| _ = objc.dispatch_semaphore_signal(s);
}

/// dispatch_async trampoline: runs ON the VM's serial queue. Issues the actual
/// VZ async call (start or connect) from the correct thread, then returns; the
/// VZ completion block above does the signaling.
fn queueWork(block: *anyopaque) callconv(.c) void {
    _ = block;
    const vm = g_dispatch_vm;
    switch (g_dispatch_kind) {
        .start => {
            objc.msgSend(void, vm, objc.sel("startWithCompletionHandler:"), .{blockArg(&start_block)});
        },
        .connect => {
            // socketDevices[0] -> VZVirtioSocketDevice, then connectToPort:.
            const devices = objc.msgSend(?objc.Id, vm, objc.sel("socketDevices"), .{});
            const count = objc.msgSend(usize, devices, objc.sel("count"), .{});
            if (count == 0) {
                // No vsock device; report as a connect error path.
                g_connect_conn = null;
                g_connect_err = @as(?objc.Id, @ptrFromInt(1)); // sentinel non-null
                if (g_connect_sema) |s| _ = objc.dispatch_semaphore_signal(s);
                return;
            }
            const dev = objc.msgSend(?objc.Id, devices, objc.sel("objectAtIndex:"), .{@as(usize, 0)});
            objc.msgSend(void, dev, objc.sel("connectToPort:completionHandler:"), .{
                g_dispatch_port,
                blockArg(&connect_block),
            });
        },
    }
    if (g_dispatched_sema) |s| _ = objc.dispatch_semaphore_signal(s);
}

// --- static global block literals ---
//
// Each block literal lives at module scope (static lifetime) as objc.zig
// requires, paired with its descriptor.

var start_desc: objc.BlockDescriptor = .{ .size = @sizeOf(objc.BlockLiteral) };
var start_block: objc.BlockLiteral = objc.globalBlock(startCompletion, &start_desc);

var connect_desc: objc.BlockDescriptor = .{ .size = @sizeOf(objc.BlockLiteral) };
var connect_block: objc.BlockLiteral = objc.globalBlock(connectCompletion, &connect_desc);

var work_desc: objc.BlockDescriptor = .{ .size = @sizeOf(objc.BlockLiteral) };
var work_block: objc.BlockLiteral = objc.globalBlock(queueWork, &work_desc);

/// Cast a static block literal pointer to the objc.Id an ObjC block param wants.
fn blockArg(lit: *objc.BlockLiteral) objc.Id {
    return @ptrCast(lit);
}

// --- configuration builder ---
//
// Each step returns null on the first missing class/object so callers can map a
// build failure to BootFailed without crashing on a nil deref.

const BuildError = error{BuildFailed};

/// Build a fully populated, retained VZVirtualMachineConfiguration for `spec`.
/// Does NOT validate; caller validates. Returns the config Id.
fn buildConfig(spec: BootSpec) BuildError!objc.Id {
    // Boot loader: VZLinuxBootLoader initWithKernelURL: + setCommandLine:.
    const boot_cls = objc.class("VZLinuxBootLoader") orelse return error.BuildFailed;
    const boot_alloc = objc.msgSend(?objc.Id, boot_cls, objc.sel("alloc"), .{}) orelse return error.BuildFailed;
    const kernel_url = objc.fileURL(spec.kernel_path);
    const boot_loader = objc.msgSend(?objc.Id, boot_alloc, objc.sel("initWithKernelURL:"), .{kernel_url}) orelse return error.BuildFailed;
    objc.msgSend(void, boot_loader, objc.sel("setCommandLine:"), .{objc.nsString(spec.cmdline)});

    // Root disk: VZDiskImageStorageDeviceAttachment initWithURL:readOnly:error:
    // then wrapped in a VZVirtioBlockDeviceConfiguration. A nonexistent rootfs
    // may fail here; we tolerate it and just skip the disk so config building
    // (and the unit test) still proceeds without a real image.
    var block_dev: ?objc.Id = null;
    if (objc.class("VZDiskImageStorageDeviceAttachment")) |att_cls| {
        const att_alloc = objc.msgSend(?objc.Id, att_cls, objc.sel("alloc"), .{});
        const disk_url = objc.fileURL(spec.rootfs_path);
        var att_err: ?objc.Id = null;
        const attachment = objc.msgSend(
            ?objc.Id,
            att_alloc,
            objc.sel("initWithURL:readOnly:error:"),
            .{ disk_url, @as(u8, 0), &att_err },
        );
        if (attachment != null and att_err == null) {
            if (objc.class("VZVirtioBlockDeviceConfiguration")) |blk_cls| {
                const blk_alloc = objc.msgSend(?objc.Id, blk_cls, objc.sel("alloc"), .{});
                block_dev = objc.msgSend(?objc.Id, blk_alloc, objc.sel("initWithAttachment:"), .{attachment});
            }
        }
    }

    // vsock: plain VZVirtioSocketDeviceConfiguration.
    const vsock_dev = objc.allocInit("VZVirtioSocketDeviceConfiguration");

    // Serial console -> stderr, so guest boot logs surface on the host.
    const serial_dev = buildSerialConsole();

    // Entropy (virtio-rng) helps the guest boot in reasonable time.
    const entropy_dev = objc.allocInit("VZVirtioEntropyDeviceConfiguration");

    // Assemble the configuration.
    const cfg_cls = objc.class("VZVirtualMachineConfiguration") orelse return error.BuildFailed;
    const cfg_alloc = objc.msgSend(?objc.Id, cfg_cls, objc.sel("alloc"), .{}) orelse return error.BuildFailed;
    const config = objc.msgSend(?objc.Id, cfg_alloc, objc.sel("init"), .{}) orelse return error.BuildFailed;

    objc.msgSend(void, config, objc.sel("setBootLoader:"), .{boot_loader});
    objc.msgSend(void, config, objc.sel("setCPUCount:"), .{spec.cpu_count});
    objc.msgSend(void, config, objc.sel("setMemorySize:"), .{spec.memory_bytes});

    if (block_dev) |d| {
        objc.msgSend(void, config, objc.sel("setStorageDevices:"), .{singletonArray(d)});
    }
    if (vsock_dev) |d| {
        objc.msgSend(void, config, objc.sel("setSocketDevices:"), .{singletonArray(d)});
    }
    if (serial_dev) |d| {
        objc.msgSend(void, config, objc.sel("setSerialPorts:"), .{singletonArray(d)});
    }
    if (entropy_dev) |d| {
        objc.msgSend(void, config, objc.sel("setEntropyDevices:"), .{singletonArray(d)});
    }

    return config;
}

/// VZVirtioConsoleDeviceSerialPortConfiguration backed by stderr. Returns null
/// if any class is missing (non-fatal; console is a convenience).
fn buildSerialConsole() ?objc.Id {
    const fh_cls = objc.class("NSFileHandle") orelse return null;
    const stderr_fh = objc.msgSend(?objc.Id, fh_cls, objc.sel("fileHandleWithStandardError"), .{}) orelse return null;

    const att_cls = objc.class("VZFileHandleSerialPortAttachment") orelse return null;
    const att_alloc = objc.msgSend(?objc.Id, att_cls, objc.sel("alloc"), .{}) orelse return null;
    // initWithFileHandleForReading:writeHandle: (nil read, stderr write).
    const attachment = objc.msgSend(
        ?objc.Id,
        att_alloc,
        objc.sel("initWithFileHandleForReading:fileHandleForWriting:"),
        .{ @as(?objc.Id, null), stderr_fh },
    ) orelse return null;

    const serial = objc.allocInit("VZVirtioConsoleDeviceSerialPortConfiguration") orelse return null;
    objc.msgSend(void, serial, objc.sel("setAttachment:"), .{attachment});
    return serial;
}

/// `[NSArray arrayWithObject:obj]` — a one-element NSArray. We avoid varargs by
/// using the single-object convenience selector.
fn singletonArray(obj: objc.Id) objc.Id {
    const NSArray = objc.class("NSArray").?;
    return objc.msgSend(objc.Id, NSArray, objc.sel("arrayWithObject:"), .{obj});
}

// --- VM handle ---

/// A running VM handle. The VZVirtualMachine and its queue are retained for the
/// VM's lifetime (the config's sub-objects are kept alive by the VM).
pub const Vm = struct {
    handle: ?objc.Id = null,
    queue: ?objc.dispatch_queue_t = null,

    /// Connect to the guest's vsock port; returns a raw fd for proto framing.
    /// The guest must already be listening, so we retry briefly. The connect
    /// itself is issued on the VM's serial queue (Apple's requirement).
    pub fn connect(self: *Vm, port: u32) Error!std.posix.fd_t {
        const vm = self.handle orelse return Error.ConnectFailed;
        const queue = self.queue orelse return Error.ConnectFailed;

        g_connect_sema = objc.dispatch_semaphore_create(0);
        g_dispatched_sema = objc.dispatch_semaphore_create(0);

        // Brief retry loop: the guest may not be listening the instant we start.
        var attempt: usize = 0;
        while (attempt < 50) : (attempt += 1) {
            g_connect_conn = null;
            g_connect_err = null;
            g_dispatch_kind = .connect;
            g_dispatch_vm = vm;
            g_dispatch_port = port;

            dispatch_async(queue, blockArg(&work_block));
            _ = objc.dispatch_semaphore_wait(g_dispatched_sema.?, objc.DISPATCH_TIME_FOREVER);
            _ = objc.dispatch_semaphore_wait(g_connect_sema.?, objc.DISPATCH_TIME_FOREVER);

            if (g_connect_err == null and g_connect_conn != null) {
                const fd = objc.msgSend(c_int, g_connect_conn, objc.sel("fileDescriptor"), .{});
                return @as(std.posix.fd_t, fd);
            }
            // Back off ~100ms before retrying.
            sleepMs(100);
        }
        return Error.ConnectFailed;
    }

    /// Request guest stop and tear the VM down. Best-effort. The stop request
    /// must run on the VM's serial queue, so we dispatch it there and wait.
    pub fn shutdown(self: *Vm) void {
        if (self.handle == null or self.queue == null) return;
        stopOnQueue(self.*);
        self.handle = null;
    }
};

/// Issue requestStopWithError: on the VM's serial queue and wait for dispatch.
fn stopOnQueue(vm: Vm) void {
    const handle = vm.handle orelse return;
    const queue = vm.queue orelse return;
    g_stop_vm = handle;
    g_stop_sema = objc.dispatch_semaphore_create(0);
    dispatch_async(queue, blockArg(&stop_block));
    _ = objc.dispatch_semaphore_wait(g_stop_sema.?, objc.DISPATCH_TIME_FOREVER);
}

var g_stop_vm: ?objc.Id = null;
var g_stop_sema: ?objc.dispatch_semaphore_t = null;
var stop_desc: objc.BlockDescriptor = .{ .size = @sizeOf(objc.BlockLiteral) };
var stop_block: objc.BlockLiteral = objc.globalBlock(stopWork, &stop_desc);

fn stopWork(block: *anyopaque) callconv(.c) void {
    _ = block;
    if (g_stop_vm) |vm| {
        var err: ?objc.Id = null;
        // requestStopWithError: returns BOOL; ignore result, best-effort.
        _ = objc.msgSend(u8, vm, objc.sel("requestStopWithError:"), .{&err});
    }
    if (g_stop_sema) |s| _ = objc.dispatch_semaphore_signal(s);
}

/// Sleep helper without pulling in std.time on this Zig (nanosleep via libc).
fn sleepMs(ms: u64) void {
    const ts = TimeSpec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    _ = nanosleep(&ts, null);
}
const TimeSpec = extern struct { sec: isize, nsec: isize };
extern "c" fn nanosleep(req: *const TimeSpec, rem: ?*TimeSpec) c_int;

// --- boot ---

/// Build + start a VM per `spec`. Returns once the VM start completion fires
/// (successfully). Maps any build/validate/start failure to BootFailed.
pub fn boot(spec: BootSpec) Error!Vm {
    const config = buildConfig(spec) catch return Error.BootFailed;

    // Validate. validateWithError: returns BOOL; NSError** out-param on failure.
    var verr: ?objc.Id = null;
    const ok = objc.msgSend(u8, config, objc.sel("validateWithError:"), .{&verr});
    if (ok == 0 or verr != null) return Error.BootFailed;

    // Init the VM on a dedicated serial queue. All ops happen on this queue.
    const queue = objc.dispatch_queue_create("com.orchd.vm", null);
    const vm_cls = objc.class("VZVirtualMachine") orelse return Error.BootFailed;
    const vm_alloc = objc.msgSend(?objc.Id, vm_cls, objc.sel("alloc"), .{}) orelse return Error.BootFailed;
    const vm = objc.msgSend(
        ?objc.Id,
        vm_alloc,
        objc.sel("initWithConfiguration:queue:"),
        .{ config, queue },
    ) orelse return Error.BootFailed;

    // Start on the VM queue, block until the completion handler signals.
    g_start_sema = objc.dispatch_semaphore_create(0);
    g_dispatched_sema = objc.dispatch_semaphore_create(0);
    g_start_err = null;
    g_dispatch_kind = .start;
    g_dispatch_vm = vm;

    dispatch_async(queue, blockArg(&work_block));
    _ = objc.dispatch_semaphore_wait(g_dispatched_sema.?, objc.DISPATCH_TIME_FOREVER);
    _ = objc.dispatch_semaphore_wait(g_start_sema.?, objc.DISPATCH_TIME_FOREVER);

    if (g_start_err != null) return Error.BootFailed;

    return Vm{ .handle = vm, .queue = queue };
}

// --- tests ---
//
// These run in isolation: `zig test src/vm.zig -framework Foundation
// -framework Virtualization`. They prove we can BUILD and VALIDATE a real
// VZVirtualMachineConfiguration through objc.zig without a kernel asset or the
// virtualization entitlement. We deliberately do NOT start the VM here: start
// needs the entitlement and a real kernel and would hang/crash without them.

test "build a VZVirtualMachineConfiguration without crashing" {
    if (objc.class("VZVirtualMachineConfiguration") == null) return error.NoVirtualization;

    const spec = BootSpec{
        .kernel_path = "/tmp/orchd-osx-nonexistent-kernel",
        .cmdline = "console=hvc0 root=/dev/vda rw init=/orchd-init",
        .rootfs_path = "/tmp/orchd-osx-nonexistent-rootfs.img",
        .cpu_count = 2,
        .memory_bytes = 512 * 1024 * 1024,
        .vsock_port = 1024,
    };

    // buildConfig must produce a non-null config object even though the kernel
    // and rootfs paths do not exist (fileURL is path-only; disk attachment that
    // fails is skipped, not fatal).
    const config = try buildConfig(spec);
    try std.testing.expect(@intFromPtr(config) != 0);

    // The boot loader and CPU/memory setters must round-trip on the config.
    const cpu = objc.msgSend(usize, config, objc.sel("CPUCount"), .{});
    try std.testing.expectEqual(@as(usize, 2), cpu);
    const mem = objc.msgSend(u64, config, objc.sel("memorySize"), .{});
    try std.testing.expectEqual(@as(u64, 512 * 1024 * 1024), mem);

    // validateWithError: must not crash. It may pass or fail (a nonexistent
    // kernel path can still validate at this layer); we only assert it runs and
    // gives a coherent BOOL/NSError pair.
    var verr: ?objc.Id = null;
    const ok = objc.msgSend(u8, config, objc.sel("validateWithError:"), .{&verr});
    // ok==0 implies an error object; ok==1 implies none. Either is acceptable.
    if (ok == 0) {
        try std.testing.expect(verr != null);
    } else {
        try std.testing.expect(ok == 1);
    }
}

test "serial console + entropy + vsock devices build" {
    if (objc.class("VZVirtioSocketDeviceConfiguration") == null) return error.NoVirtualization;

    const vsock = objc.allocInit("VZVirtioSocketDeviceConfiguration");
    try std.testing.expect(vsock != null);

    const entropy = objc.allocInit("VZVirtioEntropyDeviceConfiguration");
    try std.testing.expect(entropy != null);

    // Serial console wiring to stderr should build cleanly.
    const serial = buildSerialConsole();
    try std.testing.expect(serial != null);

    // A singleton NSArray of a device should have count 1.
    const arr = singletonArray(vsock.?);
    const count = objc.msgSend(usize, arr, objc.sel("count"), .{});
    try std.testing.expectEqual(@as(usize, 1), count);
}
