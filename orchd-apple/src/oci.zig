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
const types = @import("types.zig");

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
    var index_digest: []const u8 = "";
    var img_size: i64 = 0;
    var img_media: []const u8 = "";
    for (images.array.items) |img| {
        if (std.mem.eql(u8, str(find(img, "reference")), reference)) {
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

/// Split a command string on ASCII spaces into argv, dropping empty fields.
/// Allocations come from `arena`.
fn splitArgs(arena: std.mem.Allocator, s: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var it = std.mem.tokenizeScalar(u8, s, ' ');
    while (it.next()) |tok| try out.append(arena, tok);
    return out.items;
}

/// Build the merged environment: image env first, then service env (KEY=VALUE),
/// then each env_files path's KEY=VALUE lines. Later entries win at runtime, so
/// service config overrides image defaults.
fn mergeEnv(arena: std.mem.Allocator, io: std.Io, image_env: []const []const u8, svc: types.Service) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    try out.appendSlice(arena, image_env);

    // Service env: a JSON object of KEY -> VALUE.
    if (svc.env == .object) {
        var it = svc.env.object.iterator();
        while (it.next()) |kv| {
            const val = switch (kv.value_ptr.*) {
                .string => |v| v,
                else => "",
            };
            const line = try std.fmt.allocPrint(arena, "{s}={s}", .{ kv.key_ptr.*, val });
            try out.append(arena, line);
        }
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
const Config = struct {
    id: []const u8,
    image: Image,
    initProcess: InitProcess,
    resources: Resources,
    platform: Platform = .{},
    dns: Dns = .{},
    mounts: []const Empty = &.{},
    publishedPorts: []const Empty = &.{},
    publishedSockets: []const Empty = &.{},
    networks: []const Network,
    labels: Empty = .{},
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
    overrides: ?types.Service,
) !void {
    const r = try resolve(arena, io, reference);

    const c = client.Client.init();
    defer c.deinit();

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

    // TODO: publish ports and volumes are deliberately skipped here. The
    // daemon's PublishPort/Filesystem encodings at 0.12.3 are unverified, and
    // Apple gives each container a dedicated IP, so port mapping is not needed
    // for reachability. Wire these once the 0.12.3 shapes are confirmed.

    const cfg = Config{
        .id = id,
        .image = .{
            .descriptor = .{ .digest = r.image_digest, .size = r.image_size, .mediaType = r.image_media_type },
            .reference = reference,
        },
        .initProcess = .{
            .executable = executable,
            .arguments = arguments,
            .environment = environment,
            .workingDirectory = working_directory,
        },
        .resources = .{ .cpus = cpus, .memoryInBytes = memory_bytes },
        .networks = &.{.{ .options = .{ .hostname = id } }},
    };
    const config_json = try std.json.Stringify.valueAlloc(arena, cfg, .{});

    const options_json = "{\"autoRemove\":false,\"rootFsOverride\":null}";

    try c.containerCreate(allocator, config_json, kernel_json, options_json, INIT_IMAGE);

    const fd = try std.posix.openatZ(std.posix.AT.FDCWD, "/dev/null", .{ .ACCMODE = .RDWR }, 0);
    defer _ = close(fd);

    try c.containerBootstrap(allocator, id, fd);
    try c.containerStartProcess(allocator, id);
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

    var env_map: std.json.ObjectMap = .empty;
    try env_map.put(arena, "FOO", .{ .string = "service" });
    const svc = types.Service{
        .name = "x",
        .mode = "container",
        .env = .{ .object = env_map },
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
