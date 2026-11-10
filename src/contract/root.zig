const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const base: u32 = 1;
pub const removal: u32 = 2;

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
    is_named: bool = false,
};

pub const ResourceLimits = struct {
    memory: ?[]const u8 = null,
    cpus: ?f64 = null,
    cpu_quota: ?[]const u8 = null,
    limit_nofile: ?u64 = null,
    limit_nproc: ?u64 = null,
    tasks_max: ?u64 = null,
    io_weight: ?u32 = null,

    pub const Cpu = struct { quota_us: u64, period_us: u64 };

    pub fn memoryBytes(r: ResourceLimits) ?u64 {
        const t = std.mem.trim(u8, r.memory orelse return null, " ");
        if (t.len < 2) return null;
        const unit: u64 = switch (t[t.len - 1]) {
            'K' => 1 << 10,
            'M' => 1 << 20,
            'G' => 1 << 30,
            else => return null,
        };
        const n = std.fmt.parseInt(u64, t[0 .. t.len - 1], 10) catch return null;
        return std.math.mul(u64, n, unit) catch null;
    }

    pub fn cpu(r: ResourceLimits) ?Cpu {
        const period: u64 = 100_000;
        if (r.cpus) |cpus| {
            if (cpus <= 0) return null;
            return .{ .quota_us = @intFromFloat(cpus * @as(f64, @floatFromInt(period))), .period_us = period };
        }
        const pct = std.fmt.parseInt(u64, std.mem.trim(u8, r.cpu_quota orelse return null, " %"), 10) catch return null;
        if (pct == 0) return null;
        return .{ .quota_us = pct * 1000, .period_us = period };
    }

    pub fn pidsMax(r: ResourceLimits) ?u64 {
        return r.tasks_max orelse r.limit_nproc;
    }
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

pub const ExecSet = struct {
    start: []const u8,
    pre_start: ?[]const u8 = null,
    stop: ?[]const u8 = null,
    post_stop: ?[]const u8 = null,
    reload: ?[]const u8 = null,

    pub fn write(set: ExecSet, w: *Io.Writer) Io.Writer.Error!void {
        try std.json.Stringify.value(set, .{}, w);
        try w.writeByte('\n');
    }
};

pub const Envelope = struct {
    contract: u32,
    grove: []const u8,
    project_dir: []const u8,
    data_dir: []const u8,
    state_dir: []const u8,
    service: Service,

    pub fn parse(arena: Allocator, bytes: []const u8) !Envelope {
        const envelope = try std.json.parseFromSliceLeaky(Envelope, arena, bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        if (envelope.contract != base) return error.ContractMismatch;
        return envelope;
    }

    pub fn containerName(e: Envelope, arena: Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s}-{s}", .{ e.grove, e.service.name });
    }

    pub fn volumeDir(e: Envelope, arena: Allocator, volume: []const u8) ![]const u8 {
        return std.fs.path.join(arena, &.{ e.data_dir, e.service.name, "volumes", volume });
    }

    pub fn mountSource(e: Envelope, arena: Allocator, volume: VolumeMount) ![]const u8 {
        if (volume.is_named) return e.volumeDir(arena, volume.source);
        if (std.fs.path.isAbsolute(volume.source)) return volume.source;
        return std.fs.path.join(arena, &.{ e.project_dir, volume.source });
    }

    pub fn envFiles(e: Envelope, arena: Allocator, io: Io) !Env {
        var env: Env = .{};
        for (e.service.env_files) |file| {
            const path = if (std.fs.path.isAbsolute(file)) file else try std.fs.path.join(arena, &.{ e.project_dir, file });
            const content = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch continue;
            try parseEnvFile(arena, content, &env);
        }
        return env;
    }
};

pub fn readEnvelope(arena: Allocator, io: Io, plugin: []const u8, stderr: *Io.Writer) !?Envelope {
    var buffer: [4096]u8 = undefined;
    var reader: Io.File.Reader = .initStreaming(.stdin(), io, &buffer);
    const bytes = try reader.interface.allocRemaining(arena, .limited(1 << 20));
    return Envelope.parse(arena, bytes) catch |err| {
        switch (err) {
            error.ContractMismatch => try stderr.print("{s} speaks contract {d}\n", .{ plugin, base }),
            else => try stderr.print("unreadable envelope: {t}\n", .{err}),
        }
        return null;
    };
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

pub fn words(arena: Allocator, s: []const u8) error{ UnterminatedQuote, OutOfMemory }![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var in_word = false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            ' ', '\t', '\n' => if (in_word) {
                try out.append(arena, try word.toOwnedSlice(arena));
                in_word = false;
            },
            '\'' => {
                in_word = true;
                const end = std.mem.indexOfScalarPos(u8, s, i + 1, '\'') orelse return error.UnterminatedQuote;
                try word.appendSlice(arena, s[i + 1 .. end]);
                i = end;
            },
            '"' => {
                in_word = true;
                i += 1;
                while (true) : (i += 1) {
                    if (i >= s.len) return error.UnterminatedQuote;
                    if (s[i] == '"') break;
                    if (s[i] == '\\' and i + 1 < s.len and std.mem.indexOfScalar(u8, "\"\\$`", s[i + 1]) != null) i += 1;
                    try word.append(arena, s[i]);
                }
            },
            '\\' => {
                in_word = true;
                if (i + 1 < s.len) {
                    i += 1;
                    try word.append(arena, s[i]);
                }
            },
            else => |ch| {
                in_word = true;
                try word.append(arena, ch);
            },
        }
    }
    if (in_word) try out.append(arena, try word.toOwnedSlice(arena));
    return out.items;
}

pub fn normalizeImage(arena: Allocator, reference: []const u8) ![]const u8 {
    const named = if (std.mem.indexOfScalar(u8, reference, '/')) |i| blk: {
        const first = reference[0..i];
        const is_registry = std.mem.indexOfAny(u8, first, ".:") != null or std.mem.eql(u8, first, "localhost");
        break :blk if (is_registry) reference else try std.fmt.allocPrint(arena, "docker.io/{s}", .{reference});
    } else try std.fmt.allocPrint(arena, "docker.io/library/{s}", .{reference});
    const last = named[(std.mem.lastIndexOfScalar(u8, named, '/') orelse 0)..];
    if (std.mem.indexOfAny(u8, last, ":@") != null) return named;
    return std.fmt.allocPrint(arena, "{s}:latest", .{named});
}

pub const Quoted = struct {
    text: []const u8,

    pub fn format(q: Quoted, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeByte('\'');
        for (q.text) |ch| if (ch == '\'') try w.writeAll("'\\''") else try w.writeByte(ch);
        try w.writeByte('\'');
    }
};

pub fn quoted(text: []const u8) Quoted {
    return .{ .text = text };
}

fn testEnvelope(service: Service) Envelope {
    return .{ .contract = base, .grove = "hum", .project_dir = "/proj", .data_dir = "/data/hum", .state_dir = "/state", .service = service };
}

test "the envelope reads what orchd sends and passes over what a rootstock does not use" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const envelope = try Envelope.parse(arena.allocator(),
        \\{"contract":1,"grove":"hum","project_dir":"/p","data_dir":"/d","state_dir":"/s","later":true,
        \\ "service":{"name":"web","mode":"host","run_command":"sleep 1","env":{"A":"b"},"someday":1,
        \\  "oneshot":false,"disabled":true,"recreate":"always","restart":{"policy":"on_failure"},
        \\  "volumes":[{"source":"site","destination":"/srv"}],"timeouts":{},"resources":{},"logging":{}}}
    );
    try testing.expectEqualStrings("hum", envelope.grove);
    try testing.expectEqualStrings("/d", envelope.data_dir);
    try testing.expectEqualStrings("web", envelope.service.name);
    try testing.expectEqual(.host, envelope.service.mode);
    try testing.expectEqual(.always, envelope.service.recreate);
    try testing.expectEqual(.on_failure, envelope.service.restart.policy);
    try testing.expectEqualStrings("b", envelope.service.env.map.get("A").?);
    try testing.expect(!envelope.service.volumes[0].is_named);
    try testing.expectEqual(null, envelope.service.stop_command);
}

test "an envelope from another contract is refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.ContractMismatch, Envelope.parse(arena.allocator(),
        \\{"contract":2,"grove":"g","project_dir":"/p","data_dir":"/d","state_dir":"/s",
        \\ "service":{"name":"web","mode":"host"}}
    ));
}

test "a container is named for its grove, and its volumes find their sources" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e = testEnvelope(.{ .name = "db", .mode = .container });
    try testing.expectEqualStrings("hum-db", try e.containerName(a));
    try testing.expectEqualStrings("/data/hum/db/volumes/pgdata", try e.mountSource(a, .{ .source = "pgdata", .destination = "/d", .is_named = true }));
    try testing.expectEqualStrings("/proj/./init", try e.mountSource(a, .{ .source = "./init", .destination = "/i" }));
    try testing.expectEqualStrings("/etc/hosts", try e.mountSource(a, .{ .source = "/etc/hosts", .destination = "/etc/hosts" }));
}

test "the exec set goes out as one line of JSON with every field named" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try (ExecSet{ .start = "sleep 1", .reload = "kill -HUP $MAINPID" }).write(&out.writer);
    try testing.expectEqualStrings(
        "{\"start\":\"sleep 1\",\"pre_start\":null,\"stop\":null,\"post_stop\":null,\"reload\":\"kill -HUP $MAINPID\"}\n",
        out.written(),
    );
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

test "env files are read from the project, and a missing one is passed over" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".env", .data = "A=1\n" });
    var e = testEnvelope(.{ .name = "web", .mode = .host, .env_files = &.{ ".env", "absent.env" } });
    e.project_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const env = try e.envFiles(a, testing.io);
    try testing.expectEqualStrings("1", env.map.get("A").?);
    try testing.expectEqual(1, env.map.count());
}

test "words split like a shell: quotes hold spaces, backslashes escape" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "nginx", "-g", "daemon off;" }), try words(a, "nginx -g 'daemon off;'"));
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "sh", "-c", "echo \"$A\" b" }), try words(a, "sh  -c \"echo \\\"\\$A\\\" b\""));
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "a b", "" }), try words(a, "a\\ b ''"));
    try testing.expectEqual(0, (try words(a, "  ")).len);
    try testing.expectError(error.UnterminatedQuote, words(a, "sh -c 'half"));
}

test "a quoted word survives the shell, single quotes and all" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try out.writer.print("{f}", .{quoted("/opt/it's here")});
    try testing.expectEqualStrings("'/opt/it'\\''s here'", out.written());
}

test "a FROM reads as Docker reads it: docker.io, library and latest when left out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("docker.io/library/alpine:3.20", try normalizeImage(a, "alpine:3.20"));
    try testing.expectEqualStrings("docker.io/library/alpine:latest", try normalizeImage(a, "alpine"));
    try testing.expectEqualStrings("docker.io/bitnami/redis:7", try normalizeImage(a, "bitnami/redis:7"));
    try testing.expectEqualStrings("ghcr.io/apple/x:1", try normalizeImage(a, "ghcr.io/apple/x:1"));
    try testing.expectEqualStrings("localhost:5000/app:latest", try normalizeImage(a, "localhost:5000/app"));
    try testing.expectEqualStrings("docker.io/library/alpine@sha256:abc", try normalizeImage(a, "alpine@sha256:abc"));
}

test "limits read MEMORY with its unit, CPUS before CPU_QUOTA, and TASKS_MAX before LIMIT_NPROC" {
    try testing.expectEqual(256 << 20, (ResourceLimits{ .memory = "256M" }).memoryBytes().?);
    try testing.expectEqual(2 << 30, (ResourceLimits{ .memory = " 2G" }).memoryBytes().?);
    try testing.expectEqual(null, (ResourceLimits{ .memory = "512" }).memoryBytes());
    try testing.expectEqual(null, (ResourceLimits{}).memoryBytes());
    try testing.expectEqual(ResourceLimits.Cpu{ .quota_us = 150_000, .period_us = 100_000 }, (ResourceLimits{ .cpus = 1.5, .cpu_quota = "20%" }).cpu().?);
    try testing.expectEqual(ResourceLimits.Cpu{ .quota_us = 50_000, .period_us = 100_000 }, (ResourceLimits{ .cpu_quota = "50%" }).cpu().?);
    try testing.expectEqual(null, (ResourceLimits{ .cpu_quota = "0%" }).cpu());
    try testing.expectEqual(null, (ResourceLimits{}).cpu());
    try testing.expectEqual(64, (ResourceLimits{ .tasks_max = 64, .limit_nproc = 9 }).pidsMax().?);
    try testing.expectEqual(9, (ResourceLimits{ .limit_nproc = 9 }).pidsMax().?);
}
