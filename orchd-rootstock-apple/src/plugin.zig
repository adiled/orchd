const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const types = @import("types.zig");
const exec_set = @import("exec_set.zig");

pub const contract: u32 = 1;

pub const Envelope = struct {
    contract: u32,
    grove: []const u8,
    project_dir: []const u8,
    data_dir: []const u8,
    state_dir: []const u8,
    service: types.Service,
};

pub const Mode = enum {
    cli,
    xpc,

    pub const Choice = union(enum) { mode: Mode, unknown, applz };

    pub fn parse(wanted: []const u8) Choice {
        const t = std.mem.trim(u8, wanted, " \t\r\n");
        const table = [_]struct { []const u8, Choice }{
            .{ "container", .{ .mode = .cli } }, .{ "cli", .{ .mode = .cli } },
            .{ "xpc", .{ .mode = .xpc } },       .{ "daemon", .{ .mode = .xpc } },
            .{ "apple", .{ .mode = .xpc } },     .{ "orchd-apple", .{ .mode = .xpc } },
            .{ "", .{ .mode = .xpc } },          .{ "osx", .applz },
            .{ "vz", .applz },                   .{ "orchd-osx", .applz },
        };
        for (table) |entry| {
            if (std.ascii.eqlIgnoreCase(t, entry[0])) return entry[1];
        }
        return .unknown;
    }
};

pub const Refusal = error{ NoRunCommand, NoImage };

pub fn parseEnvelope(arena: Allocator, bytes: []const u8) !Envelope {
    const envelope = try std.json.parseFromSliceLeaky(Envelope, arena, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    if (envelope.contract != contract) return error.ContractMismatch;
    return envelope;
}

pub fn isHost(service: types.Service) bool {
    return std.mem.eql(u8, service.mode, "host");
}

pub fn hostExecSet(service: types.Service) Refusal!types.ExecSet {
    return .{
        .start = service.run_command orelse return error.NoRunCommand,
        .stop = service.stop_command,
        .reload = service.reload_command,
    };
}

pub fn volumeSource(arena: Allocator, project_dir: []const u8, vol: types.Volume) ![]const u8 {
    if (vol.is_named or std.fs.path.isAbsolute(vol.source)) return vol.source;
    return std.fs.path.join(arena, &.{ project_dir, vol.source });
}

pub fn cliExecSet(arena: Allocator, envelope: Envelope) (Refusal || Allocator.Error || error{WriteFailed})!types.ExecSet {
    const s = envelope.service;
    const image = s.image orelse return error.NoImage;
    const name = try std.fmt.allocPrint(arena, "{s}-{s}", .{ envelope.grove, s.name });
    var start: Io.Writer.Allocating = .init(arena);
    const w = &start.writer;
    try w.print("container run --name {s} --init", .{name});

    if (s.env == .object) {
        const keys = try arena.dupe([]const u8, s.env.object.keys());
        std.mem.sort([]const u8, keys, {}, lessThan);
        for (keys) |k| switch (s.env.object.get(k).?) {
            .string => |v| try w.print(" --env {s}={s}", .{ k, v }),
            else => {},
        };
    }
    for (s.env_files) |ef| try w.print(" --env-file {s}", .{ef});
    for (s.volumes) |vol| try w.print(" --volume {s}:{s}", .{ try volumeSource(arena, envelope.project_dir, vol), vol.destination });
    for (s.publish) |p| {
        if (p.address) |addr| {
            try w.print(" --publish {s}:{d}:{d}", .{ addr, p.host, p.container });
        } else {
            try w.print(" --publish {d}:{d}", .{ p.host, p.container });
        }
    }
    if (s.resources.memory) |mem| try w.print(" --memory {s}", .{mem});
    if (s.resources.cpus) |cpus| try w.print(" --cpus {d}", .{cpus});
    if (s.user) |user| try w.print(" --user {s}", .{user});
    if (s.workdir) |wd| try w.print(" --workdir {s}", .{wd});
    if (s.entrypoint) |ep| try w.print(" --entrypoint {s}", .{ep});
    try w.print(" {s}", .{image});
    if (s.cmd) |cmd| try w.print(" {s}", .{cmd});

    return .{
        .start = start.written(),
        .pre_start = try std.fmt.allocPrint(arena, "container image pull {s}", .{image}),
        .stop = try std.fmt.allocPrint(arena, "container stop {s}", .{name}),
        .post_stop = try std.fmt.allocPrint(arena, "container delete --force {s}", .{name}),
    };
}

pub fn xpcExecSet(arena: Allocator, io: Io, envelope: Envelope) !types.ExecSet {
    if (envelope.service.image == null) return error.NoImage;
    return exec_set.build(arena, io, envelope.service, envelope.grove);
}

pub fn explain(refusal: Refusal, service: types.Service, w: *Io.Writer) Io.Writer.Error!void {
    switch (refusal) {
        error.NoRunCommand => try w.print("service '{s}' is host-mode but has no RUN command\n", .{service.name}),
        error.NoImage => try w.print("service '{s}' is container-mode but has no FROM image\n", .{service.name}),
    }
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn envelopeFor(arena: Allocator, service_json: []const u8) !Envelope {
    return parseEnvelope(arena, try std.fmt.allocPrint(arena,
        \\{{"contract":1,"grove":"orch","project_dir":"/proj","data_dir":"/d","state_dir":"/s","service":{s}}}
    , .{service_json}));
}

test {
    _ = @import("oci.zig");
}

test "modes read from ORCHD_APPLE_MODE, any case, and osx points at applz" {
    try testing.expectEqual(Mode.Choice{ .mode = .cli }, Mode.parse("container"));
    try testing.expectEqual(Mode.Choice{ .mode = .cli }, Mode.parse("CLI"));
    try testing.expectEqual(Mode.Choice{ .mode = .xpc }, Mode.parse(""));
    try testing.expectEqual(Mode.Choice{ .mode = .xpc }, Mode.parse("daemon"));
    try testing.expectEqual(Mode.Choice.applz, Mode.parse("OSX"));
    try testing.expectEqual(Mode.Choice.applz, Mode.parse("vz"));
    try testing.expectEqual(Mode.Choice.unknown, Mode.parse("bogus"));
}

test "the cli mode spells out the whole container" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e = try envelopeFor(a,
        \\{"name":"postgres","mode":"container","image":"postgres:15","env":{"FOO":"bar","ALPHA":"1"},
        \\ "publish":[{"host":8080,"container":80},{"address":"127.0.0.1","host":5432,"container":5432}],
        \\ "volumes":[{"source":"./pgdata","destination":"/data","is_named":false},{"source":"named-vol","destination":"/v","is_named":true}],
        \\ "resources":{"memory":"512M","cpus":2.0}}
    );
    const set = try cliExecSet(a, e);
    try testing.expectEqualStrings(
        "container run --name orch-postgres --init --env ALPHA=1 --env FOO=bar" ++
            " --volume /proj/./pgdata:/data --volume named-vol:/v" ++
            " --publish 8080:80 --publish 127.0.0.1:5432:5432 --memory 512M --cpus 2 postgres:15",
        set.start,
    );
    try testing.expectEqualStrings("container image pull postgres:15", set.pre_start.?);
    try testing.expectEqualStrings("container stop orch-postgres", set.stop.?);
    try testing.expectEqualStrings("container delete --force orch-postgres", set.post_stop.?);
}

test "the xpc mode drives this binary over XPC" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const set = try xpcExecSet(a, testing.io, try envelopeFor(a,
        \\{"name":"postgres","mode":"container","image":"postgres:15"}
    ));
    try testing.expect(std.mem.indexOf(u8, set.start, " run orch-postgres postgres:15") != null);
    try testing.expect(std.mem.indexOf(u8, set.start, " wait orch-postgres") != null);
    try testing.expect(std.mem.endsWith(u8, set.stop.?, " stop orch-postgres"));
    try testing.expect(std.mem.endsWith(u8, set.post_stop.?, " delete orch-postgres"));
}

test "a host service runs as it would bare, and a service without what it needs is refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const host = try envelopeFor(a,
        \\{"name":"web","mode":"host","run_command":"/usr/bin/nginx","reload_command":"kill -HUP $MAINPID"}
    );
    try testing.expect(isHost(host.service));
    const set = try hostExecSet(host.service);
    try testing.expectEqualStrings("/usr/bin/nginx", set.start);
    try testing.expectEqualStrings("kill -HUP $MAINPID", set.reload.?);
    try testing.expectError(error.NoRunCommand, hostExecSet((try envelopeFor(a,
        \\{"name":"web","mode":"host"}
    )).service));
    try testing.expectError(error.NoImage, cliExecSet(a, try envelopeFor(a,
        \\{"name":"db","mode":"container"}
    )));
}

test "an envelope from another contract is refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.ContractMismatch, parseEnvelope(arena.allocator(),
        \\{"contract":2,"grove":"g","project_dir":"/p","data_dir":"/d","state_dir":"/s","service":{"name":"x","mode":"host"}}
    ));
}
