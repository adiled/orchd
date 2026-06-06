//! portfwd.zig — HOST-side TCP port forwarding for orchd-osx.
//!
//! The VM gets a NAT IP the macOS host can reach directly (e.g.
//! "192.168.65.5"). To make a container's *published* ports usable from the
//! host (e.g. `curl localhost:8080`) we run a tiny userspace proxy: for each
//! requested forward we bind a listening socket on the host and, for every
//! accepted connection, dial guest_ip:guest_port and shovel bytes both ways
//! until either side hangs up.
//!
//! This is HOST code (aarch64-apple-darwin, linked against libc). Rather than
//! lean on std.net — which is mid-rework in Zig 0.16 and now lives under
//! std.Io — we talk to the BSD sockets layer through plain `extern "c"`
//! declarations, the same approach the rest of orchd-osx uses for syscalls
//! (see vsock.zig). Blocking sockets + thread-per-connection keeps it simple
//! and robust; the threads run for the life of the process.

const std = @import("std");

pub const Forward = struct {
    host_port: u16,
    guest_port: u16,
    address: ?[]const u8 = null, // bind address; null/empty -> "127.0.0.1"
};

// --- libc / BSD sockets (Darwin ABI) ---------------------------------------

const socklen_t = u32;

// Darwin's sockaddr_in. Note the leading sin_len byte (BSD-ism) and that
// sin_port / sin_addr are stored in network byte order (big-endian).
const sockaddr_in = extern struct {
    len: u8 = @sizeOf(sockaddr_in),
    family: u8 = AF_INET,
    port: u16, // network byte order
    addr: u32, // network byte order
    zero: [8]u8 = .{0} ** 8,
};

// Well-known, ABI-stable Darwin constants.
const AF_INET: u8 = 2;
const SOCK_STREAM: c_int = 1;
const IPPROTO_TCP: c_int = 6;
const SOL_SOCKET: c_int = 0xffff;
const SO_REUSEADDR: c_int = 0x0004;
const SHUT_WR: c_int = 1;

extern "c" fn socket(domain: c_int, type: c_int, protocol: c_int) callconv(.c) c_int;
extern "c" fn bind(fd: c_int, addr: *const sockaddr_in, len: socklen_t) callconv(.c) c_int;
extern "c" fn listen(fd: c_int, backlog: c_int) callconv(.c) c_int;
extern "c" fn accept(fd: c_int, addr: ?*sockaddr_in, len: ?*socklen_t) callconv(.c) c_int;
extern "c" fn connect(fd: c_int, addr: *const sockaddr_in, len: socklen_t) callconv(.c) c_int;
extern "c" fn setsockopt(fd: c_int, level: c_int, optname: c_int, optval: *const anyopaque, optlen: socklen_t) callconv(.c) c_int;
extern "c" fn shutdown(fd: c_int, how: c_int) callconv(.c) c_int;
extern "c" fn close(fd: c_int) callconv(.c) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, nbyte: usize) callconv(.c) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, nbyte: usize) callconv(.c) isize;

// --- public API ------------------------------------------------------------

/// Spawn one detached listener thread per forward. Each binds
/// (address orelse "127.0.0.1"):host_port and proxies every accepted TCP
/// connection to guest_ip:guest_port, copying bytes in both directions.
/// Best-effort: a port that fails to bind is reported to stderr and skipped.
/// Threads run for the lifetime of the process (orchd-osx exits when the
/// container exits, which tears them down); this function returns immediately
/// after spawning them. guest_ip is copied internally (caller may free it).
pub fn spawnAll(allocator: std.mem.Allocator, guest_ip: []const u8, fwds: []const Forward) void {
    if (fwds.len == 0) return;

    // The guest IP outlives this call because the listener threads do; copy it
    // onto the heap once and share it. Leaking is acceptable: these threads
    // live until the process exits.
    const guest_ip_copy = allocator.dupe(u8, guest_ip) catch {
        std.debug.print("portfwd: out of memory copying guest ip\n", .{});
        return;
    };

    const guest_addr = parseIp4(guest_ip_copy) orelse {
        std.debug.print("portfwd: bad guest ip '{s}'\n", .{guest_ip_copy});
        return;
    };

    for (fwds) |fwd| {
        const bind_str = blk: {
            const a = fwd.address orelse break :blk "127.0.0.1";
            if (a.len == 0) break :blk "127.0.0.1";
            break :blk a;
        };

        const bind_addr = parseIp4(bind_str) orelse {
            std.debug.print("portfwd: bad bind address '{s}'\n", .{bind_str});
            continue;
        };

        // Each listener owns its own config struct on the heap (intentionally
        // leaked) so it survives independently of this stack frame.
        const cfg = allocator.create(Listener) catch {
            std.debug.print("portfwd: out of memory\n", .{});
            continue;
        };
        cfg.* = .{
            .allocator = allocator,
            .bind_str = bind_str, // points into caller/fwd memory; only used for messages
            .bind_addr = bind_addr,
            .host_port = fwd.host_port,
            .guest_addr = guest_addr,
            .guest_port = fwd.guest_port,
        };

        const thread = std.Thread.spawn(.{}, listenerMain, .{cfg}) catch |err| {
            std.debug.print("portfwd: failed to spawn listener for port {d}: {s}\n", .{ fwd.host_port, @errorName(err) });
            continue;
        };
        thread.detach();
    }
}

// --- listener --------------------------------------------------------------

const Listener = struct {
    allocator: std.mem.Allocator,
    bind_str: []const u8,
    bind_addr: u32, // network byte order
    host_port: u16,
    guest_addr: u32, // network byte order
    guest_port: u16,
};

fn listenerMain(cfg: *Listener) void {
    const lfd = socket(@as(c_int, AF_INET), SOCK_STREAM, IPPROTO_TCP);
    if (lfd < 0) {
        std.debug.print("portfwd: socket() failed for {s}:{d}\n", .{ cfg.bind_str, cfg.host_port });
        return;
    }

    const one: c_int = 1;
    _ = setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, @sizeOf(c_int));

    var addr = sockaddr_in{
        .port = std.mem.nativeToBig(u16, cfg.host_port),
        .addr = cfg.bind_addr,
    };

    if (bind(lfd, &addr, @sizeOf(sockaddr_in)) != 0) {
        std.debug.print("portfwd: bind {s}:{d} failed: errno {d}\n", .{ cfg.bind_str, cfg.host_port, lastErrno() });
        _ = close(lfd);
        return;
    }

    if (listen(lfd, 128) != 0) {
        std.debug.print("portfwd: listen {s}:{d} failed: errno {d}\n", .{ cfg.bind_str, cfg.host_port, lastErrno() });
        _ = close(lfd);
        return;
    }
    std.debug.print("portfwd: listening {s}:{d} -> guest:{d}\n", .{ cfg.bind_str, cfg.host_port, cfg.guest_port });

    while (true) {
        const cfd = accept(lfd, null, null);
        if (cfd < 0) {
            // Transient errors (EINTR etc.) shouldn't kill the listener; just
            // retry. A persistent failure here would spin, but accept() on a
            // healthy listening socket effectively never fails permanently.
            continue;
        }

        const conn = cfg.allocator.create(Conn) catch {
            _ = close(cfd);
            continue;
        };
        conn.* = .{
            .allocator = cfg.allocator,
            .client_fd = cfd,
            .guest_addr = cfg.guest_addr,
            .guest_port = cfg.guest_port,
        };

        const t = std.Thread.spawn(.{}, connMain, .{conn}) catch {
            _ = close(cfd);
            cfg.allocator.destroy(conn);
            continue;
        };
        t.detach();
    }
}

// --- per-connection proxy --------------------------------------------------

const Conn = struct {
    allocator: std.mem.Allocator,
    client_fd: c_int,
    guest_addr: u32, // network byte order
    guest_port: u16,
};

fn connMain(conn: *Conn) void {
    defer conn.allocator.destroy(conn);
    defer _ = close(conn.client_fd);

    const gfd = socket(@as(c_int, AF_INET), SOCK_STREAM, IPPROTO_TCP);
    if (gfd < 0) return;
    defer _ = close(gfd);

    var gaddr = sockaddr_in{
        .port = std.mem.nativeToBig(u16, conn.guest_port),
        .addr = conn.guest_addr,
    };
    if (connect(gfd, &gaddr, @sizeOf(sockaddr_in)) != 0) {
        std.debug.print("portfwd: connect guest:{d} failed: errno {d}\n", .{ conn.guest_port, lastErrno() });
        return;
    }

    // One pump thread carries client -> guest; this thread carries guest ->
    // client. When either direction hits EOF we half-close the peer so the
    // other pump can drain and finish, then both sockets close on return.
    const pump = conn.allocator.create(Pump) catch return;
    pump.* = .{ .src = conn.client_fd, .dst = gfd };
    const t = std.Thread.spawn(.{}, pumpMain, .{ pump, conn.allocator }) catch {
        conn.allocator.destroy(pump);
        return;
    };

    copyLoop(gfd, conn.client_fd);
    t.join();
}

const Pump = struct {
    src: c_int,
    dst: c_int,
};

fn pumpMain(pump: *Pump, allocator: std.mem.Allocator) void {
    defer allocator.destroy(pump);
    copyLoop(pump.src, pump.dst);
}

/// Copy bytes from src to dst until src reaches EOF (or errors), then
/// half-close dst's write side so the peer sees the EOF. Best-effort: any
/// error simply ends the copy.
fn copyLoop(src: c_int, dst: c_int) void {
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = read(src, &buf, buf.len);
        if (n <= 0) break; // 0 => EOF, <0 => error
        if (!writeAll(dst, buf[0..@intCast(n)])) break;
    }
    _ = shutdown(dst, SHUT_WR);
}

fn writeAll(fd: c_int, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = write(fd, bytes[off..].ptr, bytes.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

// --- helpers ---------------------------------------------------------------

/// Parse a dotted-quad IPv4 string ("a.b.c.d") into a u32 in network byte
/// order, suitable for sockaddr_in.addr. Returns null on any malformed input.
fn parseIp4(s: []const u8) ?u32 {
    var octets: [4]u8 = undefined;
    var idx: usize = 0;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |part| {
        if (idx >= 4) return null;
        if (part.len == 0) return null;
        const v = std.fmt.parseInt(u8, part, 10) catch return null;
        octets[idx] = v;
        idx += 1;
    }
    if (idx != 4) return null;
    // sockaddr_in.addr holds the address in network byte order, i.e. the four
    // octets laid out in memory as octets[0..4]. readInt(.little) reinterprets
    // that byte sequence as a u32 whose in-memory representation is exactly
    // those bytes in order, so storing it back to the struct reproduces the
    // wire layout regardless of host endianness.
    return std.mem.readInt(u32, &octets, .little);
}

extern "c" fn __error() callconv(.c) *c_int; // Darwin's errno location
fn lastErrno() c_int {
    return __error().*;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "spawnAll with empty list returns cleanly" {
    spawnAll(testing.allocator, "192.168.65.5", &.{});
}

test "parseIp4 valid and invalid" {
    // 127.0.0.1 -> network order: bytes 127,0,0,1
    const v = parseIp4("127.0.0.1").?;
    const bytes = std.mem.toBytes(v);
    try testing.expectEqual(@as(u8, 127), bytes[0]);
    try testing.expectEqual(@as(u8, 0), bytes[1]);
    try testing.expectEqual(@as(u8, 0), bytes[2]);
    try testing.expectEqual(@as(u8, 1), bytes[3]);

    try testing.expect(parseIp4("") == null);
    try testing.expect(parseIp4("1.2.3") == null);
    try testing.expect(parseIp4("1.2.3.4.5") == null);
    try testing.expect(parseIp4("256.0.0.1") == null);
    try testing.expect(parseIp4("a.b.c.d") == null);
    try testing.expect(parseIp4("1..2.3") == null);
}

test "Forward default address is null" {
    const f = Forward{ .host_port = 8080, .guest_port = 80 };
    try testing.expect(f.address == null);
}
