const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const contract: u32 = 1;

pub const Mode = enum { host, container };

pub const Service = struct {
    name: []const u8,
    mode: Mode,
    image: ?[]const u8 = null,
    run_command: ?[]const u8 = null,
    stop_command: ?[]const u8 = null,
    reload_command: ?[]const u8 = null,
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

pub const Refusal = error{ ContainerService, NoRunCommand };

pub fn parseEnvelope(arena: Allocator, bytes: []const u8) !Envelope {
    const envelope = try std.json.parseFromSliceLeaky(Envelope, arena, bytes, .{
        .ignore_unknown_fields = true,
    });
    if (envelope.contract != contract) return error.ContractMismatch;
    return envelope;
}

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

pub fn emit(set: ExecSet, w: *Io.Writer) Io.Writer.Error!void {
    try std.json.Stringify.value(set, .{}, w);
    try w.writeByte('\n');
}

pub fn prepare(io: Io, root: Io.Dir, envelope: Envelope) !void {
    const data = try root.createDirPathOpen(io, envelope.data_dir, .{});
    defer data.close(io);
    try data.createDirPath(io, envelope.service.name);
}

fn envelopeFor(service: Service) Envelope {
    return .{
        .contract = contract,
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

test "the exec set goes out as one line of JSON with every field named" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try emit(.{ .start = "sleep 1", .reload = "kill -HUP $MAINPID" }, &out.writer);
    try testing.expectEqualStrings(
        "{\"start\":\"sleep 1\",\"pre_start\":null,\"stop\":null,\"post_stop\":null,\"reload\":\"kill -HUP $MAINPID\"}\n",
        out.written(),
    );
}

test "the envelope reads what orchd sends and passes over what bare does not use" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const envelope = try parseEnvelope(arena.allocator(),
        \\{"contract":1,"grove":"hum","project_dir":"/p","data_dir":"/d","state_dir":"/s",
        \\ "service":{"name":"web","mode":"host","run_command":"sleep 1","env":{"A":"b"},
        \\  "oneshot":false,"disabled":true,"recreate":"never","restart":{"policy":"always"},
        \\  "timeouts":{},"resources":{},"logging":{}}}
    );
    try testing.expectEqualStrings("hum", envelope.grove);
    try testing.expectEqualStrings("/d", envelope.data_dir);
    try testing.expectEqualStrings("web", envelope.service.name);
    try testing.expectEqual(.host, envelope.service.mode);
    try testing.expectEqualStrings("sleep 1", envelope.service.run_command.?);
    try testing.expectEqual(null, envelope.service.stop_command);
}

test "an envelope from another contract is refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.ContractMismatch, parseEnvelope(arena.allocator(),
        \\{"contract":2,"grove":"g","project_dir":"/p","data_dir":"/d","state_dir":"/s",
        \\ "service":{"name":"web","mode":"host"}}
    ));
}

test "prepare gives the service its own data directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try prepare(testing.io, tmp.dir, envelopeFor(.{ .name = "web", .mode = .host }));
    try tmp.dir.access(testing.io, "data/web", .{});
    try prepare(testing.io, tmp.dir, envelopeFor(.{ .name = "web", .mode = .host }));
}
