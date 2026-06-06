//! vz.zig — the lifecycle facade for orchd-osx. Composes the modules into the
//! run/wait/stop/delete verbs orchd drives.
//!
//! Unlike the XPC path (where the daemon holds the container), an orchd-osx VM
//! lives INSIDE the `run` process: run boots the VM, runs the container's
//! process over vsock, and blocks until it exits. So `run` is the foreground
//! process launchd tracks, and it returns the container's exit code. `wait` is
//! therefore a no-op (run already blocked), and stop/delete tear down state.
//!
//! Pipeline (run):
//!   oci.resolve  image ref -> unpacked rootfs dir + process spec
//!   ext4.build   rootfs dir + our guest init -> ext4 image (/dev/vda)
//!   vm.boot      kernel + ext4 -> a running VM (init=/orchd-init)
//!   vm.connect   vsock port 1024 -> a raw fd
//!   vsock.run    send the exec spec, stream stdio, return the exit code

const std = @import("std");

const oci = @import("oci.zig");
const ext4 = @import("ext4.zig");
const cpio = @import("cpio.zig");
const vm = @import("vm.zig");
const vsock = @import("vsock.zig");
const kernel = @import("kernel.zig");
const proto = @import("proto.zig");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

pub const Error = error{
    NotImplemented,
    BootFailed,
    ImageFailed,
    Ext4Failed,
    ExecFailed,
    OutOfMemory,
    NoHome,
};

const VSOCK_PORT: u32 = 1024;
// initramfs boot: the kernel unpacks our cpio as root and runs /init from it.
// ip=dhcp makes the kernel autoconfigure eth0 from VZ's NAT DHCP at boot.
const KERNEL_CMDLINE = "console=hvc0 ip=dhcp";
const MEMORY: u64 = 1024 * 1024 * 1024;
const CPUS: usize = 2;

/// Boot a container for `image` and block until its process exits; returns the
/// exit code. This is the foreground process launchd tracks.
pub fn run(allocator: std.mem.Allocator, io: std.Io, id: []const u8, image: []const u8) Error!i64 {
    const work = try workDir(allocator, id);
    defer allocator.free(work);
    makePath(io, work);

    // 1. Resolve the image into a rootfs + process spec.
    const rootfs = try std.fmt.allocPrint(allocator, "{s}/rootfs", .{work});
    defer allocator.free(rootfs);
    const img = oci.resolve(allocator, io, work, image) catch |e| {
        std.debug.print("orchd-osx run: image resolve failed ({s})\n", .{@errorName(e)});
        return Error.ImageFailed;
    };

    const spec = proto.ExecSpec{ .argv = img.argv, .env = img.env, .cwd = img.cwd };
    return runRootfs(allocator, io, id, img.rootfs_dir, spec);
}

/// The integration core: given an unpacked rootfs and the process to run, build
/// the disk, boot the VM, and run the process over vsock. Returns the exit code.
pub fn runRootfs(
    allocator: std.mem.Allocator,
    io: std.Io,
    id: []const u8,
    rootfs_dir: []const u8,
    spec: proto.ExecSpec,
) Error!i64 {
    const work = try workDir(allocator, id);
    defer allocator.free(work);
    makePath(io, work);

    // 1. initramfs (cpio): the rootfs tree + our guest init at /init.
    const cpio_path = try std.fmt.allocPrint(allocator, "{s}/rootfs.cpio", .{work});
    defer allocator.free(cpio_path);
    const init_bytes = readInitBytes(allocator, io) catch |e| {
        std.debug.print("orchd-osx run: cannot read guest init ({s})\n", .{@errorName(e)});
        return Error.Ext4Failed;
    };
    defer allocator.free(init_bytes);

    cpio.build(allocator, io, rootfs_dir, cpio_path, init_bytes) catch |e| {
        std.debug.print("orchd-osx run: initramfs build failed ({s})\n", .{@errorName(e)});
        return Error.Ext4Failed;
    };

    // 2. Boot the VM (kernel + initramfs; no block-device root).
    const kpath = kernel.kernelPath(allocator) catch return Error.BootFailed;
    defer allocator.free(kpath);
    const kpath_z = try allocator.dupeZ(u8, kpath);
    defer allocator.free(kpath_z);
    const cpio_z = try allocator.dupeZ(u8, cpio_path);
    defer allocator.free(cpio_z);

    var machine = vm.boot(.{
        .kernel_path = kpath_z,
        .cmdline = KERNEL_CMDLINE,
        .rootfs_path = "/nonexistent-no-block",
        .ramdisk_path = cpio_z,
        .cpu_count = CPUS,
        .memory_bytes = MEMORY,
        .vsock_port = VSOCK_PORT,
    }) catch |e| {
        std.debug.print("orchd-osx run: VM boot failed ({s})\n", .{@errorName(e)});
        return Error.BootFailed;
    };
    defer machine.shutdown();

    // 3. Connect to the guest init and run the process.
    const fd = machine.connect(VSOCK_PORT) catch |e| {
        std.debug.print("orchd-osx run: vsock connect failed ({s})\n", .{@errorName(e)});
        return Error.ExecFailed;
    };

    const code = vsock.runStdio(allocator, fd, spec) catch |e| {
        std.debug.print("orchd-osx run: exec over vsock failed ({s})\n", .{@errorName(e)});
        return Error.ExecFailed;
    };
    return code;
}

/// wait: the VM lives in the run process, so by the time anything calls wait the
/// container has already exited. No-op success.
pub fn wait(allocator: std.mem.Allocator, id: []const u8) Error!i64 {
    _ = allocator;
    _ = id;
    return 0;
}

pub fn stop(allocator: std.mem.Allocator, id: []const u8) Error!void {
    _ = allocator;
    _ = id;
    // launchd SIGTERMs the run process, which tears its VM down. Nothing extra.
}

pub fn delete(allocator: std.mem.Allocator, id: []const u8) Error!void {
    const work = try workDir(allocator, id);
    defer allocator.free(work);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().deleteTree(io, work) catch {};
}

pub fn available() bool {
    return true;
}

// --- helpers ---

fn workDir(allocator: std.mem.Allocator, id: []const u8) Error![]u8 {
    const home_z = getenv("HOME") orelse return Error.NoHome;
    const home = std.mem.span(home_z);
    return std.fmt.allocPrint(allocator, "{s}/.orch/osx/run/{s}", .{ home, id }) catch
        return Error.OutOfMemory;
}

fn makePath(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().createDirPath(io, path) catch {};
}

/// Read the guest init binary bytes: $ORCHD_OSX_INIT, else next to this exe.
fn readInitBytes(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    if (getenv("ORCHD_OSX_INIT")) |p| {
        return std.Io.Dir.cwd().readFileAlloc(io, std.mem.span(p), allocator, .unlimited);
    }
    const dir = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(dir);
    const path = try std.fmt.allocPrint(allocator, "{s}/orchd-osx-init", .{dir});
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
}
