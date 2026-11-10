//! ExecSet generation: translates a Service into `orchd-rootstock-apple` XPC subcommands.
//!
//! Naming:  <grove>-<service.name>  e.g. "orch-postgres"
//!
//! Each stage re-invokes this very binary, which talks to the pinned apple
//! container daemon over XPC (no `container` CLI anywhere):
//!   pre_start  — `orchd-rootstock-apple pull <image>`
//!   start      — `orchd-rootstock-apple run <name> <image> --spec <b64> && orchd-rootstock-apple wait <name>`
//!                (wait blocks while the container lives, so launchd tracks it)
//!   stop       — `orchd-rootstock-apple stop <name>`
//!   post_stop  — `orchd-rootstock-apple delete <name>` (clean slate on restart)
//!
//! The full Service config (env, env_files, memory, cpus, workdir, entrypoint,
//! cmd) is carried into `run` as a base64-encoded JSON blob via `--spec`. The
//! ExecSet is driven by a supervisor with no stdin, so the config has to be
//! baked into the command itself. base64 (standard alphabet) is shell-safe, so
//! env values containing spaces or quotes pass through cleanly.

const std = @import("std");
const contract = @import("contract");

pub const Error = error{
    MissingImage,
    OutOfMemory,
    WriteFailed,
};

pub fn build(
    allocator: std.mem.Allocator,
    io: std.Io,
    svc: contract.Service,
    grove: []const u8,
    definition: []const u8,
    keep: bool,
) Error!contract.ExecSet {
    if (svc.image == null) return Error.MissingImage;
    const image = svc.image.?;

    const name = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ grove, svc.name });
    defer allocator.free(name);

    // The ExecSet invokes this very binary's XPC-backed subcommands, so the
    // launchd supervisor drives the apple container entirely over XPC (no
    // `container` CLI). `run` returns once started; `wait` blocks while alive.
    const self = std.process.executablePathAlloc(io, allocator) catch return Error.OutOfMemory;
    defer allocator.free(self);

    const pre_start = try std.fmt.allocPrint(allocator, "{s} pull {s}", .{ self, image });

    // Carry the full service config into `run` as a shell-safe base64 blob.
    const spec_b64 = try encodeSpec(allocator, svc);
    defer allocator.free(spec_b64);

    const start = try std.fmt.allocPrint(
        allocator,
        "{s} run {s} {s} --spec {s} --definition {s}{s} && {s} wait {s}",
        .{ self, name, image, spec_b64, definition, if (keep) " --keep" else "", self, name },
    );
    const stop = try std.fmt.allocPrint(allocator, "{s} stop {s}", .{ self, name });
    const post_stop: ?[]const u8 = if (keep) null else try std.fmt.allocPrint(allocator, "{s} delete {s}", .{ self, name });

    return contract.ExecSet{
        .start = start,
        .pre_start = pre_start,
        .stop = stop,
        .post_stop = post_stop,
    };
}

// ─── Spec encoding ─────────────────────────────────────────────────────────

/// Serialize `svc` to JSON and base64-encode it (standard alphabet) so it can
/// be passed as a single shell-safe `--spec` argument. Caller frees the result.
pub fn encodeSpec(allocator: std.mem.Allocator, svc: contract.Service) Error![]u8 {
    const json = std.json.Stringify.valueAlloc(allocator, svc, .{}) catch return Error.OutOfMemory;
    defer allocator.free(json);

    const enc = std.base64.standard.Encoder;
    const out = allocator.alloc(u8, enc.calcSize(json.len)) catch return Error.OutOfMemory;
    _ = enc.encode(out, json);
    return out;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "minimal container service drives orchd-rootstock-apple over xpc" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();
    const svc = contract.Service{ .name = "postgres", .mode = .container, .image = "postgres:15" };
    const es = try build(allocator, io, svc, "orch", "def", false);

    // pre_start pulls the image; start runs then waits (foreground for launchd).
    try std.testing.expect(std.mem.endsWith(u8, es.pre_start.?, " pull postgres:15"));
    try std.testing.expect(std.mem.indexOf(u8, es.start, " run orch-postgres postgres:15") != null);
    try std.testing.expect(std.mem.indexOf(u8, es.start, " wait orch-postgres") != null);
    try std.testing.expect(std.mem.indexOf(u8, es.start, "&&") != null);
    try std.testing.expect(std.mem.endsWith(u8, es.stop.?, " stop orch-postgres"));
    try std.testing.expect(std.mem.endsWith(u8, es.post_stop.?, " delete orch-postgres"));

    // Every stage invokes this very binary (no `container` CLI).
    try std.testing.expect(std.mem.indexOf(u8, es.start, "container ") == null);
}

test "grove prefixes the container name" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();
    const svc = contract.Service{ .name = "api", .mode = .container, .image = "myapp:latest" };
    const es = try build(allocator, io, svc, "myns", "def", false);
    try std.testing.expect(std.mem.indexOf(u8, es.start, " run myns-api myapp:latest") != null);
    try std.testing.expect(std.mem.endsWith(u8, es.stop.?, " stop myns-api"));
}

test "missing image is an error" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const svc = contract.Service{ .name = "broken", .mode = .container, .image = null };
    try std.testing.expectError(Error.MissingImage, build(std.testing.allocator, io, svc, "orch", "def", false));
}

test "start carries a --spec base64 blob" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();
    const svc = contract.Service{ .name = "pg", .mode = .container, .image = "postgres:15" };
    const es = try build(allocator, io, svc, "orch", "def", false);
    try std.testing.expect(std.mem.indexOf(u8, es.start, " --spec ") != null);
}

test "spec base64 round-trips back to the service" {
    const allocator = std.testing.allocator;
    var env: contract.Env = .{};
    defer env.deinit(allocator);
    try env.map.put(allocator, "POSTGRES_PASSWORD", "a secret with spaces");
    const svc = contract.Service{
        .name = "pg",
        .mode = .container,
        .image = "postgres:15",
        .workdir = "/var/lib/postgresql",
        .entrypoint = "docker-entrypoint.sh",
        .cmd = "postgres -c max_connections=200",
        .env = env,
        .env_files = &.{".env.local"},
        .resources = .{ .memory = "512M", .cpus = 4 },
    };

    const b64 = try encodeSpec(allocator, svc);
    defer allocator.free(b64);

    // Decode base64 -> JSON, then parse back to a Service.
    const dec = std.base64.standard.Decoder;
    const json = try allocator.alloc(u8, try dec.calcSizeForSlice(b64));
    defer allocator.free(json);
    try dec.decode(json, b64);

    const parsed = try std.json.parseFromSlice(contract.Service, allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const got = parsed.value;

    try std.testing.expectEqualStrings("pg", got.name);
    try std.testing.expectEqualStrings("postgres:15", got.image.?);
    try std.testing.expectEqualStrings("/var/lib/postgresql", got.workdir.?);
    try std.testing.expectEqualStrings("docker-entrypoint.sh", got.entrypoint.?);
    try std.testing.expectEqualStrings("postgres -c max_connections=200", got.cmd.?);
    try std.testing.expectEqualStrings("512M", got.resources.memory.?);
    try std.testing.expectEqual(@as(f64, 4), got.resources.cpus.?);
    try std.testing.expectEqual(@as(usize, 1), got.env_files.len);
    try std.testing.expectEqualStrings(".env.local", got.env_files[0]);
    try std.testing.expectEqualStrings(
        "a secret with spaces",
        got.env.map.get("POSTGRES_PASSWORD").?,
    );
}

test "a spec planted by the previous release still reads" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const got = try std.json.parseFromSliceLeaky(contract.Service, arena.allocator(),
        \\{"name":"pg","mode":"container","image":"postgres:16","run_command":null,"stop_command":null,"reload_command":null,
        \\ "entrypoint":null,"cmd":null,"publish":[],"volumes":[{"source":"pgdata","destination":"/data","is_named":true}],
        \\ "user":null,"workdir":null,"env":{"A":"1"},"env_files":[],"resources":{"memory":"1G","cpus":2,"limit_nofile":null},
        \\ "recreate":"never","oneshot":false}
    , .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    try std.testing.expectEqual(.container, got.mode);
    try std.testing.expectEqualStrings("1", got.env.map.get("A").?);
    try std.testing.expectEqualStrings("1G", got.resources.memory.?);
    try std.testing.expect(got.volumes[0].is_named);
}
