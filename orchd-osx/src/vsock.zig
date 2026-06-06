//! vsock.zig — the HOST end of the host<->guest wire protocol.
//!
//! The guest counterpart is guest/init.zig. vm.zig's connect() hands us a
//! connected vsock file descriptor; from there the exchange is fixed:
//!   1. send exactly one Exec frame describing the process to run.
//!   2. read Stdout/Stderr frames, forwarding their bytes to the host's
//!      stdout/stderr, until an Exit frame carries the container's code.
//!
//! The wire format lives in proto.zig, which both ends compile, so the bytes
//! can never drift. We are on macOS with libc, so we use proto's libc-backed
//! framing directly (the guest reimplements the same frames over raw syscalls
//! because it is not linked against libc).

const std = @import("std");
const proto = @import("proto.zig");

// std.posix lacks write in this Zig; go straight to libSystem, same pattern as
// proto.zig. We only need write here for forwarding guest output.
extern "c" fn write(fd: proto.fd_t, buf: [*]const u8, nbyte: usize) callconv(.c) isize;

/// Drive one container to completion over an already-connected vsock fd.
///
/// Sends `spec` as the Exec frame, then forwards guest stdout to `out_fd` and
/// guest stderr to `err_fd` until the guest reports an exit code, which we
/// return. `out_fd`/`err_fd` let callers point the streams anywhere (host fd 1
/// and 2 in production; a pipe or file in tests).
pub fn run(
    allocator: std.mem.Allocator,
    fd: proto.fd_t,
    spec: proto.ExecSpec,
    out_fd: proto.fd_t,
    err_fd: proto.fd_t,
) !i32 {
    const encoded = try spec.encode(allocator);
    defer allocator.free(encoded);
    try proto.writeFrame(fd, .exec, encoded);

    while (true) {
        const frame = (try proto.readFrame(allocator, fd)) orelse return error.GuestClosed;
        defer allocator.free(frame.body);

        switch (frame.type) {
            .stdout => try writeAll(out_fd, frame.body),
            .stderr => try writeAll(err_fd, frame.body),
            .ipinfo => std.debug.print("orchd-osx: container ip {s}\n", .{frame.body}),
            .exit => {
                if (frame.body.len < 4) return error.Truncated;
                return std.mem.readInt(i32, frame.body[0..4], .little);
            },
            // exec is host->guest only; anything else is the guest misbehaving.
            else => return error.UnexpectedFrame,
        }
    }
}

/// Convenience wrapper that forwards to the host's own stdout (fd 1) and
/// stderr (fd 2). This is what production callers want.
pub fn runStdio(allocator: std.mem.Allocator, fd: proto.fd_t, spec: proto.ExecSpec) !i32 {
    return run(allocator, fd, spec, 1, 2);
}

fn writeAll(fd: proto.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = write(fd, bytes[off..].ptr, bytes.len - off);
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

// --- tests ---

const testing = std.testing;

extern "c" fn socketpair(domain: c_int, type: c_int, protocol: c_int, fds: *[2]c_int) callconv(.c) c_int;
extern "c" fn close(fd: c_int) callconv(.c) c_int;
extern "c" fn read(fd: proto.fd_t, buf: [*]u8, nbyte: usize) callconv(.c) isize;

const AF_UNIX: c_int = 1;
const SOCK_STREAM: c_int = 1;

test "run sends exec, forwards stdout/stderr, returns exit code" {
    const a = testing.allocator;

    // A socketpair stands in for the connected vsock: one end is the code under
    // test, the other end plays the guest.
    var sp: [2]c_int = undefined;
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, &sp) != 0) return error.SocketpairFailed;
    const host_fd: proto.fd_t = @intCast(sp[0]);
    const guest_fd: proto.fd_t = @intCast(sp[1]);
    defer _ = close(sp[0]);
    defer _ = close(sp[1]);

    // Capture forwarded output in a pipe so we can read it back and assert.
    var out_pipe: [2]proto.fd_t = undefined;
    var err_pipe: [2]proto.fd_t = undefined;
    if (pipe(&out_pipe) != 0) return error.PipeFailed;
    if (pipe(&err_pipe) != 0) return error.PipeFailed;
    defer _ = close(@intCast(out_pipe[0]));
    defer _ = close(@intCast(out_pipe[1]));
    defer _ = close(@intCast(err_pipe[0]));
    defer _ = close(@intCast(err_pipe[1]));

    const spec = proto.ExecSpec{
        .argv = &.{ "/bin/echo", "hello" },
        .env = &.{"PATH=/bin"},
        .cwd = "/srv",
    };

    // Play the guest on a thread: read the exec frame, then stream back
    // stdout, stderr, and a final exit(7).
    const guest = try std.Thread.spawn(.{}, guestPeer, .{ a, guest_fd });

    const code = try run(a, host_fd, spec, out_pipe[1], err_pipe[1]);
    guest.join();

    try testing.expectEqual(@as(i32, 7), code);

    // The guest echoed exactly what it received on each stream.
    var out_buf: [64]u8 = undefined;
    const out_n = read(out_pipe[0], &out_buf, out_buf.len);
    try testing.expect(out_n > 0);
    try testing.expectEqualStrings("out-bytes", out_buf[0..@intCast(out_n)]);

    var err_buf: [64]u8 = undefined;
    const err_n = read(err_pipe[0], &err_buf, err_buf.len);
    try testing.expect(err_n > 0);
    try testing.expectEqualStrings("err-bytes", err_buf[0..@intCast(err_n)]);
}

extern "c" fn pipe(fds: *[2]proto.fd_t) callconv(.c) c_int;

/// The fake guest: confirm the exec frame round-trips, then send back one
/// stdout frame, one stderr frame, and an exit frame carrying code 7.
fn guestPeer(a: std.mem.Allocator, fd: proto.fd_t) !void {
    const frame = (try proto.readFrame(a, fd)) orelse return error.NoExecFrame;
    defer a.free(frame.body);
    try testing.expectEqual(proto.MsgType.exec, frame.type);

    const spec = try proto.ExecSpec.decode(a, frame.body);
    defer spec.free(a);
    try testing.expectEqual(@as(usize, 2), spec.argv.len);
    try testing.expectEqualStrings("/bin/echo", spec.argv[0]);
    try testing.expectEqualStrings("hello", spec.argv[1]);
    try testing.expectEqualStrings("/srv", spec.cwd);

    try proto.writeFrame(fd, .stdout, "out-bytes");
    try proto.writeFrame(fd, .stderr, "err-bytes");
    try proto.writeFrame(fd, .exit, &std.mem.toBytes(@as(i32, 7)));
}
