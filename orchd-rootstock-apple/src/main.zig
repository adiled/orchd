//! orchd-rootstock-apple: orchd's rootstock for Apple's container runtime.
//!
//! Contract 1 (orchd calls these, the envelope on stdin):
//!   contract | check | prepare | exec-set
//!
//! ORCHD_APPLE_MODE picks how containers run: `xpc` (default) drives Apple's
//! container daemon over XPC through this binary's own verbs; `cli` writes
//! `container` command lines. Host services run as they would bare.
//!
//! The XPC verbs the exec set calls back into:
//!   run <id> <image> [--spec <b64>] | wait <id> | stop <id> | delete <id> | pull <image>
//! and, for poking at the daemon: list | kernel | images | content <digest> | resolve <ref>

const std = @import("std");

const client_mod = @import("client.zig");
const exec_set_mod = @import("exec_set.zig");
const oci_mod = @import("oci.zig");
const prepare_mod = @import("prepare.zig");
const types = @import("types.zig");
const plugin = @import("plugin.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const positionals = argv[1..];
    if (positionals.len == 0 or std.mem.eql(u8, positionals[0], "-h") or std.mem.eql(u8, positionals[0], "--help")) {
        std.debug.print("usage: orchd-rootstock-apple contract | check | prepare | exec-set\n" ++
            "       orchd-rootstock-apple run <id> <image> [--spec <b64>] | wait <id> | stop <id> | delete <id> | pull <image>\n" ++
            "       orchd-rootstock-apple list | kernel | images | content <digest> | resolve <ref>\n", .{});
        std.process.exit(if (positionals.len == 0) 1 else 0);
    }

    const command = positionals[0];
    const slot = if (positionals.len >= 2) positionals[1] else "orch";

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const wanted = init.environ_map.get("ORCHD_APPLE_MODE") orelse "";

    if (std.mem.eql(u8, command, "contract")) {
        try writeOut(io, "1 2\n");
    } else if (std.mem.eql(u8, command, "check")) {
        switch (modeFrom(wanted)) {
            .cli => if (!quiet(io, &.{ "container", "ls" })) {
                std.debug.print("container CLI/daemon not reachable (run: container system start)\n", .{});
                std.process.exit(1);
            },
            .xpc => try cmdCheck(allocator),
        }
    } else if (std.mem.eql(u8, command, "prepare")) {
        try cmdPrepare(arena, io);
    } else if (std.mem.eql(u8, command, "exec-set")) {
        try cmdExecSet(arena, io, modeFrom(wanted));
    } else if (std.mem.eql(u8, command, "remove")) {
        try cmdRemove(arena, io, modeFrom(wanted));
    } else if (std.mem.eql(u8, command, "cli-start")) {
        cmdCliStart(arena, io, positionals);
    } else if (std.mem.eql(u8, command, "list")) {
        try cmdList(allocator, io);
    } else if (std.mem.eql(u8, command, "stop")) {
        try cmdStop(allocator, slot); // the slot carries the container id
    } else if (std.mem.eql(u8, command, "delete")) {
        try cmdDelete(allocator, slot);
    } else if (std.mem.eql(u8, command, "kernel")) {
        try cmdKernel(allocator, io);
    } else if (std.mem.eql(u8, command, "images")) {
        try cmdImages(allocator, io);
    } else if (std.mem.eql(u8, command, "content")) {
        try cmdContent(allocator, io, slot); // the slot carries the digest
    } else if (std.mem.eql(u8, command, "resolve")) {
        try cmdResolve(allocator, io, slot); // the slot carries the image ref
    } else if (std.mem.eql(u8, command, "run")) {
        try cmdRun(allocator, io, positionals);
    } else if (std.mem.eql(u8, command, "wait")) {
        try cmdWait(allocator, slot); // the slot carries the container id
    } else if (std.mem.eql(u8, command, "pull")) {
        try cmdPull(io, slot); // the slot carries the image ref
    } else {
        std.debug.print("error: unknown command '{s}'\n", .{command});
        std.process.exit(1);
    }
}

fn cmdCheck(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var version_buf: [128]u8 = undefined;
    const c = client_mod.Client.init();
    defer c.deinit();
    const version = c.ping(&version_buf) catch |err| {
        std.debug.print(
            "error: container-apiserver unreachable ({s})\n       Run: container system start\n",
            .{@errorName(err)},
        );
        std.process.exit(1);
    };
    std.debug.print("container-apiserver ok (version: {s})\n", .{version});
}

/// `list`: query container states via XPC and emit the daemon's structured JSON.
fn cmdList(allocator: std.mem.Allocator, io: std.Io) !void {
    const c = client_mod.Client.init();
    defer c.deinit();
    const json = c.containerList(allocator) catch |err| {
        std.debug.print("error: container list failed ({s})\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer allocator.free(json);

    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    try fw.interface.writeAll(json);
    try fw.interface.flush();
}

/// `stop <id>`: stop a container via XPC (SIGTERM, 5s grace).
fn cmdStop(allocator: std.mem.Allocator, id: []const u8) !void {
    const c = client_mod.Client.init();
    defer c.deinit();
    c.containerStop(allocator, id, 5) catch |err| {
        std.debug.print("error: stop {s} failed ({s})\n", .{ id, @errorName(err) });
        std.process.exit(1);
    };
}

/// `delete <id>`: force-delete a container via XPC.
fn cmdDelete(allocator: std.mem.Allocator, id: []const u8) !void {
    const c = client_mod.Client.init();
    defer c.deinit();
    c.containerDelete(allocator, id, true) catch |err| {
        std.debug.print("error: delete {s} failed ({s})\n", .{ id, @errorName(err) });
        std.process.exit(1);
    };
}

/// `kernel`: resolve the default kernel via XPC and emit its JSON.
fn cmdKernel(allocator: std.mem.Allocator, io: std.Io) !void {
    const c = client_mod.Client.init();
    defer c.deinit();
    // SystemPlatform for the Linux guest on Apple Silicon.
    const platform = "{\"os\":\"linux\",\"architecture\":\"arm64\"}";
    const json = c.getDefaultKernel(allocator, platform) catch |err| {
        std.debug.print("error: getDefaultKernel failed ({s})\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer allocator.free(json);
    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    try fw.interface.writeAll(json);
    try fw.interface.flush();
}

/// `images`: list images via the core-images XPC service.
fn cmdImages(allocator: std.mem.Allocator, io: std.Io) !void {
    const json = client_mod.imageList(allocator) catch |err| {
        std.debug.print("error: imageList failed ({s})\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer allocator.free(json);
    var buf: [8192]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    try fw.interface.writeAll(json);
    try fw.interface.flush();
}

/// `content <digest>`: fetch a content-store blob via XPC and emit it.
fn cmdContent(allocator: std.mem.Allocator, io: std.Io, digest: []const u8) !void {
    const data = client_mod.contentGet(allocator, io, digest) catch |err| {
        std.debug.print("error: contentGet failed ({s})\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer allocator.free(data);
    var buf: [8192]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    try fw.interface.writeAll(data);
    try fw.interface.flush();
}

/// `resolve <ref>`: walk the OCI config over XPC and print initProcess fields.
fn cmdResolve(allocator: std.mem.Allocator, io: std.Io, reference: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const r = oci_mod.resolve(arena, io, reference) catch |err| {
        std.debug.print("error: resolve failed ({s})\n", .{@errorName(err)});
        std.process.exit(1);
    };
    std.debug.print("image:       {s} ({s})\n", .{ r.image_digest, r.image_media_type });
    std.debug.print("executable:  {s}\n", .{r.executable});
    std.debug.print("arguments:   ", .{});
    for (r.arguments) |a| std.debug.print("{s} ", .{a});
    std.debug.print("\nworkingdir:  {s}\n", .{r.working_directory});
    std.debug.print("environment: {d} vars\n", .{r.environment.len});
}

/// `run <id> <image> [--spec <base64>]`: create and start a container entirely
/// over XPC. The optional `--spec` carries the full service config as a base64
/// JSON blob (env, env_files, memory, cpus, workdir, entrypoint, cmd); when
/// absent, behaviour matches the old hardcoded defaults so nothing regresses.
fn cmdRun(allocator: std.mem.Allocator, io: std.Io, positionals: []const []const u8) !void {
    if (positionals.len < 3) {
        std.debug.print("usage: orchd-rootstock-apple run <id> <image> [--spec <base64>]\n", .{});
        std.process.exit(1);
    }
    const id = positionals[1];
    const reference = positionals[2];

    var spec_b64: ?[]const u8 = null;
    var definition: []const u8 = "";
    var keep = false;
    var i: usize = 3;
    while (i < positionals.len) : (i += 1) {
        if (std.mem.eql(u8, positionals[i], "--keep")) {
            keep = true;
            continue;
        }
        const is_spec = std.mem.eql(u8, positionals[i], "--spec");
        const is_definition = std.mem.eql(u8, positionals[i], "--definition");
        if (!is_spec and !is_definition) continue;
        if (i + 1 >= positionals.len) {
            std.debug.print("usage: orchd-rootstock-apple run <id> <image> [--spec <base64>] [--definition <hash>] [--keep]\n", .{});
            std.process.exit(1);
        }
        if (is_spec) spec_b64 = positionals[i + 1] else definition = positionals[i + 1];
        i += 1;
    }

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Decode --spec (base64 -> JSON -> Service) into overrides, if present.
    var overrides: ?types.Service = null;
    var parsed: ?std.json.Parsed(types.Service) = null;
    defer if (parsed) |p| p.deinit();
    if (spec_b64) |b64| {
        const dec = std.base64.standard.Decoder;
        const json = arena.alloc(u8, dec.calcSizeForSlice(b64) catch {
            std.debug.print("error: --spec is not valid base64\n", .{});
            std.process.exit(1);
        }) catch return error.OutOfMemory;
        dec.decode(json, b64) catch {
            std.debug.print("error: --spec is not valid base64\n", .{});
            std.process.exit(1);
        };
        parsed = std.json.parseFromSlice(types.Service, allocator, json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| {
            std.debug.print("error: --spec JSON parse failed ({s})\n", .{@errorName(err)});
            std.process.exit(1);
        };
        overrides = parsed.?.value;
    }

    oci_mod.run(arena, allocator, io, id, reference, overrides, definition, keep) catch |err| {
        std.debug.print("error: run failed ({s})\n", .{@errorName(err)});
        std.process.exit(1);
    };
    std.debug.print("started {s} ({s}) via XPC\n", .{ id, reference });
}

/// `wait <id>`: block until the container exits, then exit with its code. This
/// is the long-running foreground process the supervisor tracks.
fn cmdWait(allocator: std.mem.Allocator, id: []const u8) !void {
    const c = client_mod.Client.init();
    defer c.deinit();
    const code = c.containerWait(allocator, id) catch |err| {
        std.debug.print("error: wait {s} failed ({s})\n", .{ id, @errorName(err) });
        std.process.exit(1);
    };
    std.process.exit(@intCast(code & 0xff));
}

/// `pull <image>`: ensure the image is in the content store. (Image fetch over
/// XPC is the one remaining CLI holdout; runs `container image pull`.)
fn cmdPull(io: std.Io, image: []const u8) !void {
    prepare_mod.pullImage(io, image) catch |err| {
        std.debug.print("error: pull {s} failed ({s})\n", .{ image, @errorName(err) });
        std.process.exit(1);
    };
}

fn modeFrom(wanted: []const u8) plugin.Mode {
    return switch (plugin.Mode.parse(wanted)) {
        .mode => |m| m,
        .unknown => blk: {
            std.debug.print("warning: unknown ORCHD_APPLE_MODE '{s}', using 'xpc'\n", .{wanted});
            break :blk .xpc;
        },
        .applz => {
            std.debug.print("ORCHD_APPLE_MODE={s} is now applz, its own runtime (https://github.com/adiled/applz): install it and use --rootstock applz\n", .{wanted});
            std.process.exit(1);
        },
    };
}

fn quiet(io: std.Io, argv: []const []const u8) bool {
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return false;
    const term = child.wait(io) catch return false;
    return term.success();
}

fn writeOut(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

fn readEnvelope(arena: std.mem.Allocator, io: std.Io) plugin.Envelope {
    var buf: [4096]u8 = undefined;
    var reader: std.Io.File.Reader = .initStreaming(.stdin(), io, &buf);
    const bytes = reader.interface.allocRemaining(arena, .limited(1 << 20)) catch {
        std.debug.print("unreadable envelope: stdin\n", .{});
        std.process.exit(1);
    };
    return plugin.parseEnvelope(arena, bytes) catch |err| {
        if (err == error.ContractMismatch) {
            std.debug.print("orchd-rootstock-apple speaks contract {d}\n", .{plugin.contract});
        } else {
            std.debug.print("unreadable envelope: {s}\n", .{@errorName(err)});
        }
        std.process.exit(1);
    };
}

fn refuse(refusal: plugin.Refusal, service: types.Service) noreturn {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    plugin.explain(refusal, service, &w) catch {};
    std.debug.print("{s}", .{w.buffered()});
    std.process.exit(1);
}

fn cmdRemove(arena: std.mem.Allocator, io: std.Io, mode: plugin.Mode) !void {
    const envelope = readEnvelope(arena, io);
    if (plugin.isHost(envelope.service)) return;
    const name = try std.fmt.allocPrint(arena, "{s}-{s}", .{ envelope.grove, envelope.service.name });
    switch (mode) {
        .cli => _ = quiet(io, &.{ "container", "delete", "--force", name }),
        .xpc => {
            const c = client_mod.Client.init();
            defer c.deinit();
            c.containerDelete(arena, name, true) catch {};
        },
    }
}

fn cmdCliStart(arena: std.mem.Allocator, io: std.Io, positionals: []const []const u8) noreturn {
    const dashes = for (positionals, 0..) |p, i| {
        if (std.mem.eql(u8, p, "--")) break i;
    } else positionals.len;
    if (dashes != 3 or positionals.len < dashes + 3) {
        std.debug.print("usage: orchd-rootstock-apple cli-start <name> <definition> -- container run ...\n", .{});
        std.process.exit(2);
    }
    const name = positionals[1];
    const definition = positionals[2];
    const run_argv = positionals[dashes + 1 ..];

    if (cliKept(arena, io, name, definition)) {
        std.debug.print("woke {s}, kept from its last run\n", .{name});
        const err = std.process.replace(io, .{ .argv = &.{ "container", "start", "--attach", name } });
        std.debug.print("container start {s}: {s}\n", .{ name, @errorName(err) });
        std.process.exit(1);
    }
    _ = quiet(io, &.{ "container", "delete", "--force", name });
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(arena, run_argv[0..2]) catch std.process.exit(1);
    const label = std.fmt.allocPrint(arena, "{s}={s}", .{ plugin.definition_label, definition }) catch std.process.exit(1);
    argv.appendSlice(arena, &.{ "--label", label }) catch std.process.exit(1);
    argv.appendSlice(arena, run_argv[2..]) catch std.process.exit(1);
    const err = std.process.replace(io, .{ .argv = argv.items });
    std.debug.print("{s} {s}: {s}\n", .{ run_argv[0], run_argv[1], @errorName(err) });
    std.process.exit(1);
}

fn cliKept(arena: std.mem.Allocator, io: std.Io, name: []const u8, definition: []const u8) bool {
    const out = std.process.run(arena, io, .{ .argv = &.{ "container", "inspect", name } }) catch return false;
    if (!out.term.success()) return false;
    const doc = std.json.parseFromSliceLeaky(std.json.Value, arena, out.stdout, .{}) catch return false;
    const first = switch (doc) {
        .array => |a| if (a.items.len > 0) a.items[0] else return false,
        else => return false,
    };
    const config = switch (first) {
        .object => |o| o.get("configuration") orelse return false,
        else => return false,
    };
    const labels = switch (config) {
        .object => |o| o.get("labels") orelse return false,
        else => return false,
    };
    const found = switch (labels) {
        .object => |o| o.get(plugin.definition_label) orelse return false,
        else => return false,
    };
    return found == .string and std.mem.eql(u8, found.string, definition);
}

fn cmdExecSet(arena: std.mem.Allocator, io: std.Io, mode: plugin.Mode) !void {
    const envelope = readEnvelope(arena, io);
    const service = envelope.service;
    const set = if (plugin.isHost(service))
        plugin.hostExecSet(service) catch |r| refuse(r, service)
    else switch (mode) {
        .cli => plugin.cliExecSet(arena, envelope, std.process.executablePathAlloc(io, arena) catch "orchd-rootstock-apple") catch |err| switch (err) {
            error.NoImage, error.NoRunCommand => |r| refuse(r, service),
            else => |e| return e,
        },
        .xpc => plugin.xpcExecSet(arena, io, envelope) catch |err| switch (err) {
            error.NoImage => refuse(error.NoImage, service),
            else => |e| return e,
        },
    };
    try writeOut(io, try std.json.Stringify.valueAlloc(arena, set, .{}));
    try writeOut(io, "\n");
}

fn cmdPrepare(arena: std.mem.Allocator, io: std.Io) !void {
    const envelope = readEnvelope(arena, io);
    const service = envelope.service;
    if (plugin.isHost(service)) {
        const dir = try std.fs.path.join(arena, &.{ envelope.data_dir, service.name });
        std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
            std.debug.print("cannot make {s}: {s}\n", .{ dir, @errorName(err) });
            std.process.exit(1);
        };
        return;
    }
    const image = service.image orelse refuse(error.NoImage, service);
    prepare_mod.pullImage(io, image) catch |err| {
        std.debug.print("container image pull {s} failed: {s}\n", .{ image, @errorName(err) });
        std.process.exit(1);
    };
}
