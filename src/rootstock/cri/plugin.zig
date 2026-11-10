const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const contract = @import("contract");
const cri = @import("cri.zig");
const network = @import("network");
const Env = contract.Env;
const Service = contract.Service;
const ExecSet = contract.ExecSet;
const Envelope = contract.Envelope;

pub const default_endpoints = [_][]const u8{
    "/run/containerd/containerd.sock",
    "/run/crio/crio.sock",
    "/var/run/cri-dockerd.sock",
};

pub const stop_timeout_s: u64 = 5;

pub const Network = network.Mode;

pub const RunSpec = struct {
    endpoint: []const u8,
    grove: []const u8,
    service: []const u8,
    pod: []const u8,
    image: []const u8,
    host_network: bool = false,
    ports: []const network.Port = &.{},
    command: []const []const u8 = &.{},
    args: []const []const u8 = &.{},
    env: []const [2][]const u8 = &.{},
    working_dir: []const u8 = "",
    user: []const u8 = "",
    mounts: []const cri.Mount = &.{},
    memory_bytes: ?u64 = null,
    cpu_quota_us: ?u64 = null,
    cpu_period_us: ?u64 = null,
    pids_max: ?u64 = null,
    log_dir: []const u8,

    pub fn labels(spec: RunSpec) [2][2][]const u8 {
        return .{ .{ "orchd.grove", spec.grove }, .{ "orchd.service", spec.service } };
    }

    pub fn container(spec: RunSpec, arena: Allocator) !cri.Container {
        var unified: std.ArrayList([2][]const u8) = .empty;
        if (spec.pids_max) |n| try unified.append(arena, .{ "pids.max", try std.fmt.allocPrint(arena, "{d}", .{n}) });
        const own = spec.labels();
        return .{
            .name = spec.service,
            .host_network = spec.host_network,
            .image = spec.image,
            .command = spec.command,
            .args = spec.args,
            .working_dir = spec.working_dir,
            .env = spec.env,
            .mounts = spec.mounts,
            .labels = try arena.dupe([2][]const u8, &own),
            .log_path = try logName(arena, spec),
            .user = cri.User.parse(spec.user),
            .memory_bytes = spec.memory_bytes,
            .cpu_quota_us = spec.cpu_quota_us,
            .cpu_period_us = spec.cpu_period_us,
            .unified = unified.items,
        };
    }
};

pub fn logName(arena: Allocator, spec: RunSpec) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}.log", .{spec.service});
}

pub fn endpointPath(value: []const u8) error{UnsupportedEndpoint}![]const u8 {
    const prefix = "unix://";
    if (std.mem.startsWith(u8, value, prefix)) return value[prefix.len..];
    if (std.mem.indexOf(u8, value, "://") != null) return error.UnsupportedEndpoint;
    return value;
}

pub fn runSpec(arena: Allocator, envelope: Envelope, endpoint: []const u8, mode: Network, from_files: Env) !RunSpec {
    const s = envelope.service;
    const pod = try envelope.containerName(arena);

    const ports = try network.ports(arena, s.publish, mode);

    var env: Env = .{};
    for (from_files.map.keys(), from_files.map.values()) |k, v| try env.map.put(arena, k, v);
    for (s.env.map.keys(), s.env.map.values()) |k, v| try env.map.put(arena, k, v);
    const pairs = try arena.alloc([2][]const u8, env.map.count());
    for (env.map.keys(), env.map.values(), pairs) |k, v, *pair| pair.* = .{ k, v };

    const mounts = try arena.alloc(cri.Mount, s.volumes.len);
    for (s.volumes, mounts) |v, *m| m.* = .{ .host_path = try envelope.mountSource(arena, v), .container_path = v.destination, .readonly = v.read_only };

    const r = s.resources;
    const cpu = r.cpu();
    return .{
        .endpoint = endpoint,
        .grove = envelope.grove,
        .service = s.name,
        .pod = pod,
        .image = try contract.normalizeImage(arena, s.image orelse return error.NoImage),
        .host_network = mode == .host,
        .ports = ports,
        .command = if (s.entrypoint) |e| try contract.words(arena, e) else &.{},
        .args = if (s.cmd) |c| try contract.words(arena, c) else &.{},
        .env = pairs,
        .working_dir = s.workdir orelse "",
        .user = s.user orelse "",
        .mounts = mounts,
        .memory_bytes = r.memoryBytes(),
        .cpu_quota_us = if (cpu) |c| c.quota_us else null,
        .cpu_period_us = if (cpu) |c| c.period_us else null,
        .pids_max = r.pidsMax(),
        .log_dir = try std.fs.path.join(arena, &.{ envelope.state_dir, "cri", pod }),
    };
}

pub fn execSet(arena: Allocator, envelope: Envelope, self: []const u8, endpoint: []const u8, mode: Network, from_files: Env) !ExecSet {
    const s = envelope.service;
    if (s.mode == .host) return .{
        .start = s.run_command orelse return error.NoRunCommand,
        .stop = s.stop_command,
        .reload = s.reload_command,
    };
    const spec = try std.json.Stringify.valueAlloc(arena, try runSpec(arena, envelope, endpoint, mode, from_files), .{ .emit_null_optional_fields = false });
    const encoded = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(spec.len));
    _ = std.base64.standard.Encoder.encode(encoded, spec);
    return .{ .start = try std.fmt.allocPrint(arena, "{f} run --spec-base64 {s}", .{ contract.quoted(self), encoded }) };
}

pub fn removalSpec(arena: Allocator, envelope: Envelope, endpoint: []const u8) !RunSpec {
    const pod = try envelope.containerName(arena);
    return .{
        .endpoint = endpoint,
        .grove = envelope.grove,
        .service = envelope.service.name,
        .pod = pod,
        .image = envelope.service.image orelse "",
        .log_dir = try std.fs.path.join(arena, &.{ envelope.state_dir, "cri", pod }),
    };
}

pub fn decodeRunSpec(arena: Allocator, b64: []const u8) !RunSpec {
    const dec = std.base64.standard.Decoder;
    const json = try arena.alloc(u8, try dec.calcSizeForSlice(b64));
    try dec.decode(json, b64);
    return std.json.parseFromSliceLeaky(RunSpec, arena, json, .{ .allocate = .alloc_always });
}

pub fn explain(refusal: anyerror, service: Service, w: *Io.Writer) Io.Writer.Error!void {
    switch (refusal) {
        error.NoRunCommand => try w.print("service '{s}' is host-mode but has no RUN command\n", .{service.name}),
        error.NoImage => try w.print("service '{s}' is container-mode but has no FROM image\n", .{service.name}),
        error.UnterminatedQuote => try w.print("service '{s}': ENTRYPOINT or CMD has an unterminated quote\n", .{service.name}),
        error.PublishNeedsPodNetwork => try w.print("service '{s}': with ORCHD_CRI_NETWORK=host a container's ports are the host's, " ++
            "so PUBLISH can only be port:port on every address; leave ORCHD_CRI_NETWORK unset to publish through the pod network\n", .{service.name}),
        else => try w.print("service '{s}': {t}\n", .{ service.name, refusal }),
    }
}

pub fn explainEndpoint(err: anyerror, w: *Io.Writer) Io.Writer.Error!void {
    switch (err) {
        error.NoEndpoint => try w.writeAll("no CRI runtime answered at " ++ default_endpoints[0] ++ ", " ++
            default_endpoints[1] ++ " or " ++ default_endpoints[2] ++ "; set ORCHD_CRI_ENDPOINT\n"),
        error.UnsupportedEndpoint => try w.writeAll("ORCHD_CRI_ENDPOINT must be a unix socket: unix:///path or /path\n"),
        error.UnknownNetwork => try w.writeAll("ORCHD_CRI_NETWORK is pod (the default) or host\n"),
        else => try w.print("CRI endpoint: {t}\n", .{err}),
    }
}

fn testEnvelope(s: Service) Envelope {
    return .{ .contract = contract.base, .grove = "hum", .project_dir = "/proj", .data_dir = "/data/hum", .state_dir = "/state", .service = s };
}

test "a container becomes one foreground run carrying its whole spec" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Service = .{ .name = "web", .mode = .container, .image = "nginx:alpine", .entrypoint = "/docker-entrypoint.sh", .cmd = "nginx -g 'daemon off;'", .user = "101:101", .workdir = "/srv" };
    try s.env.map.put(a, "MODE", "env");
    s.volumes = &.{ .{ .source = "site", .destination = "/usr/share/nginx/html", .is_named = true }, .{ .source = "/proj/conf", .destination = "/etc/nginx/conf.d" } };
    s.resources = .{ .memory = "256M", .cpus = 1.5, .tasks_max = 64 };
    var files: Env = .{};
    try files.map.put(a, "MODE", "file");
    try files.map.put(a, "FROM_FILE", "yes");

    const set = try execSet(a, testEnvelope(s), "/usr/local/bin/orchd-rootstock-cri", "/run/crio/crio.sock", .pod, files);
    try testing.expectEqual(null, set.stop);
    const prefix = "'/usr/local/bin/orchd-rootstock-cri' run --spec-base64 ";
    try testing.expect(std.mem.startsWith(u8, set.start, prefix));

    const spec = try decodeRunSpec(a, set.start[prefix.len..]);
    try testing.expectEqualStrings("/run/crio/crio.sock", spec.endpoint);
    try testing.expect(!spec.host_network);
    try testing.expectEqualStrings("hum-web", spec.pod);
    try testing.expectEqualStrings("docker.io/library/nginx:alpine", spec.image);
    try testing.expectEqualDeep(@as([]const []const u8, &.{"/docker-entrypoint.sh"}), spec.command);
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "nginx", "-g", "daemon off;" }), spec.args);
    try testing.expectEqualDeep(@as([]const [2][]const u8, &.{ .{ "MODE", "env" }, .{ "FROM_FILE", "yes" } }), spec.env);
    try testing.expectEqualStrings("/data/hum/web/volumes/site", spec.mounts[0].host_path);
    try testing.expectEqualStrings("/proj/conf", spec.mounts[1].host_path);
    try testing.expectEqualStrings("/state/cri/hum-web", spec.log_dir);
    try testing.expectEqual(256 << 20, spec.memory_bytes.?);
    try testing.expectEqual(150_000, spec.cpu_quota_us.?);

    const c = try spec.container(a);
    try testing.expectEqualStrings("web.log", c.log_path);
    try testing.expectEqual(101, c.user.gid.?);
    try testing.expectEqualDeep(@as([]const [2][]const u8, &.{.{ "pids.max", "64" }}), c.unified);
    try testing.expectEqualStrings("hum", c.labels[0][1]);
}

test "without ENTRYPOINT or CMD the image's own run, as Kubernetes does" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spec = try runSpec(a, testEnvelope(.{ .name = "db", .mode = .container, .image = "postgres:16" }), "/s", .pod, .{});
    try testing.expectEqual(0, spec.command.len);
    try testing.expectEqual(0, spec.args.len);
    try testing.expectEqual(null, spec.memory_bytes);
    try testing.expectEqual(0, (try spec.container(a)).unified.len);
}

test "a host service runs as it would bare, and what cannot run is refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const set = try execSet(a, testEnvelope(.{ .name = "web", .mode = .host, .run_command = "python app.py", .reload_command = "kill -HUP $MAINPID" }), "/x", "/s", .pod, .{});
    try testing.expectEqualStrings("python app.py", set.start);
    try testing.expectEqualStrings("kill -HUP $MAINPID", set.reload.?);
    try testing.expectError(error.NoRunCommand, execSet(a, testEnvelope(.{ .name = "web", .mode = .host }), "/x", "/s", .pod, .{}));
    try testing.expectError(error.NoImage, execSet(a, testEnvelope(.{ .name = "db", .mode = .container }), "/x", "/s", .pod, .{}));
    try testing.expectError(error.UnterminatedQuote, execSet(a, testEnvelope(.{ .name = "db", .mode = .container, .image = "x", .cmd = "sh -c 'half" }), "/x", "/s", .pod, .{}));
}

test "an endpoint is a unix socket, given as a path or a unix:// URL" {
    try testing.expectEqualStrings("/run/crio/crio.sock", try endpointPath("unix:///run/crio/crio.sock"));
    try testing.expectEqualStrings("/run/crio/crio.sock", try endpointPath("/run/crio/crio.sock"));
    try testing.expectError(error.UnsupportedEndpoint, endpointPath("tcp://10.0.0.1:2376"));
}

test "PUBLISH forwards into the pod network, and the host network takes only port:port on every address" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Service = .{ .name = "web", .mode = .container, .image = "nginx" };
    s.publish = &.{ .{ .address = "127.0.0.1", .host = 18080, .container = 80 }, .{ .host = 5433, .container = 5432 } };
    const pod = try runSpec(a, testEnvelope(s), "/s", .pod, .{});
    try testing.expectEqual(2, pod.ports.len);
    try testing.expectEqual(18080, pod.ports[0].host);
    try testing.expectEqualStrings("127.0.0.1", pod.ports[0].address);
    try testing.expectEqualStrings("", pod.ports[1].address);
    try testing.expectError(error.PublishNeedsPodNetwork, runSpec(a, testEnvelope(s), "/s", .host, .{}));

    s.publish = &.{ .{ .host = 8080, .container = 8080 }, .{ .address = "0.0.0.0", .host = 53, .container = 53 } };
    const shared = try runSpec(a, testEnvelope(s), "/s", .host, .{});
    try testing.expect(shared.host_network);
    try testing.expectEqual(0, shared.ports.len);
    try testing.expect((try shared.container(a)).host_network);
}
