const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const testing = std.testing;
const c = @import("nghttp2");
const grpc = @import("root.zig");

const Reply = struct {
    messages: []const []const u8 = &.{},
    status: []const u8 = "0",
    message: []const u8 = "",
    hang: bool = false,
};

const Server = struct {
    gpa: std.mem.Allocator,
    io: Io,
    listener: Io.net.Server,
    reply: Reply,
    path: std.ArrayList(u8) = .empty,
    namespace: std.ArrayList(u8) = .empty,
    request: std.ArrayList(u8) = .empty,
    body: []u8 = &.{},
    sent: usize = 0,
    stream_id: i32 = 0,
    session: ?*c.nghttp2_session = null,

    fn deinit(s: *Server) void {
        s.path.deinit(s.gpa);
        s.namespace.deinit(s.gpa);
        s.request.deinit(s.gpa);
        s.gpa.free(s.body);
    }

    fn serve(s: *Server) void {
        s.serveOnce() catch {};
    }

    fn serveOnce(s: *Server) !void {
        const stream = try s.listener.accept(s.io);
        defer stream.close(s.io);
        var body: std.ArrayList(u8) = .empty;
        for (s.reply.messages) |m| {
            var len: [4]u8 = undefined;
            std.mem.writeInt(u32, &len, @intCast(m.len), .big);
            try body.append(s.gpa, 0);
            try body.appendSlice(s.gpa, &len);
            try body.appendSlice(s.gpa, m);
        }
        s.body = try body.toOwnedSlice(s.gpa);

        var callbacks: ?*c.nghttp2_session_callbacks = null;
        _ = c.nghttp2_session_callbacks_new(&callbacks);
        defer c.nghttp2_session_callbacks_del(callbacks);
        c.nghttp2_session_callbacks_set_on_header_callback(callbacks, onHeader);
        c.nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, onData);
        c.nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks, onFrame);
        _ = c.nghttp2_session_server_new(&s.session, callbacks, s);
        defer c.nghttp2_session_del(s.session);
        _ = c.nghttp2_submit_settings(s.session, c.NGHTTP2_FLAG_NONE, null, 0);

        const fd = stream.socket.handle;
        while (true) {
            while (true) {
                var data: [*c]const u8 = undefined;
                const n = c.nghttp2_session_mem_send2(s.session, &data);
                if (n <= 0) break;
                var bytes = data[0..@intCast(n)];
                while (bytes.len > 0) {
                    const wrote = std.c.write(fd, bytes.ptr, bytes.len);
                    if (wrote <= 0) return;
                    bytes = bytes[@intCast(wrote)..];
                }
            }
            var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
            if (try posix.poll(&fds, 2000) == 0) return;
            var buf: [16384]u8 = undefined;
            const got = posix.read(fd, &buf) catch return;
            if (got == 0) return;
            if (c.nghttp2_session_mem_recv2(s.session, &buf, got) < 0) return;
        }
    }

    fn of(user_data: ?*anyopaque) *Server {
        return @ptrCast(@alignCast(user_data.?));
    }

    fn onHeader(_: ?*c.nghttp2_session, _: [*c]const c.nghttp2_frame, name: [*c]const u8, namelen: usize, value: [*c]const u8, valuelen: usize, _: u8, user_data: ?*anyopaque) callconv(.c) c_int {
        const s = of(user_data);
        const n = name[0..namelen];
        const v = value[0..valuelen];
        if (std.mem.eql(u8, n, ":path")) s.path.appendSlice(s.gpa, v) catch {};
        if (std.mem.eql(u8, n, "containerd-namespace")) s.namespace.appendSlice(s.gpa, v) catch {};
        return 0;
    }

    fn onData(_: ?*c.nghttp2_session, _: u8, _: i32, data: [*c]const u8, len: usize, user_data: ?*anyopaque) callconv(.c) c_int {
        const s = of(user_data);
        s.request.appendSlice(s.gpa, data[0..len]) catch {};
        return 0;
    }

    fn onFrame(session: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, user_data: ?*anyopaque) callconv(.c) c_int {
        const s = of(user_data);
        const hd = frame.*.hd;
        const ends = hd.flags & c.NGHTTP2_FLAG_END_STREAM != 0;
        if (!ends or (hd.type != c.NGHTTP2_HEADERS and hd.type != c.NGHTTP2_DATA)) return 0;
        if (s.reply.hang) return 0;
        s.stream_id = hd.stream_id;
        const headers = [_]c.nghttp2_nv{ nv(":status", "200"), nv("content-type", "application/grpc") };
        const provider: c.nghttp2_data_provider2 = .{ .source = .{ .ptr = s }, .read_callback = readBody };
        _ = c.nghttp2_submit_response2(session, hd.stream_id, &headers, headers.len, &provider);
        return 0;
    }

    fn readBody(session: ?*c.nghttp2_session, stream_id: i32, buf: [*c]u8, length: usize, flags: [*c]u32, source: [*c]c.nghttp2_data_source, _: ?*anyopaque) callconv(.c) c.nghttp2_ssize {
        const s: *Server = @ptrCast(@alignCast(source.*.ptr.?));
        const rest = s.body[s.sent..];
        const n = @min(rest.len, length);
        @memcpy(buf[0..n], rest[0..n]);
        s.sent += n;
        if (s.sent == s.body.len) {
            flags.* |= c.NGHTTP2_DATA_FLAG_EOF | c.NGHTTP2_DATA_FLAG_NO_END_STREAM;
            const trailers = [_]c.nghttp2_nv{ nv("grpc-status", s.reply.status), nv("grpc-message", s.reply.message) };
            _ = c.nghttp2_submit_trailer(session, stream_id, &trailers, if (s.reply.message.len > 0) 2 else 1);
        }
        return @intCast(n);
    }

    fn nv(name: []const u8, value: []const u8) c.nghttp2_nv {
        return .{ .name = @constCast(name.ptr), .namelen = name.len, .value = @constCast(value.ptr), .valuelen = value.len, .flags = c.NGHTTP2_NV_FLAG_NONE };
    }
};

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    path: []const u8,
    server: *Server,
    thread: ?std.Thread,

    fn start(f: *Fixture, reply: Reply) !void {
        f.arena = .init(testing.allocator);
        f.tmp = testing.tmpDir(.{});
        f.path = try std.fmt.allocPrint(f.arena.allocator(), ".zig-cache/tmp/{s}/s.sock", .{f.tmp.sub_path});
        const address = try Io.net.UnixAddress.init(f.path);
        f.server = try f.arena.allocator().create(Server);
        f.server.* = .{ .gpa = testing.allocator, .io = testing.io, .listener = try address.listen(testing.io, .{}), .reply = reply };
        f.thread = try std.Thread.spawn(.{}, Server.serve, .{f.server});
    }

    fn served(f: *Fixture) void {
        if (f.thread) |t| t.join();
        f.thread = null;
    }

    fn stop(f: *Fixture) void {
        f.served();
        f.server.listener.deinit(testing.io);
        f.server.deinit();
        f.tmp.cleanup();
        f.arena.deinit();
    }
};

test "a unary call carries its path, namespace and message, and returns the reply" {
    var f: Fixture = undefined;
    try f.start(.{ .messages = &.{"pong"} });
    defer f.stop();
    const conn = try grpc.Conn.open(f.arena.allocator(), testing.io, f.path, "hum");
    const reply = try conn.unary("/containerd.services.version.v1.Version/Version", "ping", .{});
    conn.close();
    try testing.expectEqualStrings("pong", reply);
    f.served();
    try testing.expectEqualStrings("/containerd.services.version.v1.Version/Version", f.server.path.items);
    try testing.expectEqualStrings("hum", f.server.namespace.items);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 4, 'p', 'i', 'n', 'g' }, f.server.request.items);
}

test "a server stream returns every message in order" {
    var f: Fixture = undefined;
    try f.start(.{ .messages = &.{ "one", "", "three" } });
    defer f.stop();
    const conn = try grpc.Conn.open(f.arena.allocator(), testing.io, f.path, "hum");
    defer conn.close();
    const messages = try conn.serverStream("/containerd.services.content.v1.Content/Read", "x", .{});
    try testing.expectEqual(3, messages.len);
    try testing.expectEqualStrings("three", messages[2]);
}

test "a failing call reports its gRPC status and message" {
    var f: Fixture = undefined;
    try f.start(.{ .status = "5", .message = "image not found" });
    defer f.stop();
    const conn = try grpc.Conn.open(f.arena.allocator(), testing.io, f.path, "hum");
    defer conn.close();
    try testing.expectError(error.GrpcStatus, conn.unary("/x/Y", "", .{}));
    try testing.expectEqual(5, conn.status.code);
    try testing.expectEqualStrings("image not found", conn.status.message);
}

test "a call that never answers gives way to an interrupt and to a timeout" {
    var f: Fixture = undefined;
    try f.start(.{ .hang = true });
    defer f.stop();
    const conn = try grpc.Conn.open(f.arena.allocator(), testing.io, f.path, "hum");
    defer conn.close();
    var flag: std.atomic.Value(bool) = .init(true);
    try testing.expectError(error.Interrupted, conn.unary("/x/Wait", "", .{ .interrupt = &flag }));
    try testing.expectError(error.Timeout, conn.unary("/x/Wait", "", .{ .timeout = .fromMilliseconds(200) }));
}
