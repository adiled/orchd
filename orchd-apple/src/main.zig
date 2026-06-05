//! orchd-apple — Apple container runtime co-process for orchd.
//!
//! Commands:
//!   orchd-apple check                -- exit 0 if apiserver reachable
//!   orchd-apple exec-set <namespace> -- stdin: Service JSON → stdout: ExecSet JSON
//!   orchd-apple prepare  <namespace> -- stdin: Service JSON, pulls image
//!   orchd-apple cleanup  <namespace> -- stdin: Service JSON, deletes container

const std = @import("std");
const clap = @import("clap");

const client_mod = @import("client.zig");
const exec_set_mod = @import("exec_set.zig");
const oci_mod = @import("oci.zig");
const prepare_mod = @import("prepare.zig");
const types = @import("types.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Display this help and exit.
        \\<str>...
        \\
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, init.minimal.args, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0)
        return clap.helpToFile(io, .stderr(), clap.Help, &params, .{});

    const positionals = res.positionals[0];
    if (positionals.len == 0) {
        std.debug.print("error: command required (check | exec-set | prepare | cleanup)\n", .{});
        std.process.exit(1);
    }

    const command = positionals[0];
    const namespace = if (positionals.len >= 2) positionals[1] else "orch";

    if (std.mem.eql(u8, command, "check")) {
        try cmdCheck(allocator);
    } else if (std.mem.eql(u8, command, "exec-set")) {
        try cmdExecSet(allocator, io, namespace);
    } else if (std.mem.eql(u8, command, "prepare")) {
        try cmdPrepare(allocator, io, namespace);
    } else if (std.mem.eql(u8, command, "cleanup")) {
        try cmdCleanup(allocator, io, namespace);
    } else if (std.mem.eql(u8, command, "list")) {
        try cmdList(allocator, io);
    } else if (std.mem.eql(u8, command, "stop")) {
        try cmdStop(allocator, namespace); // namespace slot carries the container id
    } else if (std.mem.eql(u8, command, "delete")) {
        try cmdDelete(allocator, namespace);
    } else if (std.mem.eql(u8, command, "kernel")) {
        try cmdKernel(allocator, io);
    } else if (std.mem.eql(u8, command, "images")) {
        try cmdImages(allocator, io);
    } else if (std.mem.eql(u8, command, "content")) {
        try cmdContent(allocator, io, namespace); // namespace slot carries the digest
    } else if (std.mem.eql(u8, command, "resolve")) {
        try cmdResolve(allocator, io, namespace); // namespace slot carries the image ref
    } else if (std.mem.eql(u8, command, "run")) {
        try cmdRun(allocator, io, positionals);
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

/// `run <id> <image>`: create and start a container entirely over XPC.
fn cmdRun(allocator: std.mem.Allocator, io: std.Io, positionals: []const []const u8) !void {
    if (positionals.len < 3) {
        std.debug.print("usage: orchd-apple run <id> <image>\n", .{});
        std.process.exit(1);
    }
    const id = positionals[1];
    const reference = positionals[2];

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    oci_mod.run(arena_state.allocator(), allocator, io, id, reference) catch |err| {
        std.debug.print("error: run failed ({s})\n", .{@errorName(err)});
        std.process.exit(1);
    };
    std.debug.print("started {s} ({s}) via XPC\n", .{ id, reference });
}

fn cmdExecSet(allocator: std.mem.Allocator, io: std.Io, namespace: []const u8) !void {
    const svc = readService(allocator, io) catch std.process.exit(1);
    defer svc.deinit();
    if (!std.mem.eql(u8, svc.value.mode, "container")) {
        std.debug.print("error: apple runtime only handles container-mode services\n", .{});
        std.process.exit(1);
    }
    const es = exec_set_mod.build(allocator, svc.value, namespace) catch |err| {
        std.debug.print("error: exec-set: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer es.deinit(allocator);
    const json = try std.json.Stringify.valueAlloc(allocator, es, .{});
    defer allocator.free(json);

    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    try fw.interface.writeAll(json);
    try fw.interface.flush();
}

fn cmdPrepare(allocator: std.mem.Allocator, io: std.Io, namespace: []const u8) !void {
    _ = namespace;
    const svc = readService(allocator, io) catch std.process.exit(1);
    defer svc.deinit();
    const image = svc.value.image orelse {
        std.debug.print("error: service has no image\n", .{});
        std.process.exit(1);
    };
    prepare_mod.pullImage(io, image) catch |err| {
        std.debug.print("error: pull failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn cmdCleanup(allocator: std.mem.Allocator, io: std.Io, namespace: []const u8) !void {
    const svc = readService(allocator, io) catch std.process.exit(1);
    defer svc.deinit();
    const name = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ namespace, svc.value.name });
    defer allocator.free(name);
    const c = client_mod.Client.init();
    defer c.deinit();
    c.containerDelete(allocator, name, true) catch {};
}

/// Read all of stdin, then parse as Service JSON.
fn readService(allocator: std.mem.Allocator, io: std.Io) !std.json.Parsed(types.Service) {
    var buf: [4096]u8 = undefined;
    var fr = std.Io.File.stdin().reader(io, &buf);
    const data = fr.interface.allocRemaining(allocator, .unlimited) catch {
        std.debug.print("error: failed to read stdin\n", .{});
        return error.ReadFailed;
    };
    defer allocator.free(data);
    return std.json.parseFromSlice(types.Service, allocator, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        std.debug.print("error: failed to parse service JSON: {s}\n", .{@errorName(err)});
        return error.ParseFailed;
    };
}
