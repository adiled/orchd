//! ExecSet generation: translates a Service into `orchd-apple` XPC subcommands.
//!
//! Naming:  <namespace>-<service.name>  e.g. "orch-postgres"
//!
//! Each stage re-invokes this very binary, which talks to the pinned apple
//! container daemon over XPC (no `container` CLI anywhere):
//!   pre_start  — `orchd-apple pull <image>`
//!   start      — `orchd-apple run <name> <image> && orchd-apple wait <name>`
//!                (wait blocks while the container lives, so launchd tracks it)
//!   stop       — `orchd-apple stop <name>`
//!   post_stop  — `orchd-apple delete <name>` (clean slate on restart)

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

    // The ExecSet invokes this very binary's XPC-backed subcommands, so the
    // launchd supervisor drives the apple container entirely over XPC (no
    // `container` CLI). `run` returns once started; `wait` blocks while alive.
    const self = std.process.executablePathAlloc(io, allocator) catch return Error.OutOfMemory;
    defer allocator.free(self);

    const pre_start = try std.fmt.allocPrint(allocator, "{s} pull {s}", .{ self, image });
    const start = try std.fmt.allocPrint(
        allocator,
        "{s} run {s} {s} && {s} wait {s}",
        .{ self, name, image, self, name },
    );
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

test "minimal container service drives orchd-apple over xpc" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const svc = types.Service{ .name = "postgres", .mode = "container", .image = "postgres:15" };
    const es = try build(allocator, io, svc, "orch");
    defer es.deinit(allocator);

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
