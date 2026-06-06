//! ExecSet generation: translates a Service into `orchd-osx` subcommands.
//!
//! Naming:  <namespace>-<service.name>  e.g. "orch-postgres"
//!
//! Each stage re-invokes this very binary, which drives the container on
//! Virtualization.framework (no daemon, no CLI):
//!   pre_start  — `orchd-osx pull <image>`
//!   start      — `orchd-osx run <name> <image> && orchd-osx wait <name>`
//!                (wait blocks while the container lives, so launchd tracks it)
//!   stop       — `orchd-osx stop <name>`
//!   post_stop  — `orchd-osx delete <name>` (clean slate on restart)
//!
//! Identical in shape to orchd-apple's generator: the self path resolves to
//! whichever binary is running, so the same code drives the VZ backend here.

const std = @import("std");
const types = @import("types.zig");

pub const Error = error{
    MissingImage,
    OutOfMemory,
    WriteFailed,
};

pub fn build(
    allocator: std.mem.Allocator,
    io: std.Io,
    svc: types.Service,
    namespace: []const u8,
) Error!types.ExecSet {
    if (svc.image == null) return Error.MissingImage;
    const image = svc.image.?;

    const name = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ namespace, svc.name });
    defer allocator.free(name);

    // The ExecSet invokes this very binary's subcommands, so the launchd
    // supervisor drives the VZ-backed container with no daemon. `run` returns
    // once started; `wait` blocks while the container is alive.
    const self = std.process.executablePathAlloc(io, allocator) catch return Error.OutOfMemory;
    defer allocator.free(self);

    const pre_start = try std.fmt.allocPrint(allocator, "{s} pull {s}", .{ self, image });
    // The VM lives inside the `run` process, so run is the foreground process
    // launchd tracks: it blocks until the container exits. No separate `wait`.
    const start = try std.fmt.allocPrint(allocator, "{s} run {s} {s}", .{ self, name, image });
    const stop = try std.fmt.allocPrint(allocator, "{s} stop {s}", .{ self, name });
    const post_stop = try std.fmt.allocPrint(allocator, "{s} delete {s}", .{ self, name });

    return types.ExecSet{
        .start = start,
        .pre_start = pre_start,
        .stop = stop,
        .post_stop = post_stop,
    };
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "minimal container service drives orchd-osx" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const svc = types.Service{ .name = "postgres", .mode = "container", .image = "postgres:15" };
    const es = try build(allocator, io, svc, "orch");
    defer es.deinit(allocator);

    try std.testing.expect(std.mem.endsWith(u8, es.pre_start.?, " pull postgres:15"));
    try std.testing.expect(std.mem.indexOf(u8, es.start, " run orch-postgres postgres:15") != null);
    // run is foreground (the VM lives in it); no separate wait stage.
    try std.testing.expect(std.mem.indexOf(u8, es.start, " wait ") == null);
    try std.testing.expect(std.mem.endsWith(u8, es.stop.?, " stop orch-postgres"));
    try std.testing.expect(std.mem.endsWith(u8, es.post_stop.?, " delete orch-postgres"));

    // No `container` CLI anywhere.
    try std.testing.expect(std.mem.indexOf(u8, es.start, "container ") == null);
}

test "namespace prefixes the container name" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const svc = types.Service{ .name = "api", .mode = "container", .image = "myapp:latest" };
    const es = try build(allocator, io, svc, "myns");
    defer es.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, es.start, " run myns-api myapp:latest") != null);
    try std.testing.expect(std.mem.endsWith(u8, es.stop.?, " stop myns-api"));
}

test "missing image is an error" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const svc = types.Service{ .name = "broken", .mode = "container", .image = null };
    try std.testing.expectError(Error.MissingImage, build(std.testing.allocator, io, svc, "orch"));
}
