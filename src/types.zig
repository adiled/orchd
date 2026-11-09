const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const Env = std.json.ArrayHashMap([]const u8);

pub const Mode = enum { container, host };

pub const RestartPolicy = enum { no, always, on_failure };

pub const RecreatePolicy = enum { always, never };

pub const PortMapping = struct {
    address: ?[]const u8 = null,
    host: u16,
    container: u16,
};

pub const VolumeMount = struct {
    source: []const u8,
    destination: []const u8,
    is_named: bool,
};

pub const ResourceLimits = struct {
    memory: ?[]const u8 = null,
    cpus: ?f64 = null,
    cpu_quota: ?[]const u8 = null,
    limit_nofile: ?u64 = null,
    limit_nproc: ?u64 = null,
    tasks_max: ?u64 = null,
    io_weight: ?u32 = null,
};

pub const RestartConfig = struct {
    policy: RestartPolicy = .no,
    delay: ?[]const u8 = null,
    start_limit_burst: ?u32 = null,
    start_limit_interval: ?[]const u8 = null,
};

pub const TimeoutConfig = struct {
    start: ?[]const u8 = null,
    stop: ?[]const u8 = null,
};

pub const LogConfig = struct {
    stdout: ?[]const u8 = null,
    stderr: ?[]const u8 = null,
};

pub const Service = struct {
    name: []const u8,
    mode: Mode,
    image: ?[]const u8 = null,
    run_command: ?[]const u8 = null,
    entrypoint: ?[]const u8 = null,
    cmd: ?[]const u8 = null,
    publish: []const PortMapping = &.{},
    volumes: []const VolumeMount = &.{},
    user: ?[]const u8 = null,
    stop_command: ?[]const u8 = null,
    reload_command: ?[]const u8 = null,
    workdir: ?[]const u8 = null,
    env: Env = .{},
    env_files: []const []const u8 = &.{},
    requires: []const []const u8 = &.{},
    after: []const []const u8 = &.{},
    healthcheck: ?[]const u8 = null,
    readiness_timeout: ?[]const u8 = null,
    oneshot: bool = false,
    disabled: bool = false,
    recreate: RecreatePolicy = .never,
    restart: RestartConfig = .{},
    timeouts: TimeoutConfig = .{},
    resources: ResourceLimits = .{},
    logging: LogConfig = .{},
};

pub const Spec = struct {
    version: []const u8,
    args: Env = .{},
    services: []const Service = &.{},

    pub fn find(spec: Spec, name: []const u8) ?Service {
        for (spec.services) |service| {
            if (std.mem.eql(u8, service.name, name)) return service;
        }
        return null;
    }
};

pub const ExecSet = struct {
    start: []const u8,
    pre_start: ?[]const u8 = null,
    stop: ?[]const u8 = null,
    post_stop: ?[]const u8 = null,
    reload: ?[]const u8 = null,
};

pub fn parseSpec(arena: Allocator, bytes: []const u8) !Spec {
    return std.json.parseFromSliceLeaky(Spec, arena, bytes, .{ .ignore_unknown_fields = true });
}

test "a spec reads what orch parse prints, with defaults for what it leaves out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spec = try parseSpec(arena.allocator(),
        \\{"version":"1.0.0-rc","args":{"FOO":"bar"},"services":[
        \\ {"name":"api","mode":"container","image":"myapp:latest",
        \\  "publish":[{"host":8080,"container":80}],
        \\  "volumes":[{"source":"/data","destination":"/app/data","is_named":false}],
        \\  "env":{"DB_HOST":"localhost"},"requires":["postgres"],
        \\  "oneshot":false,"disabled":false,"recreate":"always",
        \\  "restart":{"policy":"on_failure","delay":"5s","start_limit_burst":3},
        \\  "timeouts":{"stop":"10s"},"resources":{"memory":"512M","cpus":2.0},"logging":{}},
        \\ {"name":"web","mode":"host","run_command":"/usr/bin/nginx","oneshot":false,"disabled":true,
        \\  "recreate":"never","restart":{"policy":"no"},"timeouts":{},"resources":{},"logging":{}}]}
    );
    try testing.expectEqualStrings("bar", spec.args.map.get("FOO").?);
    const api = spec.find("api").?;
    try testing.expectEqual(.container, api.mode);
    try testing.expectEqual(8080, api.publish[0].host);
    try testing.expectEqualStrings("localhost", api.env.map.get("DB_HOST").?);
    try testing.expectEqual(.on_failure, api.restart.policy);
    try testing.expectEqual(3, api.restart.start_limit_burst.?);
    try testing.expectEqual(2.0, api.resources.cpus.?);
    const web = spec.find("web").?;
    try testing.expect(web.disabled);
    try testing.expectEqual(0, web.env.map.count());
    try testing.expectEqual(null, spec.find("absent"));
}

pub const Planted = struct {
    service: Service,
    set: ExecSet,
};

pub const Diagnostic = struct {
    message: []const u8 = "",

    pub fn set(d: *Diagnostic, arena: Allocator, comptime fmt: []const u8, args: anytype) void {
        d.message = std.fmt.allocPrint(arena, fmt, args) catch fmt;
    }
};

test "a diagnostic carries the message an error leaves behind" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    diag.set(arena.allocator(), "no bed is planted for {s}", .{"orch.web"});
    try testing.expectEqualStrings("no bed is planted for orch.web", diag.message);
}
