const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const testing = std.testing;
const types = @import("types.zig");
const Config = @import("config.zig").Config;
const exe = @import("exe.zig");
const Service = types.Service;
const ExecSet = types.ExecSet;
const Diagnostic = types.Diagnostic;

pub const contract: u32 = 1;

pub const Rootstock = union(enum) {
    apple: Apple,
    external: External,

    pub fn name(r: Rootstock) []const u8 {
        return switch (r) {
            .apple => "apple",
            .external => |e| e.name,
        };
    }

    pub fn check(r: Rootstock, arena: Allocator, io: Io, diag: *Diagnostic) !void {
        return switch (r) {
            inline else => |s| s.check(arena, io, diag),
        };
    }

    pub fn prepare(r: Rootstock, arena: Allocator, io: Io, service: Service, diag: *Diagnostic) !void {
        return switch (r) {
            inline else => |s| s.prepare(arena, io, service, diag),
        };
    }

    pub fn execSet(r: Rootstock, arena: Allocator, io: Io, service: Service, diag: *Diagnostic) !ExecSet {
        return switch (r) {
            inline else => |s| s.execSet(arena, io, service, diag),
        };
    }
};

pub fn create(arena: Allocator, io: Io, environ: *const Environ.Map, config: Config, log: *Io.Writer, diag: *Diagnostic) !Rootstock {
    const path_var = environ.get("PATH") orelse "";
    const beside = exe.selfDir(arena, io);
    if (std.mem.eql(u8, config.rootstock, "apple")) {
        return .{ .apple = try Apple.init(arena, io, environ, config, beside, log, diag) };
    }
    const file = try pluginName(arena, config.rootstock);
    const bin = try exe.find(arena, io, file, beside, path_var) orelse {
        diag.set(arena, "binary not found: {s} beside orchd or on PATH (built in: apple)", .{file});
        return error.RootstockNotFound;
    };
    return .{ .external = .{ .name = config.rootstock, .bin = bin, .config = config } };
}

pub fn pluginName(arena: Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "orchd-rootstock-{s}", .{name});
}

pub const External = struct {
    name: []const u8,
    bin: []const u8,
    config: Config,

    const Envelope = struct {
        contract: u32,
        grove: []const u8,
        project_dir: []const u8,
        data_dir: []const u8,
        state_dir: []const u8,
        service: Service,
    };

    fn call(e: External, arena: Allocator, io: Io, verb: []const u8, service: ?Service, diag: *Diagnostic) ![]const u8 {
        const plugin = try pluginName(arena, e.name);
        const input = if (service) |s| try std.json.Stringify.valueAlloc(arena, Envelope{
            .contract = contract,
            .grove = e.config.grove,
            .project_dir = e.config.project_dir,
            .data_dir = e.config.data_dir,
            .state_dir = e.config.state_dir,
            .service = s,
        }, .{ .emit_null_optional_fields = false }) else "";
        const out = exe.communicate(arena, io, &.{ e.bin, verb }, input) catch |err| {
            diag.set(arena, "{s} {s}: {t}", .{ plugin, verb, err });
            return error.RootstockFailed;
        };
        if (!out.ok()) {
            diag.set(arena, "{s} {s} failed: {s}", .{ plugin, verb, out.reason() });
            return error.RootstockFailed;
        }
        return out.stdout;
    }

    pub fn check(e: External, arena: Allocator, io: Io, diag: *Diagnostic) !void {
        const spoken = try e.call(arena, io, "contract", null, diag);
        var versions = std.mem.tokenizeAny(u8, spoken, " \t\r\n");
        while (versions.next()) |v| {
            if (std.fmt.parseInt(u32, v, 10) catch null == contract) break;
        } else {
            diag.set(arena, "{s} speaks contract {s}, orchd needs {d}", .{
                try pluginName(arena, e.name),
                std.mem.trim(u8, spoken, " \t\r\n"),
                contract,
            });
            return error.ContractMismatch;
        }
        _ = try e.call(arena, io, "check", null, diag);
    }

    pub fn prepare(e: External, arena: Allocator, io: Io, service: Service, diag: *Diagnostic) !void {
        _ = try e.call(arena, io, "prepare", service, diag);
    }

    pub fn execSet(e: External, arena: Allocator, io: Io, service: Service, diag: *Diagnostic) !ExecSet {
        const out = try e.call(arena, io, "exec-set", service, diag);
        return std.json.parseFromSliceLeaky(ExecSet, arena, out, .{ .ignore_unknown_fields = true }) catch |err| {
            diag.set(arena, "{s} exec-set: not an ExecSet: {t}", .{ try pluginName(arena, e.name), err });
            return error.RootstockFailed;
        };
    }
};

pub const AppleMode = enum {
    container_cli,
    orchd_apple,

    pub fn parse(s: []const u8) ?AppleMode {
        const t = std.mem.trim(u8, s, " \t\r\n");
        const table = [_]struct { []const u8, AppleMode }{
            .{ "container", .container_cli }, .{ "cli", .container_cli },
            .{ "xpc", .orchd_apple },         .{ "daemon", .orchd_apple },
            .{ "apple", .orchd_apple },       .{ "orchd-apple", .orchd_apple },
            .{ "", .orchd_apple },
        };
        for (table) |entry| {
            if (std.ascii.eqlIgnoreCase(t, entry[0])) return entry[1];
        }
        return null;
    }

    pub fn binary(mode: AppleMode) ?struct { file: []const u8, env: []const u8 } {
        return switch (mode) {
            .container_cli => null,
            .orchd_apple => .{ .file = "orchd-apple", .env = "ORCHD_APPLE_BIN" },
        };
    }
};

pub const Apple = struct {
    mode: AppleMode,
    bin: ?[]const u8,
    grove: []const u8,
    data_dir: []const u8,
    project_dir: []const u8,

    fn init(arena: Allocator, io: Io, environ: *const Environ.Map, config: Config, beside: ?[]const u8, log: *Io.Writer, diag: *Diagnostic) !Apple {
        const wanted = environ.get("ORCHD_APPLE_MODE") orelse "";
        if (movedToApplz(wanted)) {
            diag.set(arena, "ORCHD_APPLE_MODE={s} is now applz, its own runtime (https://github.com/adiled/applz): install it and use --rootstock applz", .{wanted});
            return error.MovedToApplz;
        }
        const mode = AppleMode.parse(wanted) orelse blk: {
            try log.print("warning: unknown ORCHD_APPLE_MODE '{s}', using 'xpc' (orchd-apple)\n", .{wanted});
            break :blk .orchd_apple;
        };
        const bin: ?[]const u8 = if (mode.binary()) |b|
            environ.get(b.env) orelse (try exe.find(arena, io, b.file, beside, "")) orelse b.file
        else
            null;
        return .{ .mode = mode, .bin = bin, .grove = config.grove, .data_dir = config.data_dir, .project_dir = config.project_dir };
    }

    fn containerName(a: Apple, arena: Allocator, service: Service) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s}-{s}", .{ a.grove, service.name });
    }

    fn call(a: Apple, arena: Allocator, io: Io, subcommand: []const u8, input: ?[]const u8, diag: *Diagnostic) ![]const u8 {
        const bin = a.bin.?;
        const out = exe.communicate(arena, io, &.{ bin, subcommand, a.grove }, input) catch |err| {
            diag.set(arena, "binary not found: could not spawn '{s}': {t}", .{ bin, err });
            return error.RootstockFailed;
        };
        if (!out.ok()) {
            diag.set(arena, "{s} {s} failed (exit {d}): {s}", .{ bin, subcommand, out.code(), out.reason() });
            return error.RootstockFailed;
        }
        return out.stdout;
    }

    fn container(arena: Allocator, io: Io, argv: []const []const u8, diag: *Diagnostic) !bool {
        const out = exe.communicate(arena, io, argv, null) catch |err| {
            diag.set(arena, "binary not found: could not spawn 'container': {t}", .{err});
            return error.RootstockFailed;
        };
        return out.ok();
    }

    fn requireImage(arena: Allocator, service: Service, diag: *Diagnostic) ![]const u8 {
        return service.image orelse {
            diag.set(arena, "service '{s}' is container-mode but has no FROM image", .{service.name});
            return error.NoImage;
        };
    }

    pub fn volumeSource(a: Apple, arena: Allocator, vol: types.VolumeMount) ![]const u8 {
        if (vol.is_named or std.fs.path.isAbsolute(vol.source)) return vol.source;
        return std.fs.path.join(arena, &.{ a.project_dir, vol.source });
    }

    pub fn check(a: Apple, arena: Allocator, io: Io, diag: *Diagnostic) !void {
        switch (a.mode) {
            .container_cli => if (!try container(arena, io, &.{ "container", "ls" }, diag)) {
                diag.set(arena, "container CLI/daemon not reachable (run: container system start)", .{});
                return error.RootstockFailed;
            },
            .orchd_apple => _ = try a.call(arena, io, "check", null, diag),
        }
    }

    pub fn prepare(a: Apple, arena: Allocator, io: Io, service: Service, diag: *Diagnostic) !void {
        if (service.mode == .host) {
            const dir = try std.fs.path.join(arena, &.{ a.data_dir, service.name });
            Io.Dir.cwd().createDirPath(io, dir) catch |err| {
                diag.set(arena, "failed to create data directory '{s}': {t}", .{ dir, err });
                return error.RootstockFailed;
            };
            return;
        }
        switch (a.mode) {
            .container_cli => {
                const image = try requireImage(arena, service, diag);
                if (!try container(arena, io, &.{ "container", "image", "pull", image }, diag)) {
                    diag.set(arena, "container image pull {s} failed", .{image});
                    return error.RootstockFailed;
                }
            },
            .orchd_apple => _ = try a.call(arena, io, "prepare", try serviceJson(arena, service), diag),
        }
    }

    pub fn execSet(a: Apple, arena: Allocator, io: Io, service: Service, diag: *Diagnostic) !ExecSet {
        if (service.mode == .host) {
            return .{
                .start = service.run_command orelse {
                    diag.set(arena, "service '{s}' is host-mode but has no RUN command", .{service.name});
                    return error.NoRunCommand;
                },
                .stop = service.stop_command,
                .reload = service.reload_command,
            };
        }
        switch (a.mode) {
            .container_cli => return a.cliExecSet(arena, service, diag),
            .orchd_apple => {
                const out = try a.call(arena, io, "exec-set", try serviceJson(arena, service), diag);
                return std.json.parseFromSliceLeaky(ExecSet, arena, out, .{ .ignore_unknown_fields = true }) catch |err| {
                    diag.set(arena, "failed to deserialize ExecSet from co-process: {t}\nraw: {s}", .{ err, out });
                    return error.RootstockFailed;
                };
            },
        }
    }

    fn cliExecSet(a: Apple, arena: Allocator, service: Service, diag: *Diagnostic) !ExecSet {
        const image = try requireImage(arena, service, diag);
        const name = try a.containerName(arena, service);
        var start: Io.Writer.Allocating = .init(arena);
        const w = &start.writer;
        try w.print("container run --name {s} --init", .{name});

        const keys = try arena.dupe([]const u8, service.env.map.keys());
        std.mem.sort([]const u8, keys, {}, lessThan);
        for (keys) |k| try w.print(" --env {s}={s}", .{ k, service.env.map.get(k).? });
        for (service.env_files) |ef| try w.print(" --env-file {s}", .{ef});
        for (service.volumes) |vol| try w.print(" --volume {s}:{s}", .{ try a.volumeSource(arena, vol), vol.destination });
        for (service.publish) |p| {
            if (p.address) |addr| {
                try w.print(" --publish {s}:{d}:{d}", .{ addr, p.host, p.container });
            } else {
                try w.print(" --publish {d}:{d}", .{ p.host, p.container });
            }
        }
        if (service.resources.memory) |mem| try w.print(" --memory {s}", .{mem});
        if (service.resources.cpus) |cpus| try w.print(" --cpus {d}", .{cpus});
        if (service.user) |user| try w.print(" --user {s}", .{user});
        if (service.workdir) |wd| try w.print(" --workdir {s}", .{wd});
        if (service.entrypoint) |ep| try w.print(" --entrypoint {s}", .{ep});
        try w.print(" {s}", .{image});
        if (service.cmd) |cmd| try w.print(" {s}", .{cmd});

        return .{
            .start = start.written(),
            .pre_start = try std.fmt.allocPrint(arena, "container image pull {s}", .{image}),
            .stop = try std.fmt.allocPrint(arena, "container stop {s}", .{name}),
            .post_stop = try std.fmt.allocPrint(arena, "container delete --force {s}", .{name}),
        };
    }
};

fn movedToApplz(mode: []const u8) bool {
    const t = std.mem.trim(u8, mode, " \t\r\n");
    for ([_][]const u8{ "osx", "vz", "orchd-osx" }) |old| {
        if (std.ascii.eqlIgnoreCase(t, old)) return true;
    }
    return false;
}

fn serviceJson(arena: Allocator, service: Service) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, service, .{ .emit_null_optional_fields = false });
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn testApple(mode: AppleMode) Apple {
    return .{ .mode = mode, .bin = null, .grove = "orch", .data_dir = "/nonexistent/data", .project_dir = "/proj" };
}

test "apple modes read from ORCHD_APPLE_MODE, any case" {
    try testing.expectEqual(.container_cli, AppleMode.parse("container"));
    try testing.expectEqual(.container_cli, AppleMode.parse("cli"));
    try testing.expectEqual(.orchd_apple, AppleMode.parse("xpc"));
    try testing.expectEqual(.orchd_apple, AppleMode.parse("daemon"));
    try testing.expectEqual(.orchd_apple, AppleMode.parse(""));
    try testing.expectEqual(null, AppleMode.parse("osx"));
    try testing.expect(movedToApplz("OSX"));
    try testing.expect(movedToApplz("vz"));
    try testing.expect(!movedToApplz("xpc"));
    try testing.expectEqual(null, AppleMode.parse("bogus"));
    try testing.expectEqual(null, AppleMode.binary(.container_cli));
    try testing.expectEqualStrings("ORCHD_APPLE_BIN", AppleMode.binary(.orchd_apple).?.env);
}

test "the container CLI mode spells out the whole container" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var service: Service = .{ .name = "postgres", .mode = .container, .image = "postgres:15" };
    try service.env.map.put(a, "FOO", "bar");
    try service.env.map.put(a, "ALPHA", "1");
    service.publish = &.{ .{ .host = 8080, .container = 80 }, .{ .address = "127.0.0.1", .host = 5432, .container = 5432 } };
    service.volumes = &.{ .{ .source = "./pgdata", .destination = "/data", .is_named = false }, .{ .source = "named-vol", .destination = "/v", .is_named = true } };
    service.resources = .{ .memory = "512M", .cpus = 2.0 };
    var diag: Diagnostic = .{};
    const set = try testApple(.container_cli).execSet(a, testing.io, service, &diag);
    try testing.expectEqualStrings(
        "container run --name orch-postgres --init --env ALPHA=1 --env FOO=bar" ++
            " --volume /proj/./pgdata:/data --volume named-vol:/v" ++
            " --publish 8080:80 --publish 127.0.0.1:5432:5432 --memory 512M --cpus 2 postgres:15",
        set.start,
    );
    try testing.expectEqualStrings("container image pull postgres:15", set.pre_start.?);
    try testing.expectEqualStrings("container stop orch-postgres", set.stop.?);
    try testing.expectEqualStrings("container delete --force orch-postgres", set.post_stop.?);

    service.resources.cpus = 1.5;
    const half = try testApple(.container_cli).execSet(a, testing.io, service, &diag);
    try testing.expect(std.mem.indexOf(u8, half.start, " --cpus 1.5 ") != null);
}

test "a host service under apple runs as it would bare" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const set = try testApple(.container_cli).execSet(arena.allocator(), testing.io, .{
        .name = "web",
        .mode = .host,
        .run_command = "/usr/bin/nginx",
        .reload_command = "kill -HUP $MAINPID",
    }, &diag);
    try testing.expectEqualStrings("/usr/bin/nginx", set.start);
    try testing.expectEqual(null, set.pre_start);
    try testing.expectEqualStrings("kill -HUP $MAINPID", set.reload.?);
}

test "volume sources anchor relative paths to the project, nothing else" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const apple = testApple(.container_cli);
    try testing.expectEqualStrings("/proj/../up", try apple.volumeSource(a, .{ .source = "../up", .destination = "/d", .is_named = false }));
    try testing.expectEqualStrings("/var/lib/pg", try apple.volumeSource(a, .{ .source = "/var/lib/pg", .destination = "/d", .is_named = false }));
    try testing.expectEqualStrings("pgdata", try apple.volumeSource(a, .{ .source = "pgdata", .destination = "/d", .is_named = true }));
}

fn fakePlugin(arena: Allocator, dir: Io.Dir, root: []const u8, body: []const u8) ![]const u8 {
    try dir.writeFile(testing.io, .{ .sub_path = "draft", .data = try std.fmt.allocPrint(arena, "#!/bin/sh\n{s}\n", .{body}) });
    const path = try std.fs.path.join(arena, &.{ root, "orchd-rootstock-fake" });
    const draft = try std.fs.path.join(arena, &.{ root, "draft" });
    const out = try exe.communicate(arena, testing.io, &.{ "/bin/sh", "-c", "cp \"$0\" \"$1\" && chmod 755 \"$1\"", draft, path }, null);
    try testing.expect(out.ok());
    return path;
}

fn fakeExternal(bin: []const u8, root: []const u8) External {
    var config = @import("config.zig").forTest(root);
    config.grove = "g";
    config.project_dir = "/proj";
    config.data_dir = "/data";
    return .{ .name = "fake", .bin = bin, .config = config };
}

test "a plugin gets the envelope on stdin and answers with an exec set" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const seen = try std.fs.path.join(a, &.{ root, "envelope.json" });
    const bin = try fakePlugin(a, tmp.dir, root, try std.fmt.allocPrint(a,
        \\case "$1" in
        \\  contract) echo 1 ;;
        \\  check) exit 0 ;;
        \\  exec-set) cat > {s}; echo '{{"start":"fake run web","stop":null}}' ;;
        \\esac
    , .{seen}));
    const plugin: Rootstock = .{ .external = fakeExternal(bin, root) };
    var diag: Diagnostic = .{};
    try plugin.check(a, testing.io, &diag);
    const set = try plugin.execSet(a, testing.io, .{ .name = "web", .mode = .host, .run_command = "sleep 1" }, &diag);
    try testing.expectEqualStrings("fake run web", set.start);
    try testing.expectEqual(null, set.stop);

    const envelope = try std.json.parseFromSliceLeaky(std.json.Value, a, try tmp.dir.readFileAlloc(testing.io, "envelope.json", a, .limited(1 << 16)), .{});
    try testing.expectEqual(1, envelope.object.get("contract").?.integer);
    try testing.expectEqualStrings("g", envelope.object.get("grove").?.string);
    try testing.expectEqualStrings("/proj", envelope.object.get("project_dir").?.string);
    const service = envelope.object.get("service").?.object;
    try testing.expectEqualStrings("web", service.get("name").?.string);
    try testing.expectEqualStrings("host", service.get("mode").?.string);
    try testing.expectEqual(null, service.get("image"));
}

test "a plugin that speaks another contract is refused by name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const plugin: Rootstock = .{ .external = fakeExternal(try fakePlugin(a, tmp.dir, root, "echo 2"), root) };
    var diag: Diagnostic = .{};
    try testing.expectError(error.ContractMismatch, plugin.check(a, testing.io, &diag));
    try testing.expectEqualStrings("orchd-rootstock-fake speaks contract 2, orchd needs 1", diag.message);
}

test "a failing verb carries the plugin's own reason, even unread" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const plugin: Rootstock = .{ .external = fakeExternal(try fakePlugin(a, tmp.dir, root, "echo 'no image for web' >&2; exit 3"), root) };
    var diag: Diagnostic = .{};
    try testing.expectError(error.RootstockFailed, plugin.prepare(a, testing.io, .{ .name = "web", .mode = .host }, &diag));
    try testing.expectEqualStrings("orchd-rootstock-fake prepare failed: no image for web", diag.message);
}
