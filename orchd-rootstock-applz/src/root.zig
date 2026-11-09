const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const contract: u32 = 1;

pub const Env = std.json.ArrayHashMap([]const u8);

pub const Port = struct {
    address: ?[]const u8 = null,
    host: u16,
    container: u16,
};

pub const Volume = struct {
    source: []const u8,
    destination: []const u8,
    is_named: bool = false,
};

pub const Resources = struct {
    memory: ?[]const u8 = null,
    cpus: ?f64 = null,
    cpu_quota: ?[]const u8 = null,
    limit_nofile: ?u64 = null,
    limit_nproc: ?u64 = null,
    tasks_max: ?u64 = null,
    io_weight: ?u32 = null,
};

pub const Mode = enum { host, container };

pub const Service = struct {
    name: []const u8,
    mode: Mode,
    image: ?[]const u8 = null,
    run_command: ?[]const u8 = null,
    stop_command: ?[]const u8 = null,
    reload_command: ?[]const u8 = null,
    entrypoint: ?[]const u8 = null,
    cmd: ?[]const u8 = null,
    publish: []const Port = &.{},
    volumes: []const Volume = &.{},
    user: ?[]const u8 = null,
    workdir: ?[]const u8 = null,
    env: Env = .{},
    env_files: []const []const u8 = &.{},
    resources: Resources = .{},
};

pub const Envelope = struct {
    contract: u32,
    grove: []const u8,
    project_dir: []const u8,
    data_dir: []const u8,
    state_dir: []const u8,
    service: Service,
};

pub const ExecSet = struct {
    start: []const u8,
    pre_start: ?[]const u8 = null,
    stop: ?[]const u8 = null,
    post_stop: ?[]const u8 = null,
    reload: ?[]const u8 = null,
};

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
    ports: []const Port = &.{},
    memory: ?[]const u8 = null,
    cpus: ?f64 = null,
    limits: Limits = .{},
};

pub const Refusal = error{ NoRunCommand, NoImage };

pub fn parseEnvelope(arena: Allocator, bytes: []const u8) !Envelope {
    const envelope = try std.json.parseFromSliceLeaky(Envelope, arena, bytes, .{ .ignore_unknown_fields = true });
    if (envelope.contract != contract) return error.ContractMismatch;
    return envelope;
}

pub fn containerName(arena: Allocator, envelope: Envelope) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}-{s}", .{ envelope.grove, envelope.service.name });
}

pub fn volumeDir(arena: Allocator, envelope: Envelope, volume: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ envelope.data_dir, envelope.service.name, "volumes", volume });
}

pub fn mountSource(arena: Allocator, envelope: Envelope, volume: Volume) ![]const u8 {
    if (volume.is_named) return volumeDir(arena, envelope, volume.source);
    if (std.fs.path.isAbsolute(volume.source)) return volume.source;
    return std.fs.path.join(arena, &.{ envelope.project_dir, volume.source });
}

pub fn parseEnvFile(arena: Allocator, content: []const u8, into: *Env) !void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const body = if (std.mem.startsWith(u8, line, "export ")) std.mem.trimStart(u8, line["export ".len..], " \t") else line;
        const eq = std.mem.indexOfScalar(u8, body, '=') orelse continue;
        const key = std.mem.trim(u8, body[0..eq], " \t");
        if (key.len == 0) continue;
        var value = std.mem.trim(u8, body[eq + 1 ..], " \t");
        if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\''))) {
            value = value[1 .. value.len - 1];
        }
        try into.map.put(arena, key, value);
    }
}

pub fn runSpec(arena: Allocator, envelope: Envelope, from_files: Env) !RunSpec {
    const s = envelope.service;
    var env: Env = .{};
    for (from_files.map.keys(), from_files.map.values()) |k, v| try env.map.put(arena, k, v);
    for (s.env.map.keys(), s.env.map.values()) |k, v| try env.map.put(arena, k, v);
    const pairs = try arena.alloc([]const u8, env.map.count());
    for (env.map.keys(), env.map.values(), pairs) |k, v, *pair| pair.* = try std.fmt.allocPrint(arena, "{s}={s}", .{ k, v });

    const mounts = try arena.alloc(Mount, s.volumes.len);
    for (s.volumes, mounts) |v, *m| m.* = .{ .source = try mountSource(arena, envelope, v), .destination = v.destination };

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

pub const Quoted = struct {
    text: []const u8,

    pub fn format(q: Quoted, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeByte('\'');
        for (q.text) |c| if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c);
        try w.writeByte('\'');
    }
};

fn quoted(text: []const u8) Quoted {
    return .{ .text = text };
}

pub fn execSet(arena: Allocator, envelope: Envelope, applz: []const u8, from_files: Env) (Refusal || Allocator.Error || error{WriteFailed})!ExecSet {
    const s = envelope.service;
    if (s.mode == .host) return .{
        .start = s.run_command orelse return error.NoRunCommand,
        .stop = s.stop_command,
        .reload = s.reload_command,
    };
    const image = s.image orelse return error.NoImage;
    const name = try containerName(arena, envelope);
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

pub fn emit(set: ExecSet, w: *Io.Writer) Io.Writer.Error!void {
    try std.json.Stringify.value(set, .{}, w);
    try w.writeByte('\n');
}

fn testEnvelope(service: Service) Envelope {
    return .{ .contract = 1, .grove = "hum", .project_dir = "/proj", .data_dir = "/data/hum", .state_dir = "/state", .service = service };
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
        .{ .source = "./init", .destination = "/docker-entrypoint-initdb.d" },
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
    try testing.expectEqualStrings("/proj/./init", spec.mounts[1].source);
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

test "env files take comments, export and quotes, and the last word wins" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: Env = .{};
    try parseEnvFile(arena.allocator(), "# c\nexport A = 1\nB=\"two words\"\nnoise\nA=3\n", &env);
    try testing.expectEqualStrings("3", env.map.get("A").?);
    try testing.expectEqualStrings("two words", env.map.get("B").?);
    try testing.expectEqual(2, env.map.count());
}

test "the envelope reads what orchd sends, and refuses another contract" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e = try parseEnvelope(a,
        \\{"contract":1,"grove":"hum","project_dir":"/p","data_dir":"/d","state_dir":"/s",
        \\ "service":{"name":"db","mode":"container","image":"postgres:16","env":{"A":"b"},
        \\  "oneshot":false,"restart":{"policy":"always"},"timeouts":{},"logging":{}}}
    );
    try testing.expectEqualStrings("postgres:16", e.service.image.?);
    try testing.expectEqualStrings("b", e.service.env.map.get("A").?);
    try testing.expectError(error.ContractMismatch, parseEnvelope(a,
        \\{"contract":2,"grove":"g","project_dir":"/p","data_dir":"/d","state_dir":"/s","service":{"name":"x","mode":"host"}}
    ));
}
