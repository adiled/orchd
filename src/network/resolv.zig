const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const host = "/etc/resolv.conf";
pub const upstream = "/run/systemd/resolve/resolv.conf";

pub const Dns = struct {
    servers: []const []const u8 = &.{},
    searches: []const []const u8 = &.{},
    options: []const []const u8 = &.{},

    pub fn onlyLoopback(dns: Dns) bool {
        for (dns.servers) |server| {
            if (!std.mem.startsWith(u8, server, "127.") and !std.mem.eql(u8, server, "::1")) return false;
        }
        return dns.servers.len > 0;
    }
};

pub fn parse(arena: Allocator, content: []const u8) !Dns {
    var servers: std.ArrayList([]const u8) = .empty;
    var searches: std.ArrayList([]const u8) = .empty;
    var options: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        const key = words.next() orelse continue;
        const into = if (std.mem.eql(u8, key, "nameserver"))
            &servers
        else if (std.mem.eql(u8, key, "search") or std.mem.eql(u8, key, "domain"))
            &searches
        else if (std.mem.eql(u8, key, "options"))
            &options
        else
            continue;
        while (words.next()) |word| try into.append(arena, word);
    }
    return .{ .servers = servers.items, .searches = searches.items, .options = options.items };
}

fn readDns(arena: Allocator, io: Io, path: []const u8) !Dns {
    return parse(arena, Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 10)) catch "");
}

pub const Choice = struct { path: []const u8, dns: Dns };

pub fn forOwnNetwork(arena: Allocator, io: Io) !Choice {
    const here = try readDns(arena, io, host);
    if (!here.onlyLoopback()) return .{ .path = host, .dns = here };
    const there = try readDns(arena, io, upstream);
    if (there.servers.len > 0 and !there.onlyLoopback()) return .{ .path = upstream, .dns = there };
    return .{ .path = host, .dns = here };
}

pub fn forHostNetwork(arena: Allocator, io: Io) !Choice {
    return .{ .path = host, .dns = try readDns(arena, io, host) };
}

test "dns comes from resolv.conf, as kubelet gives a pod" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const dns = try parse(arena.allocator(), "# x\nnameserver 10.0.0.2\nnameserver 1.1.1.1\nsearch lan corp\noptions ndots:2 edns0\n");
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "10.0.0.2", "1.1.1.1" }), dns.servers);
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "lan", "corp" }), dns.searches);
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "ndots:2", "edns0" }), dns.options);
}

test "a host that resolves through a loopback stub is spotted" {
    try testing.expect((Dns{ .servers = &.{"127.0.0.53"} }).onlyLoopback());
    try testing.expect(!(Dns{ .servers = &.{ "127.0.0.53", "10.0.0.2" } }).onlyLoopback());
    try testing.expect(!(Dns{}).onlyLoopback());
}
