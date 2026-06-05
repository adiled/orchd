//! ExecSet generation: translates a Service into `container` CLI commands.
//!
//! Naming:  <namespace>-<service.name>  e.g. "orch-postgres"
//!
//! Lifecycle:
//!   pre_start  — pull image
//!   start      — `container run` (no -d) — foreground so supervisor tracks PID
//!   stop       — `container stop <name>`
//!   post_stop  — `container delete --force <name>` (clean slate on restart)

const std = @import("std");
const types = @import("types.zig");

pub const Error = error{
    MissingImage,
    OutOfMemory,
    WriteFailed,
};

pub fn build(
    allocator: std.mem.Allocator,
    svc: types.Service,
    namespace: []const u8,
) Error!types.ExecSet {
    if (svc.image == null) return Error.MissingImage;
    const image = svc.image.?;

    const container_name = try std.fmt.allocPrint(
        allocator, "{s}-{s}", .{ namespace, svc.name },
    );
    defer allocator.free(container_name); // internal temporary; not returned

    // pre_start: image pull
    const pre_start = try std.fmt.allocPrint(
        allocator, "container image pull {s}", .{image},
    );

    // start: build command string via Io.Writer.Allocating
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    try aw.writer.print("container run --name {s}", .{container_name});
    // --init: forwards signals to container, reaps zombies
    try aw.writer.writeAll(" --init");

    // env vars (parsed from JSON object)
    if (svc.env == .object) {
        var iter = svc.env.object.iterator();
        while (iter.next()) |entry| {
            const val = switch (entry.value_ptr.*) {
                .string => |s| s,
                else => continue,
            };
            try aw.writer.print(" --env {s}={s}", .{ entry.key_ptr.*, val });
        }
    }

    for (svc.env_files) |ef| {
        try aw.writer.print(" --env-file {s}", .{ef});
    }
    for (svc.volumes) |vol| {
        try aw.writer.print(" --volume {s}:{s}", .{ vol.source, vol.destination });
    }
    for (svc.publish) |port| {
        if (port.address) |addr| {
            try aw.writer.print(" --publish {s}:{d}:{d}", .{ addr, port.host, port.container });
        } else {
            try aw.writer.print(" --publish {d}:{d}", .{ port.host, port.container });
        }
    }
    if (svc.resources.memory) |mem| {
        try aw.writer.print(" --memory {s}", .{mem});
    }
    if (svc.resources.cpus) |cpus| {
        if (cpus == @trunc(cpus)) {
            try aw.writer.print(" --cpus {d}", .{@as(u64, @intFromFloat(cpus))});
        } else {
            try aw.writer.print(" --cpus {d}", .{cpus});
        }
    }
    if (svc.user) |user| try aw.writer.print(" --user {s}", .{user});
    if (svc.workdir) |wd| try aw.writer.print(" --workdir {s}", .{wd});
    if (svc.entrypoint) |ep| try aw.writer.print(" --entrypoint {s}", .{ep});
    try aw.writer.print(" {s}", .{image});
    if (svc.cmd) |cmd| try aw.writer.print(" {s}", .{cmd});

    const start = try aw.toOwnedSlice();

    const stop = try std.fmt.allocPrint(
        allocator, "container stop {s}", .{container_name},
    );
    const post_stop = try std.fmt.allocPrint(
        allocator, "container delete --force {s}", .{container_name},
    );

    return types.ExecSet{
        .start = start,
        .pre_start = pre_start,
        .stop = stop,
        .post_stop = post_stop,
    };
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "minimal container service" {
    const allocator = std.testing.allocator;
    const svc = types.Service{ .name = "postgres", .mode = "container", .image = "postgres:15" };
    const es = try build(allocator, svc, "orch");
    defer es.deinit(allocator);
    try std.testing.expectEqualStrings("container image pull postgres:15", es.pre_start.?);
    try std.testing.expect(std.mem.indexOf(u8, es.start, "--name orch-postgres") != null);
    try std.testing.expect(std.mem.indexOf(u8, es.start, "--init") != null);
    try std.testing.expect(std.mem.indexOf(u8, es.start, "postgres:15") != null);
    try std.testing.expectEqualStrings("container stop orch-postgres", es.stop.?);
    try std.testing.expectEqualStrings("container delete --force orch-postgres", es.post_stop.?);
}

test "resources and ports" {
    const allocator = std.testing.allocator;
    const svc = types.Service{
        .name = "api",
        .mode = "container",
        .image = "myapp:latest",
        .publish = &.{.{ .host = 8080, .container = 80 }},
        .resources = .{ .memory = "512M", .cpus = 2.0 },
        .user = "nobody",
    };
    const es = try build(allocator, svc, "myns");
    defer es.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, es.start, "--publish 8080:80") != null);
    try std.testing.expect(std.mem.indexOf(u8, es.start, "--memory 512M") != null);
    try std.testing.expect(std.mem.indexOf(u8, es.start, "--cpus 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, es.start, "--user nobody") != null);
}

test "missing image is an error" {
    const svc = types.Service{ .name = "broken", .mode = "container", .image = null };
    try std.testing.expectError(Error.MissingImage, build(std.testing.allocator, svc, "orch"));
}

test "publish with host address" {
    const allocator = std.testing.allocator;
    const svc = types.Service{
        .name = "api",
        .mode = "container",
        .image = "myapp:latest",
        .publish = &.{.{ .address = "127.0.0.1", .host = 8080, .container = 80 }},
    };
    const es = try build(allocator, svc, "myns");
    defer es.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, es.start, "--publish 127.0.0.1:8080:80") != null);
}
