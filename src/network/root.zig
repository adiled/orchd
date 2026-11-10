const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const contract = @import("contract");

pub const publish = @import("publish.zig");
pub const Publisher = publish.Publisher;
pub const Port = publish.Port;
pub const resolv = @import("resolv.zig");
pub const cni = @import("cni.zig");
pub const netns = @import("netns.zig");

pub const Mode = enum {
    pod,
    host,

    pub fn parse(value: ?[]const u8) ?Mode {
        const v = value orelse return .pod;
        if (v.len == 0) return .pod;
        return std.meta.stringToEnum(Mode, v);
    }
};

fn allInterfaces(address: ?[]const u8) bool {
    const a = address orelse return true;
    return a.len == 0 or std.mem.eql(u8, a, "0.0.0.0") or std.mem.eql(u8, a, "::");
}

pub fn ports(arena: Allocator, publishes: []const contract.PortMapping, mode: Mode) error{ PublishNeedsPodNetwork, OutOfMemory }![]const Port {
    const out = try arena.alloc(Port, publishes.len);
    for (publishes, out) |p, *port| {
        if (mode == .host and (p.host != p.container or !allInterfaces(p.address))) return error.PublishNeedsPodNetwork;
        port.* = .{ .address = p.address orelse "", .host = p.host, .container = p.container };
    }
    return if (mode == .host) &.{} else out;
}

test {
    _ = publish;
    _ = resolv;
    _ = cni;
    _ = netns;
}

test "PUBLISH is forwarded on the pod network, and the host network takes only port:port on every address" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const remapped: []const contract.PortMapping = &.{ .{ .address = "127.0.0.1", .host = 18080, .container = 80 }, .{ .host = 5433, .container = 5432 } };
    const pod = try ports(a, remapped, .pod);
    try testing.expectEqual(18080, pod[0].host);
    try testing.expectEqualStrings("127.0.0.1", pod[0].address);
    try testing.expectEqualStrings("", pod[1].address);
    try testing.expectError(error.PublishNeedsPodNetwork, ports(a, remapped, .host));
    try testing.expectEqual(0, (try ports(a, &.{ .{ .host = 8080, .container = 8080 }, .{ .address = "0.0.0.0", .host = 53, .container = 53 } }, .host)).len);
    try testing.expectEqual(Mode.pod, Mode.parse(null).?);
    try testing.expectEqual(Mode.host, Mode.parse("host").?);
    try testing.expectEqual(null, Mode.parse("bridge"));
}
