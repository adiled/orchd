//! guest/init.zig — our PID 1 inside the container VM (static aarch64-linux).
//!
//! The guest counterpart of vsock.zig. Replaces Apple's vminitd entirely.
//! Responsibilities (in order):
//!   1. mount essentials (/proc, /sys, /dev); the ext4 rootfs is already /.
//!   2. open a vsock listener on the agreed port and accept the host.
//!   3. read one Exec frame (proto.ExecSpec) from the host.
//!   4. fork/exec the container process with that argv/env/cwd.
//!   5. stream child stdout/stderr back as Stdout/Stderr frames.
//!   6. reap the child and send an Exit frame with its code.
//!   7. power the VM off (PID 1 must not return).
//!
//! Shares the wire contract with the host by compiling ../proto.zig.
//!
//! Built for aarch64-linux (musl, static) by build.zig. The guest module is
//! NOT linked against libc, so we drive the kernel directly through
//! `std.os.linux` raw syscalls — no `extern "c"`. For the same reason we cannot
//! call proto.writeFrame/readFrame (those go through libc `read`/`write`); we
//! reimplement the identical frame format here over raw syscalls, reusing
//! proto.MsgType and proto.ExecSpec so the wire stays byte-for-byte compatible.

const std = @import("std");
const linux = std.os.linux;
const proto = @import("proto");

// ── Wire constants the host MUST match (see vm.zig connectToPort) ───────────
//
// The guest is the vsock LISTENER. The host connects to (CID of this VM, PORT).
//   - PORT 1024: arbitrary fixed port above the privileged range; the host's
//     connectToPort dials this same number.
//   - CID: we bind VMADDR_CID_ANY so the kernel accepts on whatever CID the
//     host assigned this VM. The host dials the VM's own CID; we need not know
//     it here.
pub const VSOCK_PORT: u32 = 1024;
pub const VMADDR_CID_ANY: u32 = 0xFFFFFFFF;

const fd_t = linux.fd_t; // i32

// ── entry point ─────────────────────────────────────────────────────────────

pub fn main() void {
    // PID 1 must never panic-exit silently. Funnel every error to the serial
    // console, then power off so the host stops waiting on a dead VM.
    run() catch |err| {
        report("orchd-init: fatal: ");
        report(@errorName(err));
        report("\n");
    };
    powerOff();
}

fn run() !void {
    mountEssentials();

    const listen_fd = try openListener(VSOCK_PORT);
    const conn = try sysFd(linux.accept(listen_fd, null, null), error.AcceptFailed);
    _ = linux.close(listen_fd);

    const a = std.heap.page_allocator;

    // Report our eth0 IPv4 to the host (best-effort) so it knows where the
    // container is reachable. The kernel configured eth0 via ip=dhcp pre-init.
    reportIp(conn);

    // Expect exactly one Exec frame to kick things off.
    const frame = (try readFrame(a, conn)) orelse return error.NoExecFrame;
    defer a.free(frame.body);
    if (frame.type != .exec) return error.UnexpectedFrame;

    const spec = try proto.ExecSpec.decode(a, frame.body);
    defer spec.free(a);

    const code = try runChild(a, conn, spec);
    try writeFrame(conn, .exit, &std.mem.toBytes(@as(i32, code)));
    _ = linux.close(conn);
}

// ── step 1: mounts (best-effort) ────────────────────────────────────────────

fn mountEssentials() void {
    // Ignore failures: EBUSY (already mounted) and friends are fine for a
    // first cut. These give us /proc, /sys and device nodes under /dev.
    _ = linux.mount("proc", "/proc", "proc", 0, 0);
    _ = linux.mount("sysfs", "/sys", "sysfs", 0, 0);
    _ = linux.mount("devtmpfs", "/dev", "devtmpfs", 0, 0);
}

/// Read eth0's IPv4 (set by the kernel's ip=dhcp) and send it to the host as an
/// ipinfo frame. Best-effort: any failure is silently skipped.
fn reportIp(conn: fd_t) void {
    const s = linux.socket(linux.AF.INET, linux.SOCK.DGRAM, 0);
    if (@as(isize, @bitCast(s)) < 0) return;
    const sock: fd_t = @intCast(s);
    defer _ = linux.close(sock);

    // struct ifreq: char ifr_name[16]; union { sockaddr ifr_addr; ... } (16 B).
    var req: [40]u8 = [_]u8{0} ** 40;
    const name = "eth0";
    @memcpy(req[0..name.len], name);

    const r = linux.ioctl(sock, linux.SIOCGIFADDR, @intFromPtr(&req));
    if (@as(isize, @bitCast(r)) < 0) return;

    // ifr_addr is a sockaddr at offset 16; sockaddr_in.sin_addr is at +4 -> 20.
    const ip = req[20..24];
    var buf: [16]u8 = undefined;
    const s_ip = std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] }) catch return;
    writeFrame(conn, .ipinfo, s_ip) catch {};
}

// ── step 2: vsock listener ──────────────────────────────────────────────────

fn openListener(port: u32) !fd_t {
    const fd = try sysFd(linux.socket(linux.AF.VSOCK, linux.SOCK.STREAM, 0), error.SocketFailed);

    const addr = linux.sockaddr.vm{
        .port = port,
        .cid = VMADDR_CID_ANY,
        .flags = 0,
    };
    const sa: *const linux.sockaddr = @ptrCast(&addr);
    if (linux.errno(linux.bind(fd, sa, @sizeOf(linux.sockaddr.vm))) != .SUCCESS) {
        return error.BindFailed;
    }
    if (linux.errno(linux.listen(fd, 1)) != .SUCCESS) return error.ListenFailed;
    return fd;
}

// ── steps 4+5: fork/exec the child, stream its stdio ────────────────────────

/// Fork the container process, stream its stdout/stderr to `conn`, and return
/// its exit code. `spec` argv/env/cwd describe the process to run.
fn runChild(a: std.mem.Allocator, conn: fd_t, spec: proto.ExecSpec) !u8 {
    if (spec.argv.len == 0) return error.EmptyArgv;

    const argv = try buildNullTerminated(a, spec.argv);
    defer a.free(argv);
    const envp = try buildNullTerminated(a, spec.env);
    defer a.free(envp);
    const cwd = try dupZ(a, if (spec.cwd.len == 0) "/" else spec.cwd);
    defer a.free(cwd);

    var out_pipe: [2]fd_t = undefined;
    var err_pipe: [2]fd_t = undefined;
    if (linux.errno(linux.pipe2(&out_pipe, .{})) != .SUCCESS) return error.PipeFailed;
    if (linux.errno(linux.pipe2(&err_pipe, .{})) != .SUCCESS) return error.PipeFailed;

    const pid: i32 = @bitCast(@as(u32, @truncate(linux.fork())));
    if (pid < 0) return error.ForkFailed;

    if (pid == 0) {
        // ── child ──
        // Wire stdin from /dev/null, stdout/stderr to the pipe write ends.
        const null_fd: i32 = @bitCast(@as(u32, @truncate(linux.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0))));
        if (null_fd >= 0) _ = linux.dup2(null_fd, 0);
        _ = linux.dup2(out_pipe[1], 1);
        _ = linux.dup2(err_pipe[1], 2);
        // Close the now-duplicated descriptors.
        _ = linux.close(out_pipe[0]);
        _ = linux.close(out_pipe[1]);
        _ = linux.close(err_pipe[0]);
        _ = linux.close(err_pipe[1]);
        if (null_fd >= 0) _ = linux.close(null_fd);

        _ = linux.chdir(cwd.ptr);
        _ = linux.execve(argv[0].?, argv.ptr, envp.ptr);
        // execve only returns on failure.
        linux.exit(127);
    }

    // ── parent ──
    _ = linux.close(out_pipe[1]);
    _ = linux.close(err_pipe[1]);
    try streamStdio(conn, out_pipe[0], err_pipe[0]);
    _ = linux.close(out_pipe[0]);
    _ = linux.close(err_pipe[0]);

    var status: u32 = 0;
    if (linux.errno(linux.wait4(pid, &status, 0, null)) != .SUCCESS) return error.WaitFailed;
    return exitCode(status);
}

/// Drain both pipes concurrently via poll(), forwarding each chunk as a Stdout
/// or Stderr frame. Returns once both pipes hit EOF. Using poll() (rather than
/// a sequential read-after-exit) keeps memory bounded and avoids deadlock when
/// the child fills one pipe while we are blocked reading the other.
fn streamStdio(conn: fd_t, out_fd: fd_t, err_fd: fd_t) !void {
    const POLLIN: i16 = linux.POLL.IN;
    const POLLHUP: i16 = linux.POLL.HUP;
    const POLLERR: i16 = linux.POLL.ERR;
    const POLLNVAL: i16 = linux.POLL.NVAL;

    var buf: [16 * 1024]u8 = undefined;
    var fds = [2]linux.pollfd{
        .{ .fd = out_fd, .events = POLLIN, .revents = 0 },
        .{ .fd = err_fd, .events = POLLIN, .revents = 0 },
    };
    const kinds = [2]proto.MsgType{ .stdout, .stderr };
    var open_count: usize = 2;

    while (open_count > 0) {
        if (linux.errno(linux.poll(&fds, fds.len, -1)) != .SUCCESS) return error.PollFailed;

        for (&fds, 0..) |*pf, i| {
            if (pf.fd < 0) continue;
            if (pf.revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL) == 0) continue;

            const got = readOnce(pf.fd, &buf);
            if (got > 0) {
                try writeFrame(conn, kinds[i], buf[0..got]);
            } else {
                // EOF (got == 0) or error: retire this pipe.
                pf.fd = -1;
                pf.events = 0;
                open_count -= 1;
            }
        }
    }
}

// ── framing over a raw fd (mirrors proto's wire format, libc-free) ──────────
//
//   frame = u32 len (LE, payload bytes incl. type) ++ MsgType ++ body
//
// Identical to proto.writeFrame/readFrame; reimplemented because the guest
// module is not linked against libc and proto's helpers use `extern "c"`.

fn writeFrame(fd: fd_t, t: proto.MsgType, payload: []const u8) !void {
    var hdr: [5]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(payload.len + 1), .little);
    hdr[4] = @intFromEnum(t);
    try writeAll(fd, &hdr);
    try writeAll(fd, payload);
}

fn readFrame(a: std.mem.Allocator, fd: fd_t) !?proto.Frame {
    var hdr: [5]u8 = undefined;
    if (!try readAllOrEof(fd, &hdr)) return null;
    const len = std.mem.readInt(u32, hdr[0..4], .little);
    if (len == 0) return error.Truncated; // must include the type byte
    const body = try a.alloc(u8, len - 1);
    errdefer a.free(body);
    if (!try readAllOrEof(fd, body)) return error.Truncated;
    return .{ .type = @enumFromInt(hdr[4]), .body = body };
}

fn writeAll(fd: fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const r = linux.write(fd, bytes[off..].ptr, bytes.len - off);
        if (linux.errno(r) != .SUCCESS) return error.WriteFailed;
        const n: usize = r; // success => non-negative
        if (n == 0) return error.WriteFailed;
        off += n;
    }
}

/// Read exactly buf.len bytes. Returns false on EOF before the first byte,
/// errors on EOF mid-buffer.
fn readAllOrEof(fd: fd_t, buf: []u8) !bool {
    var off: usize = 0;
    while (off < buf.len) {
        const r = linux.read(fd, buf[off..].ptr, buf.len - off);
        if (linux.errno(r) != .SUCCESS) return error.ReadFailed;
        const n: usize = r;
        if (n == 0) {
            if (off == 0) return false;
            return error.Truncated;
        }
        off += n;
    }
    return true;
}

/// One read() into `buf`, returning the byte count (0 = EOF, errors counted as
/// 0 so the caller retires the pipe).
fn readOnce(fd: fd_t, buf: []u8) usize {
    const r = linux.read(fd, buf.ptr, buf.len);
    if (linux.errno(r) != .SUCCESS) return 0;
    return r;
}

// ── pure helpers (obviously correct by reading) ─────────────────────────────

/// Decode a wait4 status word into a 0..=255 exit code, mirroring
/// WIFEXITED/WEXITSTATUS and WTERMSIG. A signalled child reports 128+signal,
/// the shell convention.
fn exitCode(status: u32) u8 {
    if (linux.W.IFEXITED(status)) return linux.W.EXITSTATUS(status);
    // Terminated by a signal: 128 + signo (low 7 bits).
    return @intCast(128 + (status & 0x7f));
}

/// Copy `s` into a fresh NUL-terminated buffer owned by the caller.
fn dupZ(a: std.mem.Allocator, s: []const u8) ![:0]u8 {
    const out = try a.allocSentinel(u8, s.len, 0);
    @memcpy(out, s);
    return out;
}

/// Turn a slice of byte-slices into a NUL-terminated array of C strings ending
/// in a null pointer, as execve() wants for argv/envp. Each string and the
/// outer array are owned by the caller; freeing the array leaks the individual
/// strings, which is fine here: the parent exits right after exec and the child
/// replaces its image.
fn buildNullTerminated(
    a: std.mem.Allocator,
    items: []const []const u8,
) ![:null]?[*:0]const u8 {
    const out = try a.allocSentinel(?[*:0]const u8, items.len, null);
    for (items, 0..) |item, i| {
        const z = try dupZ(a, item);
        out[i] = z.ptr;
    }
    return out;
}

// ── tiny console + shutdown ─────────────────────────────────────────────────

/// Map a raw syscall return into an fd or an error.
fn sysFd(ret: usize, err: anyerror) !fd_t {
    if (linux.errno(ret) != .SUCCESS) return err;
    return @intCast(ret);
}

/// Write to fd 2 (the VM serial console). Best-effort; ignore short writes.
fn report(msg: []const u8) void {
    _ = linux.write(2, msg.ptr, msg.len);
}

/// Power the VM off. PID 1 must not return; if reboot() somehow fails (e.g.
/// not actually PID 1 in a test), spin so the kernel does not panic on a
/// returning init.
fn powerOff() noreturn {
    _ = linux.reboot(.MAGIC1, .MAGIC2, .POWER_OFF, null);
    while (true) {}
}
