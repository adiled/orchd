const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const image = @import("image.zig");
const oci = @import("oci.zig");

pub const contract: u32 = 1;
pub const removal_contract: u32 = 2;
pub const default_socket = "/run/containerd/containerd.sock";
pub const default_snapshotter = "overlayfs";

pub const Env = std.json.ArrayHashMap([]const u8);

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

pub const Recreate = enum { always, never };

pub const Service = struct {
    name: []const u8,
    mode: Mode,
    image: ?[]const u8 = null,
    run_command: ?[]const u8 = null,
    stop_command: ?[]const u8 = null,
    reload_command: ?[]const u8 = null,
    entrypoint: ?[]const u8 = null,
    cmd: ?[]const u8 = null,
    volumes: []const Volume = &.{},
    user: ?[]const u8 = null,
    workdir: ?[]const u8 = null,
    env: Env = .{},
    env_files: []const []const u8 = &.{},
    resources: Resources = .{},
    recreate: Recreate = .never,
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

pub const RunSpec = struct {
    socket: []const u8,
    namespace: []const u8,
    snapshotter: []const u8 = default_snapshotter,
    image: []const u8,
    container_id: []const u8,
    fifo_dir: []const u8,
    entrypoint: ?[]const []const u8 = null,
    cmd: ?[]const []const u8 = null,
    env: []const []const u8 = &.{},
    cwd: []const u8 = "",
    user: []const u8 = "",
    mounts: []const oci.BindMount = &.{},
    resources: oci.Resources = .{},
    no_pivot_root: bool = false,
    recreate: Recreate = .never,
    definition: []const u8 = "",
};

pub fn definitionOf(arena: Allocator, spec: RunSpec) ![]const u8 {
    var unhashed = spec;
    unhashed.definition = "";
    unhashed.recreate = .never;
    const json = try std.json.Stringify.valueAlloc(arena, unhashed, .{ .emit_null_optional_fields = false });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(json, &digest, .{});
    return std.fmt.allocPrint(arena, "{x}", .{&digest});
}

pub const Refusal = error{ NoRunCommand, NoImage, UnterminatedQuote };

pub fn parseEnvelope(arena: Allocator, bytes: []const u8) !Envelope {
    const envelope = try std.json.parseFromSliceLeaky(Envelope, arena, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    if (envelope.contract != contract) return error.ContractMismatch;
    return envelope;
}

pub fn containerId(arena: Allocator, envelope: Envelope) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}-{s}", .{ envelope.grove, envelope.service.name });
}

pub fn volumeDir(arena: Allocator, envelope: Envelope, volume: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ envelope.data_dir, envelope.service.name, "volumes", volume });
}

fn mountSource(arena: Allocator, envelope: Envelope, v: Volume) ![]const u8 {
    if (v.is_named) return volumeDir(arena, envelope, v.source);
    if (std.fs.path.isAbsolute(v.source)) return v.source;
    return std.fs.path.join(arena, &.{ envelope.project_dir, v.source });
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

fn memoryBytes(s: []const u8) ?u64 {
    const t = std.mem.trim(u8, s, " ");
    if (t.len < 2) return null;
    const mult: u64 = switch (t[t.len - 1]) {
        'K' => 1 << 10,
        'M' => 1 << 20,
        'G' => 1 << 30,
        else => return null,
    };
    const n = std.fmt.parseInt(u64, t[0 .. t.len - 1], 10) catch return null;
    return std.math.mul(u64, n, mult) catch null;
}

fn quotaPercent(s: []const u8) ?u64 {
    const pct = std.fmt.parseInt(u64, std.mem.trim(u8, s, " %"), 10) catch return null;
    return if (pct == 0) null else pct * 1000;
}

pub fn runSpec(arena: Allocator, envelope: Envelope, socket: []const u8, from_files: Env) !RunSpec {
    const s = envelope.service;
    const id = try containerId(arena, envelope);

    var env: Env = .{};
    for (from_files.map.keys(), from_files.map.values()) |k, v| try env.map.put(arena, k, v);
    for (s.env.map.keys(), s.env.map.values()) |k, v| try env.map.put(arena, k, v);
    const pairs = try arena.alloc([]const u8, env.map.count());
    for (env.map.keys(), env.map.values(), pairs) |k, v, *pair| pair.* = try std.fmt.allocPrint(arena, "{s}={s}", .{ k, v });

    const mounts = try arena.alloc(oci.BindMount, s.volumes.len);
    for (s.volumes, mounts) |v, *m| m.* = .{ .source = try mountSource(arena, envelope, v), .destination = v.destination };

    const r = s.resources;
    const quota: ?u64 = if (r.cpus) |cpus|
        (if (cpus > 0) @as(u64, @intFromFloat(cpus * 100_000)) else null)
    else if (r.cpu_quota) |q| quotaPercent(q) else null;

    return .{
        .socket = socket,
        .namespace = envelope.grove,
        .image = try image.normalize(arena, s.image orelse return error.NoImage),
        .container_id = id,
        .fifo_dir = try std.fs.path.join(arena, &.{ envelope.state_dir, "containerd", id }),
        .entrypoint = if (s.entrypoint) |e| try words(arena, e) else null,
        .cmd = if (s.cmd) |c| try words(arena, c) else null,
        .env = pairs,
        .cwd = s.workdir orelse "",
        .user = s.user orelse "",
        .mounts = mounts,
        .resources = .{
            .memory_bytes = if (r.memory) |m| memoryBytes(m) else null,
            .cpu_quota_us = quota,
            .cpu_period_us = if (quota != null) 100_000 else null,
            .pids_max = r.tasks_max orelse r.limit_nproc,
            .nofile = r.limit_nofile,
            .nproc = r.limit_nproc,
            .io_weight = r.io_weight,
        },
    };
}

pub fn removalSpec(arena: Allocator, envelope: Envelope, socket: []const u8) !RunSpec {
    const id = try containerId(arena, envelope);
    return .{
        .socket = socket,
        .namespace = envelope.grove,
        .image = envelope.service.image orelse "",
        .container_id = id,
        .fifo_dir = try std.fs.path.join(arena, &.{ envelope.state_dir, "containerd", id }),
    };
}

pub const Quoted = struct {
    text: []const u8,

    pub fn format(q: Quoted, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeByte('\'');
        for (q.text) |ch| if (ch == '\'') try w.writeAll("'\\''") else try w.writeByte(ch);
        try w.writeByte('\'');
    }
};

pub fn execSet(arena: Allocator, envelope: Envelope, self: []const u8, socket: []const u8, no_pivot_root: bool, from_files: Env) !ExecSet {
    const s = envelope.service;
    if (s.mode == .host) return .{
        .start = s.run_command orelse return error.NoRunCommand,
        .stop = s.stop_command,
        .reload = s.reload_command,
    };
    var run_spec = try runSpec(arena, envelope, socket, from_files);
    run_spec.no_pivot_root = no_pivot_root;
    run_spec.recreate = s.recreate;
    run_spec.definition = try definitionOf(arena, run_spec);
    const spec = try std.json.Stringify.valueAlloc(arena, run_spec, .{ .emit_null_optional_fields = false });
    const encoded = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(spec.len));
    _ = std.base64.standard.Encoder.encode(encoded, spec);
    return .{ .start = try std.fmt.allocPrint(arena, "{f} run --spec-base64 {s}", .{ Quoted{ .text = self }, encoded }) };
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
        else => try w.print("service '{s}': {t}\n", .{ service.name, refusal }),
    }
}

fn testEnvelope(s: Service) Envelope {
    return .{ .contract = 1, .grove = "hum", .project_dir = "/proj", .data_dir = "/data/hum", .state_dir = "/state", .service = s };
}

test "a container becomes one foreground run carrying its whole spec" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Service = .{ .name = "web", .mode = .container, .image = "nginx:alpine", .cmd = "nginx -g 'daemon off;'", .user = "101", .workdir = "/srv" };
    try s.env.map.put(a, "MODE", "env");
    s.volumes = &.{ .{ .source = "site", .destination = "/usr/share/nginx/html", .is_named = true }, .{ .source = "./conf", .destination = "/etc/nginx/conf.d" } };
    s.resources = .{ .memory = "256M", .cpus = 1.5, .limit_nofile = 4096, .tasks_max = 64 };
    var files: Env = .{};
    try files.map.put(a, "MODE", "file");
    try files.map.put(a, "FROM_FILE", "yes");

    const set = try execSet(a, testEnvelope(s), "/usr/local/bin/orchd-rootstock-containerd", default_socket, false, files);
    try testing.expectEqual(null, set.stop);
    const prefix = "'/usr/local/bin/orchd-rootstock-containerd' run --spec-base64 ";
    try testing.expect(std.mem.startsWith(u8, set.start, prefix));

    const spec = try decodeRunSpec(a, set.start[prefix.len..]);
    try testing.expectEqualStrings("hum", spec.namespace);
    try testing.expectEqualStrings("hum-web", spec.container_id);
    try testing.expectEqualStrings("docker.io/library/nginx:alpine", spec.image);
    try testing.expectEqualStrings("/state/containerd/hum-web", spec.fifo_dir);
    try testing.expectEqual(null, spec.entrypoint);
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "nginx", "-g", "daemon off;" }), spec.cmd.?);
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "MODE=env", "FROM_FILE=yes" }), spec.env);
    try testing.expectEqualStrings("/data/hum/web/volumes/site", spec.mounts[0].source);
    try testing.expectEqualStrings("/proj/./conf", spec.mounts[1].source);
    try testing.expectEqual(256 << 20, spec.resources.memory_bytes.?);
    try testing.expectEqual(150_000, spec.resources.cpu_quota_us.?);
    try testing.expectEqual(64, spec.resources.pids_max.?);
}

test "a host service runs as it would bare, and what cannot run is refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const set = try execSet(a, testEnvelope(.{ .name = "web", .mode = .host, .run_command = "python app.py", .reload_command = "kill -HUP $MAINPID" }), "/x", default_socket, false, .{});
    try testing.expectEqualStrings("python app.py", set.start);
    try testing.expectEqualStrings("kill -HUP $MAINPID", set.reload.?);
    try testing.expectError(error.NoRunCommand, execSet(a, testEnvelope(.{ .name = "web", .mode = .host }), "/x", default_socket, false, .{}));
    try testing.expectError(error.NoImage, execSet(a, testEnvelope(.{ .name = "db", .mode = .container }), "/x", default_socket, false, .{}));
    try testing.expectError(error.UnterminatedQuote, execSet(a, testEnvelope(.{ .name = "db", .mode = .container, .image = "x", .cmd = "sh -c 'half" }), "/x", default_socket, false, .{}));
}

test "cpu quota comes from CPUS, else CPU_QUOTA as a percentage" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spec = try runSpec(a, testEnvelope(.{ .name = "x", .mode = .container, .image = "x", .resources = .{ .cpu_quota = "50%" } }), default_socket, .{});
    try testing.expectEqual(50_000, spec.resources.cpu_quota_us.?);
    const none = try runSpec(a, testEnvelope(.{ .name = "x", .mode = .container, .image = "x" }), default_socket, .{});
    try testing.expectEqual(null, none.resources.cpu_quota_us);
    try testing.expectEqual(null, none.resources.cpu_period_us);
}

test "the definition names everything that shapes the container, and nothing else" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base: Service = .{ .name = "db", .mode = .container, .image = "postgres:16", .cmd = "postgres" };
    const one = try execSet(a, testEnvelope(base), "/x", default_socket, false, .{});
    const again = try execSet(a, testEnvelope(base), "/x", default_socket, false, .{});
    const prefix = "'/x' run --spec-base64 ";
    const first = try decodeRunSpec(a, one.start[prefix.len..]);
    try testing.expectEqual(64, first.definition.len);
    try testing.expectEqualStrings(first.definition, (try decodeRunSpec(a, again.start[prefix.len..])).definition);
    try testing.expectEqual(.never, first.recreate);

    var always = base;
    always.recreate = .always;
    const same_shape = try decodeRunSpec(a, (try execSet(a, testEnvelope(always), "/x", default_socket, false, .{})).start[prefix.len..]);
    try testing.expectEqualStrings(first.definition, same_shape.definition);
    try testing.expectEqual(.always, same_shape.recreate);

    var other_image = base;
    other_image.image = "postgres:17";
    const changed = try decodeRunSpec(a, (try execSet(a, testEnvelope(other_image), "/x", default_socket, false, .{})).start[prefix.len..]);
    try testing.expect(!std.mem.eql(u8, first.definition, changed.definition));

    var env = base;
    try env.env.map.put(a, "MODE", "x");
    const env_changed = try decodeRunSpec(a, (try execSet(a, testEnvelope(env), "/x", default_socket, false, .{})).start[prefix.len..]);
    try testing.expect(!std.mem.eql(u8, first.definition, env_changed.definition));
}
