const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const contract = @import("contract");
const Env = contract.Env;
const Service = contract.Service;
const ExecSet = contract.ExecSet;
const Envelope = contract.Envelope;
const quoted = contract.quoted;

pub const Mount = struct {
    source: []const u8,
    destination: []const u8,
};

pub const Limits = struct {
    nofile: ?u64 = null,
    nproc: ?u64 = null,
    pids: ?u64 = null,
    io_weight: ?u32 = null,
    cpu_quota: ?[]const u8 = null,
};

pub const RunSpec = struct {
    entrypoint: ?[]const u8 = null,
    cmd: ?[]const u8 = null,
    workdir: ?[]const u8 = null,
    user: ?[]const u8 = null,
    env: []const []const u8 = &.{},
    mounts: []const Mount = &.{},
    ports: []const contract.PortMapping = &.{},
    memory: ?[]const u8 = null,
    cpus: ?f64 = null,
    limits: Limits = .{},
};

pub const Refusal = error{ NoRunCommand, NoImage };

pub fn runSpec(arena: Allocator, envelope: Envelope, from_files: Env) !RunSpec {
    const s = envelope.service;
    var env: Env = .{};
    for (from_files.map.keys(), from_files.map.values()) |k, v| try env.map.put(arena, k, v);
    for (s.env.map.keys(), s.env.map.values()) |k, v| try env.map.put(arena, k, v);
    const pairs = try arena.alloc([]const u8, env.map.count());
    for (env.map.keys(), env.map.values(), pairs) |k, v, *pair| pair.* = try std.fmt.allocPrint(arena, "{s}={s}", .{ k, v });

    const mounts = try arena.alloc(Mount, s.volumes.len);
    for (s.volumes, mounts) |v, *m| m.* = .{ .source = try envelope.mountSource(arena, v), .destination = v.destination };

    const r = s.resources;
    return .{
        .entrypoint = s.entrypoint,
        .cmd = s.cmd,
        .workdir = s.workdir,
        .user = s.user,
        .env = pairs,
        .mounts = mounts,
        .ports = s.publish,
        .memory = r.memory,
        .cpus = r.cpus,
        .limits = .{ .nofile = r.limit_nofile, .nproc = r.limit_nproc, .pids = r.tasks_max, .io_weight = r.io_weight, .cpu_quota = r.cpu_quota },
    };
}

pub fn execSet(arena: Allocator, envelope: Envelope, applz: []const u8, from_files: Env) (Refusal || Allocator.Error || error{WriteFailed})!ExecSet {
    const s = envelope.service;
    if (s.mode == .host) return .{
        .start = s.run_command orelse return error.NoRunCommand,
        .stop = s.stop_command,
        .reload = s.reload_command,
    };
    const image = s.image orelse return error.NoImage;
    const name = try envelope.containerName(arena);
    const spec = try std.json.Stringify.valueAlloc(arena, try runSpec(arena, envelope, from_files), .{ .emit_null_optional_fields = false });
    const encoded = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(spec.len));
    _ = std.base64.standard.Encoder.encode(encoded, spec);
    return .{
        .pre_start = try std.fmt.allocPrint(arena, "{f} pull {f}", .{ quoted(applz), quoted(image) }),
        .start = try std.fmt.allocPrint(arena, "{f} run {f} {f} --spec-base64 {s}", .{ quoted(applz), quoted(name), quoted(image), encoded }),
        .stop = try std.fmt.allocPrint(arena, "{f} stop {f}", .{ quoted(applz), quoted(name) }),
        .post_stop = try std.fmt.allocPrint(arena, "{f} rm {f}", .{ quoted(applz), quoted(name) }),
    };
}

pub fn explain(refusal: Refusal, service: Service, w: *Io.Writer) Io.Writer.Error!void {
    switch (refusal) {
        error.NoRunCommand => try w.print("service '{s}' is host-mode but has no RUN command\n", .{service.name}),
        error.NoImage => try w.print("service '{s}' is container-mode but has no FROM image\n", .{service.name}),
    }
}

fn testEnvelope(service: Service) Envelope {
    return .{ .contract = contract.base, .grove = "hum", .project_dir = "/proj", .data_dir = "/data/hum", .state_dir = "/state", .service = service };
}

test "a container becomes an applz run with its whole spec, plus pull, stop and rm around it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Service = .{ .name = "db", .mode = .container, .image = "postgres:16", .user = "999", .workdir = "/var/lib/postgresql" };
    try s.env.map.put(a, "POSTGRES_PASSWORD", "it's secret");
    try s.env.map.put(a, "FROM", "env");
    s.publish = &.{.{ .address = "127.0.0.1", .host = 5432, .container = 5432 }};
    s.volumes = &.{
        .{ .source = "pgdata", .destination = "/var/lib/postgresql/data", .is_named = true },
        .{ .source = "/proj/init", .destination = "/docker-entrypoint-initdb.d" },
        .{ .source = "/etc/hosts", .destination = "/etc/hosts" },
    };
    s.resources = .{ .memory = "1G", .cpus = 2, .limit_nofile = 4096, .tasks_max = 64, .cpu_quota = "50%" };
    var files: Env = .{};
    try files.map.put(a, "FROM", "file");
    try files.map.put(a, "ONLY_FILE", "yes");

    const set = try execSet(a, testEnvelope(s), "/opt/applz bin/applz", files);
    try testing.expectEqualStrings("'/opt/applz bin/applz' pull 'postgres:16'", set.pre_start.?);
    try testing.expectEqualStrings("'/opt/applz bin/applz' stop 'hum-db'", set.stop.?);
    try testing.expectEqualStrings("'/opt/applz bin/applz' rm 'hum-db'", set.post_stop.?);
    try testing.expectEqual(null, set.reload);

    const prefix = "'/opt/applz bin/applz' run 'hum-db' 'postgres:16' --spec-base64 ";
    try testing.expect(std.mem.startsWith(u8, set.start, prefix));
    const b64 = set.start[prefix.len..];
    const json = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(b64));
    try std.base64.standard.Decoder.decode(json, b64);
    const spec = try std.json.parseFromSliceLeaky(RunSpec, a, json, .{});
    try testing.expectEqual(3, spec.env.len);
    try testing.expectEqualStrings("FROM=env", spec.env[0]);
    try testing.expectEqualStrings("ONLY_FILE=yes", spec.env[1]);
    try testing.expectEqualStrings("POSTGRES_PASSWORD=it's secret", spec.env[2]);
    try testing.expectEqualStrings("/data/hum/db/volumes/pgdata", spec.mounts[0].source);
    try testing.expectEqualStrings("/proj/init", spec.mounts[1].source);
    try testing.expectEqualStrings("/etc/hosts", spec.mounts[2].source);
    try testing.expectEqual(5432, spec.ports[0].host);
    try testing.expectEqualStrings("1G", spec.memory.?);
    try testing.expectEqual(64, spec.limits.pids.?);
    try testing.expectEqualStrings("999", spec.user.?);
}

test "a host service runs as it would bare" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const set = try execSet(arena.allocator(), testEnvelope(.{
        .name = "web",
        .mode = .host,
        .run_command = "python app.py",
        .stop_command = "kill $MAINPID",
        .reload_command = "kill -HUP $MAINPID",
    }), "/x/applz", .{});
    try testing.expectEqualStrings("python app.py", set.start);
    try testing.expectEqualStrings("kill $MAINPID", set.stop.?);
    try testing.expectEqualStrings("kill -HUP $MAINPID", set.reload.?);
    try testing.expectEqual(null, set.pre_start);
}

test "a service without what it needs is refused by name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.NoImage, execSet(a, testEnvelope(.{ .name = "db", .mode = .container }), "/x", .{}));
    try testing.expectError(error.NoRunCommand, execSet(a, testEnvelope(.{ .name = "web", .mode = .host }), "/x", .{}));
    var out: Io.Writer.Allocating = .init(a);
    try explain(error.NoImage, .{ .name = "db", .mode = .container }, &out.writer);
    try testing.expectEqualStrings("service 'db' is container-mode but has no FROM image\n", out.written());
}
