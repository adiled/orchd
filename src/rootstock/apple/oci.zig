//! Image -> OCI config resolution, walked entirely over XPC contentGet.
//!
//!   imageList            -> find the image's index digest
//!   contentGet(index)    -> pick the linux/arm64 manifest digest
//!   contentGet(manifest) -> the config blob digest
//!   contentGet(config)   -> OCI config: Entrypoint / Cmd / Env / WorkingDir / User
//!
//! The result feeds ContainerConfiguration.initProcess for create.

const std = @import("std");
const client = @import("client.zig");
const contract = @import("contract");
const prepare = @import("prepare.zig");

extern "c" fn close(fd: c_int) c_int;

pub const Resolved = struct {
    /// Image descriptor digest (for ContainerConfiguration.image).
    image_digest: []const u8,
    image_size: i64,
    image_media_type: []const u8,
    /// initProcess fields, from the OCI config.
    executable: []const u8,
    arguments: []const []const u8,
    environment: []const []const u8,
    working_directory: []const u8,
    /// The image's raw Entrypoint/Cmd, kept separate so Docker-style overrides
    /// can be applied (executable/arguments above are the merged default).
    image_entrypoint: []const []const u8,
    image_cmd: []const []const u8,
};

fn find(v: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn str(v: ?std.json.Value) []const u8 {
    return if (v) |x| switch (x) {
        .string => |s| s,
        else => "",
    } else "";
}

/// Resolve `reference` to its descriptor + initProcess fields. Allocations come
/// from `arena` (caller owns; free the whole arena).
pub fn resolve(arena: std.mem.Allocator, io: std.Io, reference: []const u8) !Resolved {
    // 1. imageList -> descriptor for `reference`
    const images_json = try client.imageList(arena);
    const images = try std.json.parseFromSliceLeaky(std.json.Value, arena, images_json, .{});
    const wanted = try contract.normalizeImage(arena, reference);
    var index_digest: []const u8 = "";
    var img_size: i64 = 0;
    var img_media: []const u8 = "";
    for (images.array.items) |img| {
        const stored = str(find(img, "reference"));
        if (std.mem.eql(u8, stored, reference) or std.mem.eql(u8, stored, wanted)) {
            const desc = find(img, "descriptor").?;
            index_digest = str(find(desc, "digest"));
            img_media = str(find(desc, "mediaType"));
            img_size = switch (find(desc, "size").?) {
                .integer => |n| n,
                else => 0,
            };
        }
    }
    if (index_digest.len == 0) return error.ImageNotFound;

    // 2. contentGet(index) -> linux/arm64 manifest digest
    const index_blob = try client.contentGet(arena, io, index_digest);
    const index = try std.json.parseFromSliceLeaky(std.json.Value, arena, index_blob, .{});
    var manifest_digest: []const u8 = "";
    for (find(index, "manifests").?.array.items) |m| {
        const plat = find(m, "platform") orelse continue;
        if (std.mem.eql(u8, str(find(plat, "os")), "linux") and
            std.mem.eql(u8, str(find(plat, "architecture")), "arm64"))
        {
            manifest_digest = str(find(m, "digest"));
        }
    }
    if (manifest_digest.len == 0) return error.NoArm64Manifest;

    // 3. contentGet(manifest) -> config blob digest
    const manifest_blob = try client.contentGet(arena, io, manifest_digest);
    const manifest = try std.json.parseFromSliceLeaky(std.json.Value, arena, manifest_blob, .{});
    const config_digest = str(find(find(manifest, "config") orelse return error.NoConfig, "digest"));

    // 4. contentGet(config) -> OCI config (Entrypoint/Cmd/Env/WorkingDir)
    const config_blob = try client.contentGet(arena, io, config_digest);
    const oci = try std.json.parseFromSliceLeaky(std.json.Value, arena, config_blob, .{});
    const cfg = find(oci, "config") orelse return error.NoOciConfig;

    var entrypoint = std.ArrayList([]const u8).empty;
    if (find(cfg, "Entrypoint")) |ep| if (ep == .array) for (ep.array.items) |a| try entrypoint.append(arena, str(a));

    var cmd = std.ArrayList([]const u8).empty;
    if (find(cfg, "Cmd")) |c| if (c == .array) for (c.array.items) |a| try cmd.append(arena, str(a));

    // Merged default argv (entrypoint then cmd), as the image would run it.
    var argv = std.ArrayList([]const u8).empty;
    try argv.appendSlice(arena, entrypoint.items);
    try argv.appendSlice(arena, cmd.items);
    if (argv.items.len == 0) return error.NoEntrypoint;

    var env = std.ArrayList([]const u8).empty;
    if (find(cfg, "Env")) |e| if (e == .array) for (e.array.items) |a| try env.append(arena, str(a));

    const wd = str(find(cfg, "WorkingDir"));

    return .{
        .image_digest = index_digest,
        .image_size = img_size,
        .image_media_type = img_media,
        .executable = argv.items[0],
        .arguments = argv.items[1..],
        .environment = env.items,
        .working_directory = if (wd.len == 0) "/" else wd,
        .image_entrypoint = entrypoint.items,
        .image_cmd = cmd.items,
    };
}

// ─── Spec overrides ─────────────────────────────────────────────────────────

const DEFAULT_CPUS: i64 = 2;
const DEFAULT_MEMORY: u64 = 1024 * 1024 * 1024;

/// Parse a memory string into bytes. Suffixes K/M/G are 1024-based; a bare
/// number is already bytes. Empty/unset yields the default 1 GiB.
pub fn parseMemory(s: []const u8) !u64 {
    if (s.len == 0) return DEFAULT_MEMORY;
    var end = s.len;
    var mult: u64 = 1;
    switch (s[s.len - 1]) {
        'K', 'k' => {
            mult = 1024;
            end -= 1;
        },
        'M', 'm' => {
            mult = 1024 * 1024;
            end -= 1;
        },
        'G', 'g' => {
            mult = 1024 * 1024 * 1024;
            end -= 1;
        },
        else => {},
    }
    const n = try std.fmt.parseInt(u64, s[0..end], 10);
    return n * mult;
}

fn splitArgs(arena: std.mem.Allocator, s: []const u8) ![]const []const u8 {
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
            else => |c| {
                in_word = true;
                try word.append(arena, c);
            },
        }
    }
    if (in_word) try out.append(arena, try word.toOwnedSlice(arena));
    return out.items;
}

/// Build the merged environment: image env first, then service env (KEY=VALUE),
/// then each env_files path's KEY=VALUE lines. Later entries win at runtime, so
/// service config overrides image defaults.
fn mergeEnv(arena: std.mem.Allocator, io: std.Io, image_env: []const []const u8, svc: contract.Service) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    try out.appendSlice(arena, image_env);

    // Service env: a JSON object of KEY -> VALUE.
    for (svc.env.map.keys(), svc.env.map.values()) |key, value| {
        try out.append(arena, try std.fmt.allocPrint(arena, "{s}={s}", .{ key, value }));
    }

    // env_files: append each non-empty, non-comment KEY=VALUE line verbatim.
    for (svc.env_files) |path| {
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch continue;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (std.mem.indexOfScalar(u8, line, '=') == null) continue;
            try out.append(arena, try arena.dupe(u8, line));
        }
    }

    return out.items;
}

// ─── ContainerConfiguration (mirrors the daemon's snapshot shape) ───────────

const Empty = struct {};
const Resources = struct { cpus: i64, memoryInBytes: u64 };
const Dns = struct {
    nameservers: []const []const u8 = &.{},
    searchDomains: []const []const u8 = &.{},
    options: []const []const u8 = &.{},
};
const Descriptor = struct { digest: []const u8, size: i64, mediaType: []const u8 };
const Image = struct { descriptor: Descriptor, reference: []const u8 };
const UserId = struct { uid: u32 = 0, gid: u32 = 0 };
const User = struct { id: UserId = .{} };
const Platform = struct { os: []const u8 = "linux", architecture: []const u8 = "arm64" };
const InitProcess = struct {
    executable: []const u8,
    arguments: []const []const u8,
    environment: []const []const u8,
    workingDirectory: []const u8,
    user: User = .{},
    terminal: bool = false,
    rlimits: []const Empty = &.{},
    supplementalGroups: []const u32 = &.{},
};
const Network = struct {
    network: []const u8 = "default",
    options: AttachmentOptions,
};
const AttachmentOptions = struct { hostname: []const u8 };
const PublishedPort = struct {
    hostAddress: []const u8,
    hostPort: u16,
    containerPort: u16,
    proto: []const u8 = "tcp",
    count: u32 = 1,
};
const VolumeType = struct {
    name: []const u8,
    format: []const u8 = "ext4",
    cache: struct { on: Empty = .{} } = .{},
    sync: struct { fsync: Empty = .{} } = .{},
};
const MountType = union(enum) { virtiofs: Empty, volume: VolumeType };
const Mount = struct {
    type: MountType,
    source: []const u8,
    destination: []const u8,
    options: []const []const u8 = &.{},
};

pub fn publishedPorts(arena: std.mem.Allocator, publish: []const contract.PortMapping) ![]const PublishedPort {
    const ports = try arena.alloc(PublishedPort, publish.len);
    for (publish, ports) |p, *port| port.* = .{ .hostAddress = p.address orelse "0.0.0.0", .hostPort = p.host, .containerPort = p.container };
    return ports;
}

pub fn mountFor(volume: contract.VolumeMount, source: []const u8) Mount {
    if (volume.is_named) return .{ .type = .{ .volume = .{ .name = volume.source } }, .source = source, .destination = volume.destination };
    return .{ .type = .{ .virtiofs = .{} }, .source = source, .destination = volume.destination };
}

fn mountsFor(arena: std.mem.Allocator, io: std.Io, volumes: []const contract.VolumeMount) ![]const Mount {
    const mounts = try arena.alloc(Mount, volumes.len);
    for (volumes, mounts) |v, *m| m.* = mountFor(v, if (v.is_named) try prepare.volume(arena, io, v.source) else v.source);
    return mounts;
}

const Config = struct {
    id: []const u8,
    image: Image,
    initProcess: InitProcess,
    resources: Resources,
    platform: Platform = .{},
    dns: Dns = .{},
    mounts: []const Mount = &.{},
    publishedPorts: []const PublishedPort = &.{},
    publishedSockets: []const Empty = &.{},
    networks: []const Network,
    labels: std.json.ArrayHashMap([]const u8) = .{},
    sysctls: Empty = .{},
    runtimeHandler: []const u8 = "container-runtime-linux",
    virtualization: bool = false,
    rosetta: bool = false,
    readOnly: bool = false,
    ssh: bool = false,
    useInit: bool = false,
    capAdd: []const []const u8 = &.{},
    capDrop: []const []const u8 = &.{},
};

const INIT_IMAGE = "ghcr.io/apple/containerization/vminit:0.31.0";
const vminit = "ghcr.io/apple/containerization/vminit:";

fn initImage(arena: std.mem.Allocator) ![:0]const u8 {
    const images_json = client.imageList(arena) catch return INIT_IMAGE;
    const images = std.json.parseFromSliceLeaky(std.json.Value, arena, images_json, .{}) catch return INIT_IMAGE;
    if (images != .array) return INIT_IMAGE;
    var refs: std.ArrayList([]const u8) = .empty;
    for (images.array.items) |img| try refs.append(arena, str(find(img, "reference")));
    return newestVminit(arena, refs.items) orelse INIT_IMAGE;
}

fn newestVminit(arena: std.mem.Allocator, refs: []const []const u8) ?[:0]const u8 {
    var best: ?[]const u8 = null;
    var best_version: std.SemanticVersion = undefined;
    for (refs) |ref| {
        if (!std.mem.startsWith(u8, ref, vminit)) continue;
        const version = std.SemanticVersion.parse(ref[vminit.len..]) catch continue;
        if (best == null or version.order(best_version) == .gt) {
            best = ref;
            best_version = version;
        }
    }
    return arena.dupeSentinel(u8, best orelse return null, 0) catch null;
}

test "the init image is the newest vminit the daemon already holds" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(vminit ++ "0.35.0", newestVminit(a, &.{ "docker.io/library/alpine:3.20", vminit ++ "0.31.0", vminit ++ "0.35.0", vminit ++ "0.9.0" }).?);
    try std.testing.expectEqual(null, newestVminit(a, &.{"docker.io/library/alpine:3.20"}));
}

/// Create and start a container entirely over XPC: resolve OCI -> kernel ->
/// build ContainerConfiguration -> create -> bootstrap -> start.
///
/// When `overrides` is non-null, the service spec is applied on top of the
/// image defaults: env merge (image then service then env_files), resources
/// (cpus/memory), workingDirectory, and Docker-style entrypoint/cmd. When null,
/// behaviour is identical to before (image defaults, cpus=2, 1 GiB).
pub fn run(
    arena: std.mem.Allocator,
    allocator: std.mem.Allocator,
    io: std.Io,
    id: []const u8,
    reference: []const u8,
    overrides: ?contract.Service,
    definition: []const u8,
    keep: bool,
) !void {
    const c = client.Client.init();
    defer c.deinit();

    if (try existingDefinition(arena, c, id)) |found| {
        if (keep and definition.len > 0 and std.mem.eql(u8, found, definition)) {
            std.debug.print("woke {s}, kept from its last run\n", .{id});
            return bootAndStart(allocator, c, id);
        }
        c.containerDelete(allocator, id, true) catch {};
    }

    const r = try resolve(arena, io, reference);

    const kernel_json = try c.getDefaultKernel(arena, "{\"os\":\"linux\",\"architecture\":\"arm64\"}");

    // Start from the image defaults, then layer the service spec on top.
    var executable = r.executable;
    var arguments = r.arguments;
    var environment = r.environment;
    var working_directory = r.working_directory;
    var cpus: i64 = DEFAULT_CPUS;
    var memory_bytes: u64 = DEFAULT_MEMORY;

    if (overrides) |svc| {
        // env: image env first, then service env, then env_files (service wins).
        environment = try mergeEnv(arena, io, r.environment, svc);

        // resources: round cpus to int; parse memory suffix.
        if (svc.resources.cpus) |n| cpus = @intFromFloat(@round(n));
        if (svc.resources.memory) |m| memory_bytes = try parseMemory(m);

        // workingDirectory: service.workdir overrides the image WorkingDir.
        if (svc.workdir) |wd| if (wd.len != 0) {
            working_directory = wd;
        };

        // entrypoint/cmd: Docker semantics.
        if (svc.entrypoint) |ep| {
            // entrypoint set -> executable = entrypoint, args = cmd (or empty).
            const ep_argv = try splitArgs(arena, ep);
            if (ep_argv.len == 0) return error.NoEntrypoint;
            executable = ep_argv[0];
            var args = std.ArrayList([]const u8).empty;
            try args.appendSlice(arena, ep_argv[1..]);
            if (svc.cmd) |cmd| try args.appendSlice(arena, try splitArgs(arena, cmd));
            arguments = args.items;
        } else if (svc.cmd) |cmd| {
            // only cmd set -> keep image entrypoint, replace args with cmd.
            const cmd_argv = try splitArgs(arena, cmd);
            if (r.image_entrypoint.len == 0) {
                // No image entrypoint: cmd is the full argv.
                if (cmd_argv.len == 0) return error.NoEntrypoint;
                executable = cmd_argv[0];
                arguments = cmd_argv[1..];
            } else {
                executable = r.image_entrypoint[0];
                var args = std.ArrayList([]const u8).empty;
                try args.appendSlice(arena, r.image_entrypoint[1..]);
                try args.appendSlice(arena, cmd_argv);
                arguments = args.items;
            }
        }
        // neither set -> keep image defaults (executable/arguments unchanged).
    }

    const ports: []const PublishedPort = if (overrides) |svc| try publishedPorts(arena, svc.publish) else &.{};
    const mounts: []const Mount = if (overrides) |svc| try mountsFor(arena, io, svc.volumes) else &.{};

    const cfg = Config{
        .id = id,
        .image = .{
            .descriptor = .{ .digest = r.image_digest, .size = r.image_size, .mediaType = r.image_media_type },
            .reference = try contract.normalizeImage(arena, reference),
        },
        .initProcess = .{
            .executable = executable,
            .arguments = arguments,
            .environment = environment,
            .workingDirectory = working_directory,
        },
        .resources = .{ .cpus = cpus, .memoryInBytes = memory_bytes },
        .mounts = mounts,
        .publishedPorts = ports,
        .networks = &.{.{ .options = .{ .hostname = id } }},
        .labels = try labelsFor(arena, definition),
    };
    const config_json = try std.json.Stringify.valueAlloc(arena, cfg, .{});

    const options_json = "{\"autoRemove\":false,\"rootFsOverride\":null}";

    try c.containerCreate(allocator, config_json, kernel_json, options_json, try initImage(arena));
    try bootAndStart(allocator, c, id);
}

fn bootAndStart(allocator: std.mem.Allocator, c: client.Client, id: []const u8) !void {
    const fd = try std.posix.openatZ(std.posix.AT.FDCWD, "/dev/null", .{ .ACCMODE = .RDWR }, 0);
    defer _ = close(fd);
    try c.containerBootstrap(allocator, id, fd);
    try c.containerStartProcess(allocator, id);
}

fn labelsFor(arena: std.mem.Allocator, definition: []const u8) !std.json.ArrayHashMap([]const u8) {
    var labels: std.json.ArrayHashMap([]const u8) = .{};
    if (definition.len > 0) try labels.map.put(arena, "orchd.definition", definition);
    return labels;
}

fn existingDefinition(arena: std.mem.Allocator, c: client.Client, id: []const u8) !?[]const u8 {
    const json = c.containerList(arena) catch return null;
    return definitionIn(arena, json, id);
}

pub fn definitionIn(arena: std.mem.Allocator, list_json: []const u8, id: []const u8) !?[]const u8 {
    const list = std.json.parseFromSliceLeaky(std.json.Value, arena, list_json, .{}) catch return null;
    if (list != .array) return null;
    for (list.array.items) |item| {
        const config = find(item, "configuration") orelse continue;
        if (!std.mem.eql(u8, str(find(config, "id")), id)) continue;
        return str(if (find(config, "labels")) |l| find(l, "orchd.definition") else null);
    }
    return null;
}

test "an existing container is found by id with its definition, or not at all" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list =
        \\[{"configuration":{"id":"other","labels":{}},"status":"stopped"},
        \\ {"configuration":{"id":"orch-db","labels":{"orchd.definition":"abc"}},"status":"stopped"},
        \\ {"configuration":{"id":"orch-bare","labels":{}},"status":"running"}]
    ;
    try std.testing.expectEqualStrings("abc", (try definitionIn(a, list, "orch-db")).?);
    try std.testing.expectEqualStrings("", (try definitionIn(a, list, "orch-bare")).?);
    try std.testing.expectEqual(null, try definitionIn(a, list, "orch-gone"));
    try std.testing.expectEqual(null, try definitionIn(a, "not json", "orch-db"));
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "parseMemory understands suffixes and bare bytes" {
    try std.testing.expectEqual(@as(u64, 536870912), try parseMemory("512M"));
    try std.testing.expectEqual(@as(u64, 1073741824), try parseMemory("1G"));
    try std.testing.expectEqual(@as(u64, 2048), try parseMemory("2048"));
    try std.testing.expectEqual(@as(u64, 1024), try parseMemory("1K"));
    try std.testing.expectEqual(DEFAULT_MEMORY, try parseMemory(""));
}

test "mergeEnv puts service env after image env" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var env: contract.Env = .{};
    try env.map.put(arena, "FOO", "service");
    const svc = contract.Service{
        .name = "x",
        .mode = .container,
        .env = env,
    };
    const image_env: []const []const u8 = &.{ "FOO=image", "PATH=/usr/bin" };
    const merged = try mergeEnv(arena, io, image_env, svc);

    // Image entries come first; service FOO appended after, so it wins.
    try std.testing.expectEqualStrings("FOO=image", merged[0]);
    try std.testing.expectEqualStrings("PATH=/usr/bin", merged[1]);
    try std.testing.expectEqualStrings("FOO=service", merged[merged.len - 1]);
}

test "splitArgs tokenizes on spaces" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const argv = try splitArgs(arena, "postgres -c max_connections=200");
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("postgres", argv[0]);
    try std.testing.expectEqualStrings("max_connections=200", argv[2]);
}

test "splitArgs reads quotes like a shell" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const argv = try splitArgs(arena, "sh -c \"echo hello from $GREETING; sleep 600\" 'a b' c\\ d");
    try std.testing.expectEqual(@as(usize, 5), argv.len);
    try std.testing.expectEqualStrings("echo hello from $GREETING; sleep 600", argv[2]);
    try std.testing.expectEqualStrings("a b", argv[3]);
    try std.testing.expectEqualStrings("c d", argv[4]);
    try std.testing.expectError(error.UnterminatedQuote, splitArgs(arena, "sh -c 'half"));
}

test "ports and mounts take the shapes the daemon stores" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ports = try publishedPorts(a, &.{ .{ .address = "127.0.0.1", .host = 18080, .container = 80 }, .{ .host = 5433, .container = 5432 } });
    try std.testing.expectEqualStrings(
        \\[{"hostAddress":"127.0.0.1","hostPort":18080,"containerPort":80,"proto":"tcp","count":1},{"hostAddress":"0.0.0.0","hostPort":5433,"containerPort":5432,"proto":"tcp","count":1}]
    , try std.json.Stringify.valueAlloc(a, ports, .{}));
    const mounts = [_]Mount{
        mountFor(.{ .source = "/proj/site", .destination = "/srv" }, "/proj/site"),
        mountFor(.{ .source = "pgdata", .destination = "/data", .is_named = true }, "/v/pgdata/volume.img"),
    };
    try std.testing.expectEqualStrings(
        \\[{"type":{"virtiofs":{}},"source":"/proj/site","destination":"/srv","options":[]},{"type":{"volume":{"name":"pgdata","format":"ext4","cache":{"on":{}},"sync":{"fsync":{}}}},"source":"/v/pgdata/volume.img","destination":"/data","options":[]}]
    , try std.json.Stringify.valueAlloc(a, mounts, .{}));
}
