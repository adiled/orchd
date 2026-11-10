const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const Value = std.json.Value;

pub const Config = struct {
    diff_ids: []const []const u8 = &.{},
    entrypoint: []const []const u8 = &.{},
    cmd: []const []const u8 = &.{},
    env: []const []const u8 = &.{},
    working_dir: []const u8 = "",
    user: []const u8 = "",
};

pub const arch: []const u8 = switch (builtin.cpu.arch) {
    .x86_64 => "amd64",
    .aarch64 => "arm64",
    else => @tagName(builtin.cpu.arch),
};

fn get(v: Value, key: []const u8) ?Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn str(v: ?Value) []const u8 {
    return switch (v orelse return "") {
        .string => |s| s,
        else => "",
    };
}

fn strings(arena: Allocator, v: ?Value) ![]const []const u8 {
    const items = switch (v orelse return &.{}) {
        .array => |a| a.items,
        else => return &.{},
    };
    var out: std.ArrayList([]const u8) = .empty;
    for (items) |item| if (item == .string) try out.append(arena, item.string);
    return out.items;
}

pub fn parse(arena: Allocator, json: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, arena, json, .{});
}

pub fn manifestFromIndex(index: Value, want_arch: []const u8) ?[]const u8 {
    const manifests = switch (get(index, "manifests") orelse return null) {
        .array => |a| a.items,
        else => return null,
    };
    for (manifests) |m| {
        const p = get(m, "platform") orelse continue;
        if (std.mem.eql(u8, str(get(p, "os")), "linux") and std.mem.eql(u8, str(get(p, "architecture")), want_arch)) {
            return str(get(m, "digest"));
        }
    }
    if (manifests.len > 0) return str(get(manifests[0], "digest"));
    return null;
}

pub fn isIndex(doc: Value) bool {
    return get(doc, "manifests") != null;
}

pub fn configDigest(manifest: Value) ?[]const u8 {
    const digest = str(get(get(manifest, "config") orelse return null, "digest"));
    return if (digest.len > 0) digest else null;
}

pub fn parseConfig(arena: Allocator, doc: Value) !Config {
    const inner = get(doc, "config");
    return .{
        .diff_ids = try strings(arena, get(get(doc, "rootfs") orelse return error.NoRootfs, "diff_ids")),
        .entrypoint = try strings(arena, if (inner) |i| get(i, "Entrypoint") else null),
        .cmd = try strings(arena, if (inner) |i| get(i, "Cmd") else null),
        .env = try strings(arena, if (inner) |i| get(i, "Env") else null),
        .working_dir = if (inner) |i| str(get(i, "WorkingDir")) else "",
        .user = if (inner) |i| str(get(i, "User")) else "",
    };
}

pub fn chainId(arena: Allocator, diff_ids: []const []const u8) ![]const u8 {
    if (diff_ids.len == 0) return error.NoLayers;
    var chain = diff_ids[0];
    for (diff_ids[1..]) |next| {
        var digest: [32]u8 = undefined;
        var h: std.crypto.hash.sha2.Sha256 = .init(.{});
        h.update(chain);
        h.update(" ");
        h.update(next);
        h.final(&digest);
        chain = try std.fmt.allocPrint(arena, "sha256:{x}", .{&digest});
    }
    return chain;
}

pub fn argv(arena: Allocator, config: Config, entrypoint: ?[]const []const u8, cmd: ?[]const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(arena, entrypoint orelse config.entrypoint);
    if (cmd) |c| {
        try out.appendSlice(arena, c);
    } else if (entrypoint == null) {
        try out.appendSlice(arena, config.cmd);
    }
    if (out.items.len == 0) return error.NoCommand;
    return out.items;
}

pub fn mergeEnv(arena: Allocator, image_env: []const []const u8, ours: []const []const u8) ![]const []const u8 {
    var merged: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    for ([_][]const []const u8{ image_env, ours }) |list| for (list) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        try merged.put(arena, kv[0..eq], kv);
    };
    return arena.dupe([]const u8, merged.values());
}

pub const User = struct { uid: u32 = 0, gid: u32 = 0, named: bool = false };

pub fn parseUser(user: []const u8) User {
    const t = std.mem.trim(u8, user, " ");
    if (t.len == 0) return .{};
    const uid_s, const gid_s = if (std.mem.indexOfScalar(u8, t, ':')) |i| .{ t[0..i], t[i + 1 ..] } else .{ t, "" };
    const uid = std.fmt.parseInt(u32, uid_s, 10) catch return .{ .named = true };
    const gid = std.fmt.parseInt(u32, gid_s, 10) catch uid;
    return .{ .uid = uid, .gid = gid };
}

test "an index yields this platform's manifest, else its first" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const index = try parse(arena.allocator(),
        \\{"manifests":[
        \\ {"digest":"sha256:amd","platform":{"os":"linux","architecture":"amd64"}},
        \\ {"digest":"sha256:arm","platform":{"os":"linux","architecture":"arm64","variant":"v8"}}]}
    );
    try testing.expect(isIndex(index));
    try testing.expectEqualStrings("sha256:arm", manifestFromIndex(index, "arm64").?);
    try testing.expectEqualStrings("sha256:amd", manifestFromIndex(index, "s390x").?);
    const manifest = try parse(arena.allocator(), "{\"config\":{\"digest\":\"sha256:cfg\"},\"layers\":[]}");
    try testing.expect(!isIndex(manifest));
    try testing.expectEqualStrings("sha256:cfg", configDigest(manifest).?);
}

test "an image config gives its layers, command, env, workdir and user" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try parseConfig(a, try parse(a,
        \\{"config":{"Entrypoint":["/docker-entrypoint.sh"],"Cmd":["nginx","-g","daemon off;"],
        \\ "Env":["PATH=/usr/bin"],"WorkingDir":"/srv","User":"101:101"},
        \\ "rootfs":{"type":"layers","diff_ids":["sha256:a","sha256:b"]}}
    ));
    try testing.expectEqual(2, config.diff_ids.len);
    try testing.expectEqualStrings("daemon off;", config.cmd[2]);
    try testing.expectEqualStrings("/srv", config.working_dir);
    try testing.expectError(error.NoRootfs, parseConfig(a, try parse(a, "{\"config\":{}}")));
}

test "the chain id folds each layer onto the last, as containerd names snapshots" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("sha256:a", try chainId(a, &.{"sha256:a"}));
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("sha256:a sha256:b", &digest, .{});
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "sha256:{x}", .{&digest}), try chainId(a, &.{ "sha256:a", "sha256:b" }));
    try testing.expectError(error.NoLayers, chainId(a, &.{}));
}

test "argv follows Docker: entrypoint replaces, cmd replaces, a new entrypoint drops the image cmd" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config: Config = .{ .entrypoint = &.{"/e"}, .cmd = &.{"serve"} };
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "/e", "serve" }), try argv(a, config, null, null));
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "/e", "debug" }), try argv(a, config, null, &.{"debug"}));
    try testing.expectEqualDeep(@as([]const []const u8, &.{"/other"}), try argv(a, config, &.{"/other"}, null));
    try testing.expectError(error.NoCommand, argv(a, .{}, null, null));
}

test "our env overrides the image's by key, keeping the image's order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const env = try mergeEnv(arena.allocator(), &.{ "PATH=/usr/bin", "LANG=C" }, &.{ "LANG=en", "MODE=x" });
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "PATH=/usr/bin", "LANG=en", "MODE=x" }), env);
}

test "a user is uid[:gid]; a name cannot be resolved and runs as root" {
    try testing.expectEqual(User{ .uid = 101, .gid = 101 }, parseUser("101"));
    try testing.expectEqual(User{ .uid = 101, .gid = 5 }, parseUser("101:5"));
    try testing.expectEqual(User{ .named = true }, parseUser("nginx"));
    try testing.expectEqual(User{}, parseUser(""));
}
