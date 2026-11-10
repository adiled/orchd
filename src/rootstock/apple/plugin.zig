const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const contract = @import("contract");
const Service = contract.Service;
const ExecSet = contract.ExecSet;
const Envelope = contract.Envelope;
const exec_set = @import("exec_set.zig");

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

pub fn hostExecSet(service: Service) Refusal!ExecSet {
    return .{
        .start = service.run_command orelse return error.NoRunCommand,
        .stop = service.stop_command,
        .reload = service.reload_command,
    };
}

pub const definition_label = "orchd.definition";

pub fn keeps(service: Service) bool {
    return service.recreate != .always;
}

pub fn definitionOf(arena: Allocator, envelope: Envelope) ![]const u8 {
    const s = envelope.service;
    const defined = .{
        .project_dir = envelope.project_dir,
        .service = .{
            .name = s.name,
            .mode = s.mode,
            .image = s.image,
            .run_command = s.run_command,
            .stop_command = s.stop_command,
            .reload_command = s.reload_command,
            .entrypoint = s.entrypoint,
            .cmd = s.cmd,
            .publish = s.publish,
            .volumes = s.volumes,
            .user = s.user,
            .workdir = s.workdir,
            .env = s.env,
            .env_files = s.env_files,
            .resources = .{ .memory = s.resources.memory, .cpus = s.resources.cpus, .limit_nofile = s.resources.limit_nofile },
            .recreate = "never",
            .oneshot = s.oneshot,
        },
    };
    const json = try std.json.Stringify.valueAlloc(arena, defined, .{});
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(json, &digest, .{});
    return std.fmt.allocPrint(arena, "{x}", .{&digest});
}

pub fn cliExecSet(arena: Allocator, envelope: Envelope, self: []const u8) (Refusal || Allocator.Error || error{WriteFailed})!ExecSet {
    const s = envelope.service;
    const image = s.image orelse return error.NoImage;
    const name = try envelope.containerName(arena);
    var start: Io.Writer.Allocating = .init(arena);
    const w = &start.writer;
    try w.print("container run --name {s} --init", .{name});

    const keys = try arena.dupe([]const u8, s.env.map.keys());
    std.mem.sort([]const u8, keys, {}, lessThan);
    for (keys) |k| try w.print(" --env {s}={s}", .{ k, s.env.map.get(k).? });
    for (s.env_files) |ef| try w.print(" --env-file {s}", .{ef});
    for (s.volumes) |vol| try w.print(" --volume {s}:{s}{s}", .{ vol.source, vol.destination, if (vol.read_only) ":ro" else "" });
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

    const pull = try std.fmt.allocPrint(arena, "container image pull {s}", .{image});
    const stop = try std.fmt.allocPrint(arena, "container stop {s}", .{name});
    if (keeps(s)) return .{
        .start = try std.fmt.allocPrint(arena, "'{s}' cli-start {s} {s} -- {s}", .{ self, name, try definitionOf(arena, envelope), start.written() }),
        .pre_start = pull,
        .stop = stop,
    };
    return .{
        .start = start.written(),
        .pre_start = pull,
        .stop = stop,
        .post_stop = try std.fmt.allocPrint(arena, "container delete --force {s}", .{name}),
    };
}

pub fn xpcExecSet(arena: Allocator, io: Io, envelope: Envelope) !ExecSet {
    if (envelope.service.image == null) return error.NoImage;
    return exec_set.build(arena, io, envelope.service, envelope.grove, try definitionOf(arena, envelope), keeps(envelope.service));
}

pub fn explain(refusal: Refusal, service: Service, w: *Io.Writer) Io.Writer.Error!void {
    switch (refusal) {
        error.NoRunCommand => try w.print("service '{s}' is host-mode but has no RUN command\n", .{service.name}),
        error.NoImage => try w.print("service '{s}' is container-mode but has no FROM image\n", .{service.name}),
    }
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn envelopeFor(arena: Allocator, service_json: []const u8) !Envelope {
    return Envelope.parse(arena, try std.fmt.allocPrint(arena,
        \\{{"contract":1,"grove":"orch","project_dir":"/proj","data_dir":"/d","state_dir":"/s","service":{s}}}
    , .{service_json}));
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
        \\ "volumes":[{"source":"/proj/pgdata","destination":"/data","is_named":false},{"source":"named-vol","destination":"/v","is_named":true,"read_only":true}],
        \\ "resources":{"memory":"512M","cpus":2.0}}
    );
    var always = e;
    always.service.recreate = .always;
    const set = try cliExecSet(a, always, "/x/self");
    try testing.expectEqualStrings(
        "container run --name orch-postgres --init --env ALPHA=1 --env FOO=bar" ++
            " --volume /proj/pgdata:/data --volume named-vol:/v:ro" ++
            " --publish 8080:80 --publish 127.0.0.1:5432:5432 --memory 512M --cpus 2 postgres:15",
        set.start,
    );
    try testing.expectEqualStrings("container image pull postgres:15", set.pre_start.?);
    try testing.expectEqualStrings("container stop orch-postgres", set.stop.?);
    try testing.expectEqualStrings("container delete --force orch-postgres", set.post_stop.?);
}

test "with RECREATE always, the xpc mode drives this binary over XPC and deletes on stop" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const set = try xpcExecSet(a, testing.io, try envelopeFor(a,
        \\{"name":"postgres","mode":"container","image":"postgres:15","recreate":"always"}
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
    try testing.expectEqual(.host, host.service.mode);
    const set = try hostExecSet(host.service);
    try testing.expectEqualStrings("/usr/bin/nginx", set.start);
    try testing.expectEqualStrings("kill -HUP $MAINPID", set.reload.?);
    try testing.expectError(error.NoRunCommand, hostExecSet((try envelopeFor(a,
        \\{"name":"web","mode":"host"}
    )).service));
    try testing.expectError(error.NoImage, cliExecSet(a, try envelopeFor(a,
        \\{"name":"db","mode":"container"}
    ), "/x/self"));
}

test "with RECREATE never, the cli mode keeps the container and wakes it by its definition" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e = try envelopeFor(a,
        \\{"name":"db","mode":"container","image":"postgres:16","env":{"A":"1"}}
    );
    const set = try cliExecSet(a, e, "/x/self");
    const definition = try definitionOf(a, e);
    try testing.expectEqual(64, definition.len);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "'/x/self' cli-start orch-db {s} -- container run --name orch-db --init --env A=1 postgres:16", .{definition}), set.start);
    try testing.expectEqualStrings("container stop orch-db", set.stop.?);
    try testing.expectEqual(null, set.post_stop);

    var always = e;
    always.service.recreate = .always;
    try testing.expectEqualStrings(definition, try definitionOf(a, always));
    var changed = e;
    changed.service.image = "postgres:17";
    try testing.expect(!std.mem.eql(u8, definition, try definitionOf(a, changed)));
}

test "with RECREATE never, the xpc mode asks run to keep, and does not delete on stop" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const set = try xpcExecSet(a, testing.io, try envelopeFor(a,
        \\{"name":"db","mode":"container","image":"postgres:16"}
    ));
    try testing.expect(std.mem.indexOf(u8, set.start, " --definition ") != null);
    try testing.expect(std.mem.indexOf(u8, set.start, " --keep && ") != null);
    try testing.expectEqual(null, set.post_stop);
}

test "the definition hashes what it hashed before, so a kept container still matches after an upgrade" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const full = try Envelope.parse(a,
        \\{"contract":1,"grove":"orch","project_dir":"/proj","data_dir":"/d","state_dir":"/s","service":{"name":"db","mode":"container",
        \\ "image":"postgres:16","entrypoint":"docker-entrypoint.sh","cmd":"postgres -c fsync=off",
        \\ "publish":[{"address":"127.0.0.1","host":5432,"container":5432}],
        \\ "volumes":[{"source":"pgdata","destination":"/var/lib/postgresql/data","is_named":true}],
        \\ "user":"999","workdir":"/w","env":{"B":"2","A":"1"},"env_files":[".env"],"requires":["x"],"oneshot":false,"disabled":false,
        \\ "recreate":"always","restart":{"policy":"always"},"timeouts":{},"resources":{"memory":"1G","cpus":2,"limit_nofile":4096,"tasks_max":64},"logging":{}}}
    );
    try testing.expectEqualStrings("905274701f6e889d0bb7b325bd538ec907fd662110cfbe8b68f4b496c3d709e0", try definitionOf(a, full));
    const least = try Envelope.parse(a,
        \\{"contract":1,"grove":"orch","project_dir":"/proj","data_dir":"/d","state_dir":"/s","service":{"name":"web","mode":"container","image":"nginx:alpine","env":{}}}
    );
    try testing.expectEqualStrings("5ed4a750c174fed6f46bb5b366222a6d6f2c6c4dafac3b351ec9d0014d4ee34e", try definitionOf(a, least));
}

test "the xpc mode carries ports, and volume sources resolved against the project" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const set = try xpcExecSet(a, testing.io, try envelopeFor(a,
        \\{"name":"web","mode":"container","image":"nginx:alpine","publish":[{"address":"127.0.0.1","host":18081,"container":80}],
        \\ "volumes":[{"source":"/proj/site","destination":"/srv","is_named":false},{"source":"store","destination":"/data","is_named":true}]}
    ));
    const at = std.mem.indexOf(u8, set.start, " --spec ").? + " --spec ".len;
    const b64 = set.start[at .. std.mem.indexOfScalarPos(u8, set.start, at, ' ') orelse set.start.len];
    const json = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(b64));
    try std.base64.standard.Decoder.decode(json, b64);
    const spec = try std.json.parseFromSliceLeaky(Service, a, json, .{ .ignore_unknown_fields = true });
    try testing.expectEqualStrings("/proj/site", spec.volumes[0].source);
    try testing.expectEqualStrings("store", spec.volumes[1].source);
    try testing.expectEqual(18081, spec.publish[0].host);
}
