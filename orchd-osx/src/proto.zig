//! proto.zig — the host<->guest wire contract.
//!
//! Single source of truth for the bytes that cross the vsock connection. BOTH
//! ends compile this file: the host (vsock.zig) and our guest init
//! (guest/init.zig). Because it is one shared file, the wire can never drift.
//!
//! We own both ends, so this is deliberately tiny: no gRPC, no protobuf. A
//! length-prefixed frame, a one-byte type, a compact payload.
//!
//!   frame = u32 len (LE, payload bytes) ++ payload
//!   payload[0] = MsgType, payload[1..] = message body
//!
//! Flow: host connects to the guest's vsock port, sends one Exec frame, then
//! reads Stdout/Stderr frames until an Exit frame carries the code.

const std = @import("std");

pub const fd_t = std.posix.fd_t;

// libc primitives: resolve on the macOS host (libSystem) and the musl guest.
extern "c" fn read(fd: fd_t, buf: [*]u8, nbyte: usize) isize;
extern "c" fn write(fd: fd_t, buf: [*]const u8, nbyte: usize) isize;
extern "c" fn close(fd: fd_t) c_int;
extern "c" fn pipe(fds: *[2]fd_t) c_int;

pub const MsgType = enum(u8) {
    exec = 1, // host -> guest: ExecSpec
    stdout = 2, // guest -> host: raw bytes
    stderr = 3, // guest -> host: raw bytes
    exit = 4, // guest -> host: i32 exit code (LE)
    _,
};

/// What the host asks the guest to run. The rootfs is already mounted by the
/// guest (it is /dev/vda); this is the process to exec inside it.
pub const ExecSpec = struct {
    /// argv[0] is the executable. Must be non-empty.
    argv: []const []const u8,
    /// "KEY=VALUE" entries.
    env: []const []const u8 = &.{},
    /// Working directory inside the container; empty means "/".
    cwd: []const u8 = "",

    /// Encode into an owned byte buffer (caller frees). Layout:
    ///   u16 argc; { u16 len, bytes }*argc
    ///   u16 envc; { u16 len, bytes }*envc
    ///   u16 cwd_len, bytes
    pub fn encode(self: ExecSpec, allocator: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        try putList(allocator, &buf, self.argv);
        try putList(allocator, &buf, self.env);
        try putStr(allocator, &buf, self.cwd);
        return buf.toOwnedSlice(allocator);
    }

    /// Decode from a payload body (the bytes after the MsgType). Strings point
    /// into `body`, so `body` must outlive the returned spec; the two slices
    /// (argv, env) are allocated and owned by the caller (free with `free`).
    pub fn decode(allocator: std.mem.Allocator, body: []const u8) !ExecSpec {
        var p: usize = 0;
        const argv = try getList(allocator, body, &p);
        errdefer allocator.free(argv);
        const env = try getList(allocator, body, &p);
        errdefer allocator.free(env);
        const cwd = try getStr(body, &p);
        return .{ .argv = argv, .env = env, .cwd = cwd };
    }

    pub fn free(self: ExecSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.argv);
        allocator.free(self.env);
    }
};

// --- byte helpers ---

fn putStr(a: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.appendSlice(a, &std.mem.toBytes(@as(u16, @intCast(s.len))));
    try buf.appendSlice(a, s);
}

fn putList(a: std.mem.Allocator, buf: *std.ArrayList(u8), list: []const []const u8) !void {
    try buf.appendSlice(a, &std.mem.toBytes(@as(u16, @intCast(list.len))));
    for (list) |s| try putStr(a, buf, s);
}

fn getStr(body: []const u8, p: *usize) ![]const u8 {
    if (p.* + 2 > body.len) return error.Truncated;
    const len = std.mem.readInt(u16, body[p.*..][0..2], .little);
    p.* += 2;
    if (p.* + len > body.len) return error.Truncated;
    const s = body[p.* .. p.* + len];
    p.* += len;
    return s;
}

fn getList(a: std.mem.Allocator, body: []const u8, p: *usize) ![][]const u8 {
    if (p.* + 2 > body.len) return error.Truncated;
    const n = std.mem.readInt(u16, body[p.*..][0..2], .little);
    p.* += 2;
    const out = try a.alloc([]const u8, n);
    errdefer a.free(out);
    for (out) |*slot| slot.* = try getStr(body, p);
    return out;
}

// --- framing over a file descriptor (posix; works on host and guest) ---

pub const Frame = struct {
    type: MsgType,
    body: []u8, // owned by caller; free with `allocator.free`
};

/// Write one frame: u32 len ++ [type ++ payload].
pub fn writeFrame(fd: fd_t, t: MsgType, payload: []const u8) !void {
    var hdr: [5]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(payload.len + 1), .little);
    hdr[4] = @intFromEnum(t);
    try writeAll(fd, &hdr);
    try writeAll(fd, payload);
}

/// Read one frame. Returns null on clean EOF before any bytes. Caller frees
/// `Frame.body`.
pub fn readFrame(allocator: std.mem.Allocator, fd: fd_t) !?Frame {
    var hdr: [5]u8 = undefined;
    if (!try readAllOrEof(fd, &hdr)) return null;
    const len = std.mem.readInt(u32, hdr[0..4], .little);
    if (len == 0) return error.Truncated; // must include the type byte
    const body = try allocator.alloc(u8, len - 1);
    errdefer allocator.free(body);
    if (!try readAllOrEof(fd, body)) return error.Truncated;
    return .{ .type = @enumFromInt(hdr[4]), .body = body };
}

fn writeAll(fd: fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = write(fd, bytes[off..].ptr, bytes.len - off);
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

/// Read exactly buf.len bytes. Returns false on EOF before the first byte,
/// errors on EOF mid-buffer.
fn readAllOrEof(fd: fd_t, buf: []u8) !bool {
    var off: usize = 0;
    while (off < buf.len) {
        const n = read(fd, buf[off..].ptr, buf.len - off);
        if (n < 0) return error.ReadFailed;
        if (n == 0) {
            if (off == 0) return false;
            return error.Truncated;
        }
        off += @intCast(n);
    }
    return true;
}

// --- tests ---

test "ExecSpec encode/decode round-trip" {
    const a = std.testing.allocator;
    const spec = ExecSpec{
        .argv = &.{ "/bin/sh", "-c", "echo hi" },
        .env = &.{ "PATH=/bin", "TERM=dumb" },
        .cwd = "/srv",
    };
    const bytes = try spec.encode(a);
    defer a.free(bytes);

    const got = try ExecSpec.decode(a, bytes);
    defer got.free(a);
    try std.testing.expectEqual(@as(usize, 3), got.argv.len);
    try std.testing.expectEqualStrings("/bin/sh", got.argv[0]);
    try std.testing.expectEqualStrings("echo hi", got.argv[2]);
    try std.testing.expectEqual(@as(usize, 2), got.env.len);
    try std.testing.expectEqualStrings("TERM=dumb", got.env[1]);
    try std.testing.expectEqualStrings("/srv", got.cwd);
}

test "frame round-trip over a pipe" {
    const a = std.testing.allocator;
    var fds: [2]fd_t = undefined;
    if (pipe(&fds) != 0) return error.PipeFailed;
    defer _ = close(fds[0]);
    defer _ = close(fds[1]);

    try writeFrame(fds[1], .exit, &std.mem.toBytes(@as(i32, 42)));
    const frame = (try readFrame(a, fds[0])).?;
    defer a.free(frame.body);
    try std.testing.expectEqual(MsgType.exit, frame.type);
    const code = std.mem.readInt(i32, frame.body[0..4], .little);
    try std.testing.expectEqual(@as(i32, 42), code);
}
