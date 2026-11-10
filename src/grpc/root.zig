const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const posix = std.posix;
const testing = std.testing;
const c = @import("nghttp2");

pub const pb = @import("pb.zig");

pub const Status = struct {
    code: u32 = 0,
    message: []const u8 = "",
};

pub const Options = struct {
    interrupt: ?*const std.atomic.Value(bool) = null,
    timeout: ?Io.Duration = null,
};

const Call = struct {
    stream_id: i32 = -1,
    body: []const u8 = "",
    sent: usize = 0,
    data: std.ArrayList(u8) = .empty,
    grpc_status: ?u32 = null,
    grpc_message: []const u8 = "",
    http_status: []const u8 = "",
    closed: bool = false,
    reset: u32 = 0,
};

pub const Conn = struct {
    arena: Allocator,
    io: Io,
    stream: Io.net.Stream,
    session: *c.nghttp2_session,
    namespace: []const u8,
    call: Call = .{},
    status: Status = .{},

    pub fn open(arena: Allocator, io: Io, socket_path: []const u8, namespace: []const u8) !*Conn {
        const address = try Io.net.UnixAddress.init(socket_path);
        const stream = try address.connect(io);
        errdefer stream.close(io);

        const conn = try arena.create(Conn);
        conn.* = .{ .arena = arena, .io = io, .stream = stream, .session = undefined, .namespace = namespace };

        var callbacks: ?*c.nghttp2_session_callbacks = null;
        if (c.nghttp2_session_callbacks_new(&callbacks) != 0) return error.OutOfMemory;
        defer c.nghttp2_session_callbacks_del(callbacks);
        c.nghttp2_session_callbacks_set_on_header_callback(callbacks, onHeader);
        c.nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, onData);
        c.nghttp2_session_callbacks_set_on_stream_close_callback(callbacks, onClose);

        var session: ?*c.nghttp2_session = null;
        if (c.nghttp2_session_client_new(&session, callbacks, conn) != 0) return error.OutOfMemory;
        conn.session = session.?;

        const window: i32 = 1 << 24;
        const settings = [_]c.nghttp2_settings_entry{
            .{ .settings_id = c.NGHTTP2_SETTINGS_ENABLE_PUSH, .value = 0 },
            .{ .settings_id = c.NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE, .value = window },
        };
        if (c.nghttp2_submit_settings(conn.session, c.NGHTTP2_FLAG_NONE, &settings, settings.len) != 0) return error.Http2;
        if (c.nghttp2_session_set_local_window_size(conn.session, c.NGHTTP2_FLAG_NONE, 0, window) != 0) return error.Http2;
        try conn.flush();
        return conn;
    }

    pub fn close(conn: *Conn) void {
        c.nghttp2_session_del(conn.session);
        conn.stream.close(conn.io);
    }

    pub fn unary(conn: *Conn, path: []const u8, request: []const u8, options: Options) ![]const u8 {
        const messages = try conn.invoke(path, request, options);
        if (messages.len != 1) return error.UnexpectedMessageCount;
        return messages[0];
    }

    pub fn serverStream(conn: *Conn, path: []const u8, request: []const u8, options: Options) ![]const []const u8 {
        return conn.invoke(path, request, options);
    }

    fn invoke(conn: *Conn, path: []const u8, request: []const u8, options: Options) ![]const []const u8 {
        conn.call = .{ .body = try frame(conn.arena, request) };
        conn.status = .{};
        const headers = [_]c.nghttp2_nv{
            header(":method", "POST"),
            header(":scheme", "http"),
            header(":path", path),
            header(":authority", "localhost"),
            header("content-type", "application/grpc"),
            header("te", "trailers"),
            header("containerd-namespace", conn.namespace),
            header("user-agent", "orchd-rootstock-containerd"),
        };
        const provider: c.nghttp2_data_provider2 = .{ .source = .{ .ptr = conn }, .read_callback = readBody };
        const id = c.nghttp2_submit_request2(conn.session, null, &headers, headers.len, &provider, null);
        if (id < 0) return error.Http2;
        conn.call.stream_id = id;

        const deadline = if (options.timeout) |t| Io.Timestamp.now(conn.io, .awake).addDuration(t) else null;
        while (!conn.call.closed) {
            try conn.flush();
            if (options.interrupt) |flag| if (flag.load(.seq_cst)) return error.Interrupted;
            if (deadline) |d| if (Io.Timestamp.now(conn.io, .awake).nanoseconds >= d.nanoseconds) return error.Timeout;
            try conn.receive(100);
        }
        try conn.flush();

        if (conn.call.reset != 0) return error.StreamReset;
        const code = conn.call.grpc_status orelse return error.NoGrpcStatus;
        if (code != 0) {
            conn.status = .{ .code = code, .message = conn.call.grpc_message };
            return error.GrpcStatus;
        }
        return unframe(conn.arena, conn.call.data.items);
    }

    fn receive(conn: *Conn, timeout_ms: i32) !void {
        var fds = [_]posix.pollfd{.{ .fd = conn.stream.socket.handle, .events = posix.POLL.IN, .revents = 0 }};
        if (try posix.poll(&fds, timeout_ms) == 0) return;
        var buf: [16384]u8 = undefined;
        const got = try posix.read(conn.stream.socket.handle, &buf);
        if (got == 0) return error.ConnectionClosed;
        if (c.nghttp2_session_mem_recv2(conn.session, &buf, got) < 0) return error.Http2;
    }

    fn flush(conn: *Conn) !void {
        while (true) {
            var data: [*c]const u8 = undefined;
            const n = c.nghttp2_session_mem_send2(conn.session, &data);
            if (n < 0) return error.Http2;
            if (n == 0) return;
            var bytes = data[0..@intCast(n)];
            while (bytes.len > 0) {
                const wrote = std.c.write(conn.stream.socket.handle, bytes.ptr, bytes.len);
                if (wrote <= 0) return error.WriteFailed;
                bytes = bytes[@intCast(wrote)..];
            }
        }
    }
};

fn header(name: []const u8, value: []const u8) c.nghttp2_nv {
    return .{
        .name = @constCast(name.ptr),
        .namelen = name.len,
        .value = @constCast(value.ptr),
        .valuelen = value.len,
        .flags = c.NGHTTP2_NV_FLAG_NONE,
    };
}

fn connOf(user_data: ?*anyopaque) *Conn {
    return @ptrCast(@alignCast(user_data.?));
}

fn onHeader(
    _: ?*c.nghttp2_session,
    frame_ptr: [*c]const c.nghttp2_frame,
    name: [*c]const u8,
    namelen: usize,
    value: [*c]const u8,
    valuelen: usize,
    _: u8,
    user_data: ?*anyopaque,
) callconv(.c) c_int {
    const conn = connOf(user_data);
    if (frame_ptr.*.hd.stream_id != conn.call.stream_id) return 0;
    const n = name[0..namelen];
    const v = value[0..valuelen];
    if (std.mem.eql(u8, n, "grpc-status")) {
        conn.call.grpc_status = std.fmt.parseInt(u32, v, 10) catch 2;
    } else if (std.mem.eql(u8, n, "grpc-message")) {
        conn.call.grpc_message = conn.arena.dupe(u8, v) catch "";
    } else if (std.mem.eql(u8, n, ":status")) {
        conn.call.http_status = conn.arena.dupe(u8, v) catch "";
    }
    return 0;
}

fn onData(_: ?*c.nghttp2_session, _: u8, stream_id: i32, data: [*c]const u8, len: usize, user_data: ?*anyopaque) callconv(.c) c_int {
    const conn = connOf(user_data);
    if (stream_id != conn.call.stream_id) return 0;
    conn.call.data.appendSlice(conn.arena, data[0..len]) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    return 0;
}

fn onClose(_: ?*c.nghttp2_session, stream_id: i32, error_code: u32, user_data: ?*anyopaque) callconv(.c) c_int {
    const conn = connOf(user_data);
    if (stream_id != conn.call.stream_id) return 0;
    conn.call.closed = true;
    conn.call.reset = error_code;
    return 0;
}

fn readBody(
    _: ?*c.nghttp2_session,
    _: i32,
    buf: [*c]u8,
    length: usize,
    data_flags: [*c]u32,
    source: [*c]c.nghttp2_data_source,
    _: ?*anyopaque,
) callconv(.c) c.nghttp2_ssize {
    const conn: *Conn = @ptrCast(@alignCast(source.*.ptr.?));
    const rest = conn.call.body[conn.call.sent..];
    const n = @min(rest.len, length);
    @memcpy(buf[0..n], rest[0..n]);
    conn.call.sent += n;
    if (conn.call.sent == conn.call.body.len) data_flags.* |= c.NGHTTP2_DATA_FLAG_EOF;
    return @intCast(n);
}

pub fn frame(arena: Allocator, message: []const u8) ![]const u8 {
    const out = try arena.alloc(u8, 5 + message.len);
    out[0] = 0;
    std.mem.writeInt(u32, out[1..5], @intCast(message.len), .big);
    @memcpy(out[5..], message);
    return out;
}

pub fn unframe(arena: Allocator, data: []const u8) ![]const []const u8 {
    var messages: std.ArrayList([]const u8) = .empty;
    var rest = data;
    while (rest.len > 0) {
        if (rest.len < 5) return error.TruncatedMessage;
        if (rest[0] != 0) return error.CompressedMessage;
        const len = std.mem.readInt(u32, rest[1..5], .big);
        if (rest.len - 5 < len) return error.TruncatedMessage;
        try messages.append(arena, rest[5..][0..len]);
        rest = rest[5 + len ..];
    }
    return messages.items;
}

test "gRPC frames each message with a flag and a big-endian length" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try frame(a, "hi");
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 2, 'h', 'i' }, one);
    const two = try std.mem.concat(a, u8, &.{ one, try frame(a, ""), try frame(a, "abc") });
    const messages = try unframe(a, two);
    try testing.expectEqual(3, messages.len);
    try testing.expectEqualStrings("hi", messages[0]);
    try testing.expectEqualStrings("", messages[1]);
    try testing.expectEqualStrings("abc", messages[2]);
    try testing.expectError(error.TruncatedMessage, unframe(a, one[0..6]));
    try testing.expectError(error.CompressedMessage, unframe(a, &.{ 1, 0, 0, 0, 0 }));
}

test {
    _ = pb;
    _ = @import("grpc_test.zig");
}
