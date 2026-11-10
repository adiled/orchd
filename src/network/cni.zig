const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const testing = std.testing;

pub const default_dirs = "/opt/cni/bin:/usr/libexec/cni:/usr/lib/cni";
pub const subnet = "10.87.0.0/16";
pub const gateway = "10.87.0.1";

pub const bridge =
    \\{"cniVersion":"1.0.0","name":"orchd","type":"bridge","bridge":"orchd0","isGateway":true,"ipMasq":true,"hairpinMode":true,
    \\ "ipam":{"type":"host-local","ranges":[[{"subnet":"
++ subnet ++
    \\"}]],"routes":[{"dst":"0.0.0.0/0"}]}}
;
pub const loopback =
    \\{"cniVersion":"1.0.0","name":"orchd-lo","type":"loopback"}
;

pub const needed = [_][]const u8{ "bridge", "host-local", "loopback" };

pub const Command = enum { ADD, DEL };

pub const Attachment = struct {
    container_id: []const u8,
    netns: []const u8,
    ifname: []const u8 = "eth0",
};

pub fn find(arena: Allocator, io: Io, dirs: []const u8, name: []const u8) !?[]const u8 {
    var it = std.mem.tokenizeScalar(u8, dirs, ':');
    while (it.next()) |dir| {
        const path = try std.fs.path.join(arena, &.{ dir, name });
        Io.Dir.cwd().access(io, path, .{ .execute = true }) catch continue;
        return path;
    }
    return null;
}

pub fn missing(arena: Allocator, io: Io, dirs: []const u8) !?[]const u8 {
    for (needed) |name| if (try find(arena, io, dirs, name) == null) return name;
    return null;
}

fn typeOf(arena: Allocator, config: []const u8) ![]const u8 {
    const doc = try std.json.parseFromSliceLeaky(struct { type: []const u8 }, arena, config, .{ .ignore_unknown_fields = true });
    return doc.type;
}

pub fn invoke(arena: Allocator, io: Io, environ: *const Environ.Map, dirs: []const u8, command: Command, config: []const u8, at: Attachment) ![]const u8 {
    const kind = try typeOf(arena, config);
    const plugin = try find(arena, io, dirs, kind) orelse return error.PluginNotFound;
    var env = try environ.clone(arena);
    try env.put("CNI_COMMAND", @tagName(command));
    try env.put("CNI_CONTAINERID", at.container_id);
    try env.put("CNI_NETNS", at.netns);
    try env.put("CNI_IFNAME", at.ifname);
    try env.put("CNI_PATH", dirs);
    var child = try std.process.spawn(io, .{ .argv = &.{plugin}, .environ_map = &env, .stdin = .pipe, .stdout = .pipe, .stderr = .inherit });
    child.stdin.?.writeStreamingAll(io, config) catch {};
    child.stdin.?.close(io);
    child.stdin = null;
    var buffer: [4096]u8 = undefined;
    var reader: Io.File.Reader = .initStreaming(child.stdout.?, io, &buffer);
    const out = try reader.interface.allocRemaining(arena, .limited(1 << 20));
    const term = try child.wait(io);
    if (!term.success()) {
        const failure = std.json.parseFromSliceLeaky(struct { msg: []const u8 = "", details: []const u8 = "" }, arena, out, .{ .ignore_unknown_fields = true }) catch return error.PluginFailed;
        std.log.err("cni {s} {t}: {s} {s}", .{ kind, command, failure.msg, failure.details });
        return error.PluginFailed;
    }
    return out;
}

pub fn add(arena: Allocator, io: Io, environ: *const Environ.Map, dirs: []const u8, at: Attachment) ![]const u8 {
    _ = try invoke(arena, io, environ, dirs, .ADD, loopback, .{ .container_id = at.container_id, .netns = at.netns, .ifname = "lo" });
    return ipOf(arena, try invoke(arena, io, environ, dirs, .ADD, bridge, at)) orelse error.NoAddress;
}

pub fn del(arena: Allocator, io: Io, environ: *const Environ.Map, dirs: []const u8, at: Attachment) void {
    _ = invoke(arena, io, environ, dirs, .DEL, bridge, at) catch {};
    _ = invoke(arena, io, environ, dirs, .DEL, loopback, .{ .container_id = at.container_id, .netns = at.netns, .ifname = "lo" }) catch {};
}

pub fn ipOf(arena: Allocator, result: []const u8) ?[]const u8 {
    const Result = struct { ips: []const struct { address: []const u8 } = &.{} };
    const doc = std.json.parseFromSliceLeaky(Result, arena, result, .{ .ignore_unknown_fields = true }) catch return null;
    if (doc.ips.len == 0) return null;
    const address = doc.ips[0].address;
    return address[0 .. std.mem.indexOfScalar(u8, address, '/') orelse address.len];
}

test "a CNI result gives the address the bridge handed out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("10.87.0.5", ipOf(a,
        \\{"cniVersion":"1.0.0","interfaces":[{"name":"orchd0"},{"name":"eth0","sandbox":"/run/orchd/netns/x"}],
        \\ "ips":[{"interface":1,"address":"10.87.0.5/16","gateway":"10.87.0.1"}],"dns":{}}
    ).?);
    try testing.expectEqual(null, ipOf(a, "{\"cniVersion\":\"1.0.0\"}"));
    try testing.expectEqual(null, ipOf(a, "nope"));
}

test "the configs name the plugins they need" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("bridge", try typeOf(arena.allocator(), bridge));
    try testing.expectEqualStrings("loopback", try typeOf(arena.allocator(), loopback));
    const doc = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), bridge, .{});
    try testing.expectEqualStrings("host-local", doc.object.get("ipam").?.object.get("type").?.string);
}

test "a plugin is looked for in every CNI directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    try tmp.dir.createDirPath(testing.io, "b");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b/bridge", .data = "#!/bin/sh\n", .flags = .{ .permissions = .fromMode(0o755) } });
    const dirs = try std.fmt.allocPrint(a, "{s}/a:{s}/b", .{ root, root });
    try testing.expect(try find(a, testing.io, dirs, "bridge") != null);
    try testing.expectEqualStrings("host-local", (try missing(a, testing.io, dirs)).?);
}
