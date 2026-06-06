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
//!   cpio.build   rootfs dir + our guest init -> initramfs image
//!   vm.boot      kernel + initramfs -> a running VM (runs /init)
//!   vm.connect   vsock port 1024 -> a raw fd
//!   vsock.run    send the exec spec, stream stdio, return the exit code

const std = @import("std");

const oci = @import("oci.zig");
const cpio = @import("cpio.zig");
const vm = @import("vm.zig");
const vsock = @import("vsock.zig");
const kernel = @import("kernel.zig");
const proto = @import("proto.zig");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn getpid() c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn signal(sig: c_int, handler: *const fn (c_int) callconv(.c) void) usize;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn _exit(code: c_int) noreturn;

const SIGTERM: c_int = 15;
const SIGINT: c_int = 2;

// The active run's pidfile, so the SIGTERM handler can clean it up. orchd-osx
// runs one container per process.
var g_pidfile: ?[:0]const u8 = null;

/// On stop (SIGTERM from `orchd-osx stop`, or launchd), unlink the pidfile and
/// exit. The VM is owned by this process, so exiting tears it down cleanly with
/// no orphan (unlike the daemon model).
fn onTerm(_: c_int) callconv(.c) void {
    if (g_pidfile) |p| _ = unlink(p.ptr);
    _exit(0);
}

pub const Error = error{
    NotImplemented,
    BootFailed,
    ImageFailed,
    RootfsFailed,
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

/// Cached image process config, stored next to the unpacked rootfs so re-runs
/// need no re-pull. Entrypoint and Cmd are kept separate for override semantics.
const CacheMeta = struct {
    entrypoint: []const []const u8 = &.{},
    cmd: []const []const u8 = &.{},
    env: []const []const u8 = &.{},
    cwd: []const u8 = "/",
};

/// Service overrides layered on top of the image defaults (from `run --spec`).
pub const Overrides = struct {
    env: []const []const u8 = &.{}, // KEY=VALUE merged after the image env
    entrypoint: ?[]const u8 = null,
    cmd: ?[]const u8 = null,
    workdir: ?[]const u8 = null,
};

/// Boot a container for `image` and block until its process exits; returns the
/// exit code. This is the foreground process launchd tracks.
///
/// Images are cached: the unpacked rootfs + its config live under
/// ~/.orch/osx/images/<ref>, so an image is pulled at most once. `ov` layers the
/// Service config (env/cmd/entrypoint/workdir) on top of the image defaults.
pub fn run(allocator: std.mem.Allocator, io: std.Io, id: []const u8, image: []const u8, ov: Overrides) Error!i64 {
    // Ensure the image is pulled + cached (no-op if already cached).
    try pullImage(allocator, io, image);

    const cache = try imageCacheDir(allocator, image);
    defer allocator.free(cache);
    const rootfs = try std.fmt.allocPrint(allocator, "{s}/rootfs", .{cache});
    defer allocator.free(rootfs);
    const meta_path = try std.fmt.allocPrint(allocator, "{s}/config.json", .{cache});
    defer allocator.free(meta_path);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const data = std.Io.Dir.cwd().readFileAlloc(io, meta_path, arena, .unlimited) catch
        return Error.ImageFailed;
    const base = std.json.parseFromSliceLeaky(CacheMeta, arena, data, .{}) catch
        return Error.ImageFailed;

    const spec = applyOverrides(arena, base, ov) catch return Error.ImageFailed;
    return runRootfs(allocator, io, id, rootfs, spec);
}

/// Pull `image` into the cache if it is not already there. Idempotent: a no-op
/// on a cache hit. This is what the `pull` / pre_start step runs.
pub fn pullImage(allocator: std.mem.Allocator, io: std.Io, image: []const u8) Error!void {
    const cache = try imageCacheDir(allocator, image);
    defer allocator.free(cache);
    const meta_path = try std.fmt.allocPrint(allocator, "{s}/config.json", .{cache});
    defer allocator.free(meta_path);

    if (fileExists(meta_path)) return; // already cached

    makePath(io, cache);
    const img = oci.resolve(allocator, io, cache, image) catch |e| {
        std.debug.print("orchd-osx pull: image resolve failed ({s})\n", .{@errorName(e)});
        return Error.ImageFailed;
    };
    const base = CacheMeta{ .entrypoint = img.entrypoint, .cmd = img.cmd, .env = img.env, .cwd = img.cwd };
    if (std.json.Stringify.valueAlloc(allocator, base, .{})) |j| {
        defer allocator.free(j);
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = meta_path, .data = j }) catch {};
    } else |_| {}
}

/// Compose the final ExecSpec from the image defaults + Service overrides, with
/// Docker semantics: entrypoint set replaces the executable (and clears the
/// image Cmd unless a cmd override is also given); cmd set replaces the
/// arguments; env is the image env with the service env appended (later wins).
fn applyOverrides(arena: std.mem.Allocator, base: CacheMeta, ov: Overrides) !proto.ExecSpec {
    var argv: std.ArrayList([]const u8) = .empty;
    if (ov.entrypoint) |ep| {
        try splitInto(arena, &argv, ep);
    } else {
        for (base.entrypoint) |s| try argv.append(arena, s);
    }
    if (ov.cmd) |c| {
        try splitInto(arena, &argv, c);
    } else if (ov.entrypoint == null) {
        for (base.cmd) |s| try argv.append(arena, s);
    }

    var env: std.ArrayList([]const u8) = .empty;
    for (base.env) |e| try env.append(arena, e);
    for (ov.env) |e| try env.append(arena, e);

    return .{
        .argv = try argv.toOwnedSlice(arena),
        .env = try env.toOwnedSlice(arena),
        .cwd = if (ov.workdir) |w| w else base.cwd,
    };
}

/// Split `s` on ASCII spaces into non-empty tokens, appending to `list`.
fn splitInto(arena: std.mem.Allocator, list: *std.ArrayList([]const u8), s: []const u8) !void {
    var it = std.mem.tokenizeScalar(u8, s, ' ');
    while (it.next()) |tok| try list.append(arena, tok);
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

    // pidfile + signal handlers: `orchd-osx stop <id>` (or launchd) SIGTERMs
    // this process; we exit and the VM dies with us. This is the up/down
    // interface: run holds the container, stop ends it.
    const pidfile = std.fmt.allocPrint(allocator, "{s}/pid", .{work}) catch null;
    if (pidfile) |pf| {
        const pfz = allocator.dupeZ(u8, pf) catch null;
        allocator.free(pf);
        if (pfz) |z| {
            g_pidfile = z;
            writePidfile(io, z);
            _ = signal(SIGTERM, &onTerm);
            _ = signal(SIGINT, &onTerm);
        }
    }
    defer if (g_pidfile) |z| {
        _ = unlink(z.ptr);
    };

    // 1. initramfs (cpio): the rootfs tree + our guest init at /init.
    const cpio_path = try std.fmt.allocPrint(allocator, "{s}/rootfs.cpio", .{work});
    defer allocator.free(cpio_path);
    const init_bytes = readInitBytes(allocator, io) catch |e| {
        std.debug.print("orchd-osx run: cannot read guest init ({s})\n", .{@errorName(e)});
        return Error.RootfsFailed;
    };
    defer allocator.free(init_bytes);

    cpio.build(allocator, io, rootfs_dir, cpio_path, init_bytes) catch |e| {
        std.debug.print("orchd-osx run: initramfs build failed ({s})\n", .{@errorName(e)});
        return Error.RootfsFailed;
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
    const work = try workDir(allocator, id);
    defer allocator.free(work);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const pidpath = std.fmt.allocPrint(allocator, "{s}/pid", .{work}) catch return Error.OutOfMemory;
    defer allocator.free(pidpath);
    const data = std.Io.Dir.cwd().readFileAlloc(io, pidpath, allocator, .unlimited) catch return; // not running
    defer allocator.free(data);
    const pid = std.fmt.parseInt(c_int, std.mem.trim(u8, data, " \n\r\t"), 10) catch return;
    _ = kill(pid, SIGTERM); // the run process exits and the VM tears down
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

/// Per-image cache dir, keyed by a filesystem-safe form of the reference.
fn imageCacheDir(allocator: std.mem.Allocator, image: []const u8) Error![]u8 {
    const home_z = getenv("HOME") orelse return Error.NoHome;
    const home = std.mem.span(home_z);
    const safe = allocator.dupe(u8, image) catch return Error.OutOfMemory;
    defer allocator.free(safe);
    for (safe) |*c| {
        if (!std.ascii.isAlphanumeric(c.*) and c.* != '.' and c.* != '-' and c.* != '_') c.* = '_';
    }
    return std.fmt.allocPrint(allocator, "{s}/.orch/osx/images/{s}", .{ home, safe }) catch
        return Error.OutOfMemory;
}

extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;

fn fileExists(path: []const u8) bool {
    var buf: [1024]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return access(@ptrCast(&buf), 0) == 0;
}

fn makePath(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().createDirPath(io, path) catch {};
}

/// Write this process's pid to `path` so `stop` can find and signal it.
fn writePidfile(io: std.Io, path: [:0]const u8) void {
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{getpid()}) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = s }) catch {};
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
