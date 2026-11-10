const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const contract = @import("contract");

pub const Env = contract.Env;
pub const Service = contract.Service;
pub const ExecSet = contract.ExecSet;
pub const VolumeMount = contract.VolumeMount;

pub const Spec = struct {
    schema_version: ?u32 = null,
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

pub fn parseSpec(arena: Allocator, bytes: []const u8) !Spec {
    return std.json.parseFromSliceLeaky(Spec, arena, bytes, .{ .ignore_unknown_fields = true });
}

test "a spec reads what orch resolve --json prints, with defaults for what it leaves out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spec = try parseSpec(arena.allocator(),
        \\{"schema_version":1,"version":"1.0.0-rc","args":{"FOO":"bar"},"services":[
        \\ {"name":"api","mode":"container","image":"myapp:latest",
        \\  "publish":[{"host":8080,"container":80}],
        \\  "volumes":[{"source":"/data","destination":"/app/data","is_named":false,"read_only":false}],
        \\  "env":{"DB_HOST":"localhost"},"requires":["postgres"],
        \\  "oneshot":false,"disabled":false,"recreate":"always",
        \\  "restart":{"policy":"on_failure","delay":"5s","start_limit_burst":3},
        \\  "timeouts":{"stop":"10s"},"resources":{"memory":"512M","cpus":2.0},"logging":{}},
        \\ {"name":"web","mode":"host","run_command":"/usr/bin/nginx","oneshot":false,"disabled":true,
        \\  "recreate":"never","restart":{"policy":"no"},"timeouts":{},"resources":{},"logging":{}}]}
    );
    try testing.expectEqual(1, spec.schema_version.?);
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
