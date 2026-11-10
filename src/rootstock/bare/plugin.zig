const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const contract = @import("contract");
const Service = contract.Service;
const ExecSet = contract.ExecSet;
const Envelope = contract.Envelope;

pub const Refusal = error{ ContainerService, NoRunCommand };

pub fn execSet(service: Service) Refusal!ExecSet {
    return switch (service.mode) {
        .container => error.ContainerService,
        .host => .{
            .start = service.run_command orelse return error.NoRunCommand,
            .stop = service.stop_command,
            .reload = service.reload_command,
        },
    };
}

pub fn explain(refusal: Refusal, service: Service, w: *Io.Writer) Io.Writer.Error!void {
    switch (refusal) {
        error.ContainerService => try w.print(
            "service '{s}' is a container (FROM {s}); bare runs host services: " ++
                "give it a bare overlay that redefines it with RUN, " ++
                "or use a container rootstock (--rootstock apple)\n",
            .{ service.name, service.image orelse "unknown" },
        ),
        error.NoRunCommand => try w.print(
            "service '{s}' is host-mode but has no RUN command\n",
            .{service.name},
        ),
    }
}

pub fn prepare(io: Io, root: Io.Dir, envelope: Envelope) !void {
    const data = try root.createDirPathOpen(io, envelope.data_dir, .{});
    defer data.close(io);
    try data.createDirPath(io, envelope.service.name);
}

fn envelopeFor(service: Service) Envelope {
    return .{
        .contract = contract.base,
        .grove = "orchard",
        .project_dir = "project",
        .data_dir = "data",
        .state_dir = "state",
        .service = service,
    };
}

test "a host service starts with its RUN, stops with its STOP, reloads with its RELOAD" {
    const set = try execSet(.{
        .name = "web",
        .mode = .host,
        .run_command = "nginx -g 'daemon off;'",
        .stop_command = "nginx -s quit",
        .reload_command = "kill -HUP $MAINPID",
    });
    try testing.expectEqualStrings("nginx -g 'daemon off;'", set.start);
    try testing.expectEqualStrings("nginx -s quit", set.stop.?);
    try testing.expectEqualStrings("kill -HUP $MAINPID", set.reload.?);
    try testing.expectEqual(null, set.pre_start);
    try testing.expectEqual(null, set.post_stop);
}

test "a host service with only RUN has nothing around it" {
    const set = try execSet(.{ .name = "web", .mode = .host, .run_command = "/usr/bin/nginx" });
    try testing.expectEqualStrings("/usr/bin/nginx", set.start);
    try testing.expectEqual(null, set.stop);
    try testing.expectEqual(null, set.reload);
}

test "a host service without RUN is refused by name" {
    const service: Service = .{ .name = "web", .mode = .host };
    try testing.expectError(error.NoRunCommand, execSet(service));

    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try explain(error.NoRunCommand, service, &out.writer);
    try testing.expectEqualStrings("service 'web' is host-mode but has no RUN command\n", out.written());
}

test "a container service is refused with its image and the way out" {
    const service: Service = .{ .name = "postgres", .mode = .container, .image = "pgvector/pgvector:pg15" };
    try testing.expectError(error.ContainerService, execSet(service));

    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try explain(error.ContainerService, service, &out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "FROM pgvector/pgvector:pg15") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "--rootstock apple") != null);
}

test "prepare gives the service its own data directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try prepare(testing.io, tmp.dir, envelopeFor(.{ .name = "web", .mode = .host }));
    try tmp.dir.access(testing.io, "data/web", .{});
    try prepare(testing.io, tmp.dir, envelopeFor(.{ .name = "web", .mode = .host }));
}
