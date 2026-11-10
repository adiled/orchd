const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const Port = struct {
    address: []const u8 = "",
    host: u16,
    container: u16,
};

pub const Publisher = struct {
    io: Io,
    listeners: []Listener = &.{},
    group: Io.Group = .init,

    const Listener = struct {
        port: Port,
        server: net.Server,
        target: net.IpAddress = undefined,
        connections: Io.Group = .init,
    };

    pub const Failure = struct {
        port: Port,
        err: anyerror,
    };

    pub fn bind(gpa: Allocator, io: Io, ports: []const Port, failure: *?Failure) !Publisher {
        const listeners = try gpa.alloc(Listener, ports.len);
        var bound: usize = 0;
        errdefer {
            for (listeners[0..bound]) |*l| l.server.deinit(io);
            gpa.free(listeners);
        }
        for (ports, listeners) |port, *l| {
            const address = bindAddress(io, port) catch |err| {
                failure.* = .{ .port = port, .err = err };
                return err;
            };
            l.* = .{ .port = port, .server = address.listen(io, .{ .reuse_address = true }) catch |err| {
                failure.* = .{ .port = port, .err = err };
                return err;
            } };
            bound += 1;
        }
        return .{ .io = io, .listeners = listeners };
    }

    pub fn serve(p: *Publisher, target_ip: []const u8) !void {
        for (p.listeners) |*l| {
            l.target = try net.IpAddress.parse(target_ip, l.port.container);
            try p.group.concurrent(p.io, accept, .{ p.io, l });
        }
    }

    pub fn boundPort(p: Publisher, index: usize) u16 {
        return p.listeners[index].server.socket.address.getPort();
    }

    pub fn close(p: *Publisher, gpa: Allocator) void {
        p.group.cancel(p.io);
        for (p.listeners) |*l| {
            l.connections.cancel(p.io);
            l.server.deinit(p.io);
        }
        gpa.free(p.listeners);
        p.listeners = &.{};
    }
};

fn bindAddress(io: Io, port: Port) !net.IpAddress {
    const text = if (port.address.len == 0) "0.0.0.0" else port.address;
    if (net.IpAddress.resolve(io, text, port.host)) |address| return address else |_| {}
    const host = try net.HostName.init(text);
    var results: [16]net.HostName.LookupResult = undefined;
    var queue: Io.Queue(net.HostName.LookupResult) = .init(&results);
    try host.lookup(io, &queue, .{ .port = port.host });
    while (queue.getOne(io)) |result| switch (result) {
        .address => |address| return address,
        .canonical_name => {},
    } else |_| {}
    return error.NoAddressReturned;
}

fn accept(io: Io, l: *Publisher.Listener) Io.Cancelable!void {
    while (true) {
        const client = l.server.accept(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                try io.sleep(.fromMilliseconds(50), .awake);
                continue;
            },
        };
        l.connections.concurrent(io, relay, .{ io, client, l.target }) catch client.close(io);
    }
}

fn relay(io: Io, client: net.Stream, target: net.IpAddress) Io.Cancelable!void {
    defer client.close(io);
    const upstream = target.connect(io, .{ .mode = .stream }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return,
    };
    defer upstream.close(io);
    var back: Io.Group = .init;
    back.concurrent(io, pipe, .{ io, upstream, client }) catch return;
    defer back.cancel(io);
    try pipe(io, client, upstream);
    try back.await(io);
}

fn pipe(io: Io, from: net.Stream, to: net.Stream) Io.Cancelable!void {
    var buffer: [16 << 10]u8 = undefined;
    var writer = to.writer(io, &.{});
    while (true) {
        var vec = [_][]u8{&buffer};
        const n = from.read(io, &vec) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => break,
        };
        if (n == 0) break;
        writer.interface.writeAll(buffer[0..n]) catch break;
    }
    to.shutdown(io, .send) catch {};
}

fn echo(io: Io, server: *net.Server) Io.Cancelable!void {
    while (true) {
        const stream = server.accept(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return,
        };
        defer stream.close(io);
        var buffer: [256]u8 = undefined;
        var vec = [_][]u8{&buffer};
        const n = stream.read(io, &vec) catch return;
        var writer = stream.writer(io, &.{});
        writer.interface.print("echo: {s}", .{buffer[0..n]}) catch return;
    }
}

test "a published port carries a connection to the target and its answer back" {
    const io = testing.io;
    var target_address = try net.IpAddress.parse("127.0.0.1", 0);
    var target = try target_address.listen(io, .{ .reuse_address = true });
    defer target.deinit(io);
    var serving: Io.Group = .init;
    defer serving.cancel(io);
    try serving.concurrent(io, echo, .{ io, &target });

    var failure: ?Publisher.Failure = null;
    var publisher = try Publisher.bind(testing.allocator, io, &.{.{ .address = "127.0.0.1", .host = 0, .container = target.socket.address.getPort() }}, &failure);
    defer publisher.close(testing.allocator);
    try publisher.serve("127.0.0.1");

    const published = try net.IpAddress.parse("127.0.0.1", publisher.boundPort(0));
    const stream = try published.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var writer = stream.writer(io, &.{});
    try writer.interface.writeAll("hello");
    try stream.shutdown(io, .send);
    var buffer: [64]u8 = undefined;
    var reader = stream.reader(io, &buffer);
    const got = try reader.interface.allocRemaining(testing.allocator, .limited(64));
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("echo: hello", got);
}

test "a port already taken is reported by its mapping" {
    const io = testing.io;
    var taken_address = try net.IpAddress.parse("127.0.0.1", 0);
    var taken = try taken_address.listen(io, .{});
    defer taken.deinit(io);
    var failure: ?Publisher.Failure = null;
    const port: Port = .{ .address = "127.0.0.1", .host = taken.socket.address.getPort(), .container = 80 };
    try testing.expectError(error.AddressInUse, Publisher.bind(testing.allocator, io, &.{port}, &failure));
    try testing.expectEqual(port.host, failure.?.port.host);
}

test "an address is a literal, a host name, or every interface when left out" {
    const io = testing.io;
    try testing.expectEqual(8080, (try bindAddress(io, .{ .host = 8080, .container = 80 })).getPort());
    try testing.expect((try bindAddress(io, .{ .address = "::1", .host = 1, .container = 1 })) == .ip6);
    try testing.expectEqual(5433, (try bindAddress(io, .{ .address = "localhost", .host = 5433, .container = 5432 })).getPort());
}
