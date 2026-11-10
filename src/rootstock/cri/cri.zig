const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const pb = @import("grpc").pb;

pub const method = struct {
    const runtime = "/runtime.v1.RuntimeService/";
    const images = "/runtime.v1.ImageService/";
    pub const version = runtime ++ "Version";
    pub const status = runtime ++ "Status";
    pub const run_pod = runtime ++ "RunPodSandbox";
    pub const stop_pod = runtime ++ "StopPodSandbox";
    pub const remove_pod = runtime ++ "RemovePodSandbox";
    pub const list_pods = runtime ++ "ListPodSandbox";
    pub const create_container = runtime ++ "CreateContainer";
    pub const start_container = runtime ++ "StartContainer";
    pub const stop_container = runtime ++ "StopContainer";
    pub const container_status = runtime ++ "ContainerStatus";
    pub const pod_status = runtime ++ "PodSandboxStatus";
    pub const image_status = images ++ "ImageStatus";
    pub const pull_image = images ++ "PullImage";
};

const namespace_pod: u64 = 0;
const namespace_container: u64 = 1;
const namespace_node: u64 = 2;

fn networkMode(host_network: bool) u64 {
    return if (host_network) namespace_node else namespace_pod;
}

pub const ContainerState = enum(u64) { created = 0, running = 1, exited = 2, unknown = 3, _ };

pub const Dns = struct {
    servers: []const []const u8 = &.{},
    searches: []const []const u8 = &.{},
    options: []const []const u8 = &.{},
};

pub const Pod = struct {
    name: []const u8,
    namespace: []const u8,
    log_directory: []const u8,
    hostname: []const u8 = "",
    host_network: bool = false,
    labels: []const [2][]const u8 = &.{},
    dns: Dns = .{},
};

pub const Mount = struct {
    host_path: []const u8,
    container_path: []const u8,
};

pub const User = struct {
    uid: ?u64 = null,
    gid: ?u64 = null,
    name: []const u8 = "",

    pub fn parse(spec: []const u8) User {
        if (spec.len == 0) return .{};
        const colon = std.mem.indexOfScalar(u8, spec, ':');
        const user = spec[0 .. colon orelse spec.len];
        const group = if (colon) |i| spec[i + 1 ..] else "";
        const uid = std.fmt.parseInt(u64, user, 10) catch return .{ .name = user };
        return .{ .uid = uid, .gid = std.fmt.parseInt(u64, group, 10) catch null };
    }
};

pub const Container = struct {
    name: []const u8,
    host_network: bool = false,
    image: []const u8,
    command: []const []const u8 = &.{},
    args: []const []const u8 = &.{},
    working_dir: []const u8 = "",
    env: []const [2][]const u8 = &.{},
    mounts: []const Mount = &.{},
    labels: []const [2][]const u8 = &.{},
    log_path: []const u8 = "",
    user: User = .{},
    memory_bytes: ?u64 = null,
    cpu_quota_us: ?u64 = null,
    cpu_period_us: ?u64 = null,
    unified: []const [2][]const u8 = &.{},
};

pub const Status = struct {
    state: ContainerState = .unknown,
    exit_code: i32 = 0,
    reason: []const u8 = "",
    message: []const u8 = "",
};

pub const Version = struct {
    runtime_name: []const u8 = "",
    runtime_version: []const u8 = "",
    runtime_api_version: []const u8 = "",
};

pub const Condition = struct {
    ready: bool = false,
    reason: []const u8 = "",
    message: []const u8 = "",
};

pub const Readiness = struct {
    runtime: Condition = .{},
    network: Condition = .{},
};

fn strings(w: *pb.Writer, field: u32, values: []const []const u8) !void {
    for (values) |v| try w.message(field, v);
}

fn map(w: *pb.Writer, field: u32, pairs: []const [2][]const u8) !void {
    for (pairs) |kv| try w.mapEntry(field, kv[0], kv[1]);
}

fn one(arena: Allocator, field: u32, value: []const u8) ![]const u8 {
    var w: pb.Writer = .init(arena);
    try w.string(field, value);
    return w.bytes();
}

fn int64Value(arena: Allocator, value: u64) ![]const u8 {
    var w: pb.Writer = .init(arena);
    try w.uint(1, value);
    return w.bytes();
}

pub fn podSandboxConfig(arena: Allocator, pod: Pod) ![]const u8 {
    var metadata: pb.Writer = .init(arena);
    try metadata.string(1, pod.name);
    try metadata.string(2, pod.name);
    try metadata.string(3, pod.namespace);

    var dns: pb.Writer = .init(arena);
    try strings(&dns, 1, pod.dns.servers);
    try strings(&dns, 2, pod.dns.searches);
    try strings(&dns, 3, pod.dns.options);

    var namespaces: pb.Writer = .init(arena);
    try namespaces.uint(1, networkMode(pod.host_network));
    try namespaces.uint(2, namespace_container);
    var security: pb.Writer = .init(arena);
    try security.message(1, namespaces.bytes());
    var linux: pb.Writer = .init(arena);
    try linux.message(2, security.bytes());

    var config: pb.Writer = .init(arena);
    try config.message(1, metadata.bytes());
    if (!pod.host_network) try config.string(2, pod.hostname);
    try config.string(3, pod.log_directory);
    if (dns.bytes().len > 0) try config.message(4, dns.bytes());
    try map(&config, 6, pod.labels);
    try config.message(8, linux.bytes());
    return config.bytes();
}

pub fn runPodSandboxRequest(arena: Allocator, sandbox_config: []const u8) ![]const u8 {
    var w: pb.Writer = .init(arena);
    try w.message(1, sandbox_config);
    return w.bytes();
}

pub fn podRequest(arena: Allocator, pod_id: []const u8) ![]const u8 {
    return one(arena, 1, pod_id);
}

pub fn listPodSandboxRequest(arena: Allocator, labels: []const [2][]const u8) ![]const u8 {
    var filter: pb.Writer = .init(arena);
    try map(&filter, 3, labels);
    var w: pb.Writer = .init(arena);
    try w.message(1, filter.bytes());
    return w.bytes();
}

pub fn createContainerRequest(arena: Allocator, pod_id: []const u8, c: Container, sandbox_config: []const u8) ![]const u8 {
    var metadata: pb.Writer = .init(arena);
    try metadata.string(1, c.name);

    var resources: pb.Writer = .init(arena);
    if (c.cpu_period_us) |v| try resources.uint(1, v);
    if (c.cpu_quota_us) |v| try resources.uint(2, v);
    if (c.memory_bytes) |v| try resources.uint(4, v);
    try map(&resources, 9, c.unified);

    var namespaces: pb.Writer = .init(arena);
    try namespaces.uint(1, networkMode(c.host_network));
    try namespaces.uint(2, namespace_container);
    var security: pb.Writer = .init(arena);
    try security.message(3, namespaces.bytes());
    if (c.user.uid) |uid| try security.message(5, try int64Value(arena, uid));
    if (c.user.gid) |gid| try security.message(12, try int64Value(arena, gid));
    try security.string(6, c.user.name);

    var linux: pb.Writer = .init(arena);
    try linux.message(1, resources.bytes());
    try linux.message(2, security.bytes());

    var config: pb.Writer = .init(arena);
    try config.message(1, metadata.bytes());
    var image: pb.Writer = .init(arena);
    try image.string(1, c.image);
    try image.string(18, c.image);
    try config.message(2, image.bytes());
    try strings(&config, 3, c.command);
    try strings(&config, 4, c.args);
    try config.string(5, c.working_dir);
    for (c.env) |kv| {
        var entry: pb.Writer = .init(arena);
        try entry.string(1, kv[0]);
        try entry.string(2, kv[1]);
        try config.message(6, entry.bytes());
    }
    for (c.mounts) |m| {
        var entry: pb.Writer = .init(arena);
        try entry.string(1, m.container_path);
        try entry.string(2, m.host_path);
        try config.message(7, entry.bytes());
    }
    try map(&config, 9, c.labels);
    try config.string(11, c.log_path);
    try config.message(15, linux.bytes());

    var w: pb.Writer = .init(arena);
    try w.string(1, pod_id);
    try w.message(2, config.bytes());
    try w.message(3, sandbox_config);
    return w.bytes();
}

pub fn containerRequest(arena: Allocator, container_id: []const u8) ![]const u8 {
    return one(arena, 1, container_id);
}

pub fn stopContainerRequest(arena: Allocator, container_id: []const u8, timeout_s: u64) ![]const u8 {
    var w: pb.Writer = .init(arena);
    try w.string(1, container_id);
    try w.uint(2, timeout_s);
    return w.bytes();
}

pub fn imageRequest(arena: Allocator, image: []const u8) ![]const u8 {
    var w: pb.Writer = .init(arena);
    try w.message(1, try one(arena, 1, image));
    return w.bytes();
}

fn find(bytes: []const u8, number: u32) !?pb.Field {
    var r: pb.Reader = .init(bytes);
    var found: ?pb.Field = null;
    while (try r.next()) |f| if (f.number == number) {
        found = f;
    };
    return found;
}

fn stringField(bytes: []const u8, number: u32) ![]const u8 {
    return if (try find(bytes, number)) |f| f.asBytes() else "";
}

pub fn parseId(bytes: []const u8) ![]const u8 {
    return stringField(bytes, 1);
}

pub fn parsePodIds(arena: Allocator, bytes: []const u8) ![]const []const u8 {
    var ids: std.ArrayList([]const u8) = .empty;
    var r: pb.Reader = .init(bytes);
    while (try r.next()) |f| if (f.number == 1) try ids.append(arena, try stringField(f.asBytes(), 1));
    return ids.items;
}

pub fn parsePodIp(bytes: []const u8) ![]const u8 {
    return stringField(sub(bytes, &.{ 1, 5 }) catch return "", 1);
}

pub fn imagePresent(bytes: []const u8) !bool {
    const image = try find(bytes, 1) orelse return false;
    return image.asBytes().len > 0;
}

pub fn parseContainerStatus(bytes: []const u8) !Status {
    const status = (try find(bytes, 1) orelse return .{}).asBytes();
    var out: Status = .{};
    var r: pb.Reader = .init(status);
    while (try r.next()) |f| switch (f.number) {
        3 => out.state = @fromBackingInt(@intCast(f.asUint())),
        7 => out.exit_code = @truncate(@as(i64, @bitCast(f.asUint()))),
        10 => out.reason = f.asBytes(),
        11 => out.message = f.asBytes(),
        else => {},
    };
    return out;
}

pub fn parseVersion(bytes: []const u8) !Version {
    return .{
        .runtime_name = try stringField(bytes, 2),
        .runtime_version = try stringField(bytes, 3),
        .runtime_api_version = try stringField(bytes, 4),
    };
}

pub fn parseReadiness(bytes: []const u8) !Readiness {
    const status = (try find(bytes, 1) orelse return .{}).asBytes();
    var out: Readiness = .{};
    var r: pb.Reader = .init(status);
    while (try r.next()) |f| {
        if (f.number != 1) continue;
        const condition = f.asBytes();
        const kind = try stringField(condition, 1);
        const into = if (std.mem.eql(u8, kind, "RuntimeReady")) &out.runtime else if (std.mem.eql(u8, kind, "NetworkReady")) &out.network else continue;
        into.* = .{
            .ready = if (try find(condition, 2)) |b| b.asUint() != 0 else false,
            .reason = try stringField(condition, 3),
            .message = try stringField(condition, 4),
        };
    }
    return out;
}

pub fn onlyLoopback(dns: Dns) bool {
    for (dns.servers) |server| {
        if (!std.mem.startsWith(u8, server, "127.") and !std.mem.eql(u8, server, "::1")) return false;
    }
    return dns.servers.len > 0;
}

pub fn parseResolvConf(arena: Allocator, content: []const u8) !Dns {
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

fn sub(bytes: []const u8, path: []const u32) ![]const u8 {
    var at = bytes;
    for (path) |number| at = (try find(at, number) orelse return error.Missing).asBytes();
    return at;
}

fn uintAt(bytes: []const u8, number: u32) !u64 {
    return (try find(bytes, number) orelse return error.Missing).asUint();
}

test "a pod gets its own network and hostname, or shares the host's when asked" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try podSandboxConfig(a, .{
        .name = "hum-web",
        .namespace = "hum",
        .log_directory = "/state/cri/hum-web",
        .hostname = "web",
        .labels = &.{.{ "orchd.grove", "hum" }},
        .dns = .{ .servers = &.{"1.1.1.1"}, .searches = &.{"lan"} },
    });
    try testing.expectEqualStrings("hum-web", try stringField(try sub(config, &.{1}), 1));
    try testing.expectEqualStrings("hum", try stringField(try sub(config, &.{1}), 3));
    try testing.expectEqualStrings("web", try stringField(config, 2));
    try testing.expectEqualStrings("/state/cri/hum-web", try stringField(config, 3));
    try testing.expectEqualStrings("1.1.1.1", try stringField(try sub(config, &.{4}), 1));
    try testing.expectEqualStrings("lan", try stringField(try sub(config, &.{4}), 2));
    try testing.expectEqual(null, try find(config, 5));
    const label = try sub(config, &.{6});
    try testing.expectEqualStrings("orchd.grove", try stringField(label, 1));
    try testing.expectEqualStrings("hum", try stringField(label, 2));
    const namespaces = try sub(config, &.{ 8, 2, 1 });
    try testing.expectEqual(null, try find(namespaces, 1));
    try testing.expectEqual(namespace_container, try uintAt(namespaces, 2));

    const shared = try podSandboxConfig(a, .{ .name = "hum-web", .namespace = "hum", .log_directory = "/l", .hostname = "web", .host_network = true });
    try testing.expectEqual(namespace_node, try uintAt(try sub(shared, &.{ 8, 2, 1 }), 1));
    try testing.expectEqual(null, try find(shared, 2));
}

test "a pod's status gives its IP on the pod network" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var network: pb.Writer = .init(a);
    try network.string(1, "10.85.0.7");
    var status: pb.Writer = .init(a);
    try status.string(1, "pod-1");
    try status.message(5, network.bytes());
    var response: pb.Writer = .init(a);
    try response.message(1, status.bytes());
    try testing.expectEqualStrings("10.85.0.7", try parsePodIp(response.bytes()));
    try testing.expectEqualStrings("", try parsePodIp(""));
}

test "a host that resolves through a loopback stub is spotted" {
    try testing.expect(onlyLoopback(.{ .servers = &.{"127.0.0.53"} }));
    try testing.expect(!onlyLoopback(.{ .servers = &.{ "127.0.0.53", "10.0.0.2" } }));
    try testing.expect(!onlyLoopback(.{}));
}

test "a container carries its argv, env, mounts, log, user and limits where CRI looks for them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const request = try createContainerRequest(a, "pod-1", .{
        .name = "web",
        .image = "docker.io/library/nginx:alpine",
        .command = &.{"/entry"},
        .args = &.{ "sh", "-c", "" },
        .working_dir = "/srv",
        .env = &.{.{ "MODE", "x" }},
        .mounts = &.{.{ .host_path = "/data/site", .container_path = "/srv/site" }},
        .log_path = "web.log",
        .user = .{ .uid = 0, .gid = 101 },
        .memory_bytes = 256 << 20,
        .cpu_quota_us = 50_000,
        .cpu_period_us = 100_000,
        .unified = &.{.{ "pids.max", "64" }},
    }, "sandbox");
    try testing.expectEqualStrings("pod-1", try stringField(request, 1));
    try testing.expectEqualStrings("sandbox", try stringField(request, 3));
    const config = try sub(request, &.{2});
    try testing.expectEqualStrings("web", try stringField(try sub(config, &.{1}), 1));
    try testing.expectEqualStrings("docker.io/library/nginx:alpine", try stringField(try sub(config, &.{2}), 1));
    try testing.expectEqualStrings("docker.io/library/nginx:alpine", try stringField(try sub(config, &.{2}), 18));

    var args: std.ArrayList([]const u8) = .empty;
    var r: pb.Reader = .init(config);
    while (try r.next()) |f| if (f.number == 4) try args.append(a, f.asBytes());
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "sh", "-c", "" }), args.items);

    try testing.expectEqualStrings("/entry", try stringField(config, 3));
    try testing.expectEqualStrings("/srv", try stringField(config, 5));
    try testing.expectEqualStrings("MODE", try stringField(try sub(config, &.{6}), 1));
    try testing.expectEqualStrings("x", try stringField(try sub(config, &.{6}), 2));
    try testing.expectEqualStrings("/srv/site", try stringField(try sub(config, &.{7}), 1));
    try testing.expectEqualStrings("/data/site", try stringField(try sub(config, &.{7}), 2));
    try testing.expectEqualStrings("web.log", try stringField(config, 11));

    const resources = try sub(config, &.{ 15, 1 });
    try testing.expectEqual(100_000, try uintAt(resources, 1));
    try testing.expectEqual(50_000, try uintAt(resources, 2));
    try testing.expectEqual(256 << 20, try uintAt(resources, 4));
    try testing.expectEqualStrings("pids.max", try stringField(try sub(resources, &.{9}), 1));

    const security = try sub(config, &.{ 15, 2 });
    try testing.expect(try find(security, 5) != null);
    try testing.expectEqual(0, (try sub(security, &.{5})).len);
    try testing.expectEqual(101, try uintAt(try sub(security, &.{12}), 1));
    try testing.expectEqual(namespace_container, try uintAt(try sub(security, &.{3}), 2));
    try testing.expectEqual(null, try find(try sub(security, &.{3}), 1));
}

test "a user is a uid, a uid and gid, or a name" {
    try testing.expectEqual(User{}, User.parse(""));
    try testing.expectEqual(User{ .uid = 101 }, User.parse("101"));
    try testing.expectEqual(User{ .uid = 101, .gid = 0 }, User.parse("101:0"));
    try testing.expectEqualStrings("nginx", User.parse("nginx:nginx").name);
    try testing.expectEqual(null, User.parse("nginx").uid);
}

test "a container status gives its state, exit code and why" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var status: pb.Writer = .init(a);
    try status.string(1, "c1");
    try status.uint(3, 2);
    try status.uint(7, @bitCast(@as(i64, -1)));
    try status.string(10, "Error");
    var response: pb.Writer = .init(a);
    try response.message(1, status.bytes());
    const got = try parseContainerStatus(response.bytes());
    try testing.expectEqual(.exited, got.state);
    try testing.expectEqual(-1, got.exit_code);
    try testing.expectEqualStrings("Error", got.reason);
    try testing.expectEqual(ContainerState.unknown, (try parseContainerStatus("")).state);
}

test "readiness reads the runtime and network conditions apart" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var network: pb.Writer = .init(a);
    try network.string(1, "NetworkReady");
    try network.string(3, "NetworkPluginNotReady");
    var runtime: pb.Writer = .init(a);
    try runtime.string(1, "RuntimeReady");
    try runtime.boolean(2, true);
    var conditions: pb.Writer = .init(a);
    try conditions.message(1, network.bytes());
    try conditions.message(1, runtime.bytes());
    var response: pb.Writer = .init(a);
    try response.message(1, conditions.bytes());
    const readiness = try parseReadiness(response.bytes());
    try testing.expect(readiness.runtime.ready);
    try testing.expect(!readiness.network.ready);
    try testing.expectEqualStrings("NetworkPluginNotReady", readiness.network.reason);
    try testing.expect(!(try parseReadiness("")).runtime.ready);
}

test "pods listed by label come back as their ids, and a missing image reads as absent" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var response: pb.Writer = .init(a);
    for ([_][]const u8{ "p1", "p2" }) |id| try response.message(1, try one(a, 1, id));
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "p1", "p2" }), try parsePodIds(a, response.bytes()));
    try testing.expect(!try imagePresent(""));
    var image: pb.Writer = .init(a);
    try image.message(1, try one(a, 1, "sha256:abc"));
    try testing.expect(try imagePresent(image.bytes()));
}

test "dns comes from the host's resolv.conf, as kubelet gives a pod on the host network" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const dns = try parseResolvConf(arena.allocator(), "# x\nnameserver 10.0.0.2\nnameserver 1.1.1.1\nsearch lan corp\noptions ndots:2 edns0\n");
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "10.0.0.2", "1.1.1.1" }), dns.servers);
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "lan", "corp" }), dns.searches);
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "ndots:2", "edns0" }), dns.options);
}
