const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const posix = std.posix;
const testing = std.testing;
const build_options = @import("build_options");
const types = @import("types.zig");
const Config = @import("config.zig").Config;
const supervise = @import("supervise.zig");
const spec_mod = @import("spec.zig");
const rootstock = @import("rootstock.zig");
const bed = @import("bed.zig");
const keeper = @import("keeper.zig");
const Platform = @import("platform.zig").Platform;
const launchd = @import("platform/launchd.zig");
const orchdi = @import("platform/orchdi.zig");
const systemd = @import("platform/systemd.zig");
const Diagnostic = types.Diagnostic;
const Service = types.Service;
const Spec = types.Spec;

pub const Engine = struct {
    arena: Allocator,
    io: Io,
    environ: *const Environ.Map,
    config: Config,
    platform: Platform,
    log: *Io.Writer,
    diag: *Diagnostic,
    spec: ?Spec = null,

    pub fn init(arena: Allocator, io: Io, environ: *const Environ.Map, config: Config, log: *Io.Writer, diag: *Diagnostic) !Engine {
        const platform = Platform.parse(config.platform) orelse {
            diag.set(arena, "unknown platform '{s}' (launchd, systemd, orchdi)", .{config.platform});
            return error.UnknownPlatform;
        };
        return .{ .arena = arena, .io = io, .environ = environ, .config = config, .platform = platform, .log = log, .diag = diag };
    }

    fn say(e: Engine, comptime fmt: []const u8, args: anytype) !void {
        if (!e.config.quiet) try e.log.print(fmt ++ "\n", args);
    }

    fn warn(e: Engine, comptime fmt: []const u8, args: anytype) !void {
        try e.log.print("warning: " ++ fmt ++ "\n", args);
    }

    fn parsed(e: *Engine) !Spec {
        if (e.spec) |s| return s;
        e.spec = try spec_mod.parse(e.arena, e.io, e.environ, e.config, e.log, e.diag);
        return e.spec.?;
    }

    fn checkServices(e: *Engine, names: []const []const u8) !void {
        if (names.len == 0) return;
        const spec = try e.parsed();
        var unknown: std.ArrayList([]const u8) = .empty;
        for (names) |n| if (spec.find(n) == null) try unknown.append(e.arena, n);
        if (unknown.items.len > 0) {
            e.diag.set(e.arena, "no service named {s} in {s}", .{ try std.mem.join(e.arena, ", ", unknown.items), e.config.orchfile });
            return error.UnknownService;
        }
    }

    pub fn generate(e: *Engine, force: bool, strict: bool) !void {
        if (!force and !strict and e.upToDate()) {
            try e.say("artifacts up to date, skipping generate (use --force to override)", .{});
            return;
        }
        const spec = try e.parsed();
        try e.say("parsed {d} services (orch v{s})", .{ spec.services.len, spec.version });

        var stock = try rootstock.create(e.arena, e.io, e.environ, e.config, e.diag);
        try stock.check(e.arena, e.io, e.diag);
        try e.say("rootstock: {s}", .{stock.name});

        var planted: std.ArrayList(types.Planted) = .empty;
        var skipped: std.ArrayList([]const u8) = .empty;
        for (spec.services) |service| {
            try e.lint(service);
            var why: Diagnostic = .{};
            stock.prepare(e.arena, e.io, service, &why) catch {
                try skipped.append(e.arena, try std.fmt.allocPrint(e.arena, "{s}: {s}", .{ service.name, why.message }));
                continue;
            };
            const set = stock.execSet(e.arena, e.io, service, &why) catch {
                try skipped.append(e.arena, try std.fmt.allocPrint(e.arena, "{s}: {s}", .{ service.name, why.message }));
                continue;
            };
            if (e.config.verbose) try e.log.print("  exec: {s} -> {s}\n", .{ service.name, set.start });
            if (service.reload_command != null and set.reload == null) {
                try e.warn("service '{s}': rootstock '{s}' gives no reload for RELOAD; ignoring", .{ service.name, e.config.rootstock });
            }
            try planted.append(e.arena, .{ .service = service, .set = set });
        }

        if (skipped.items.len > 0) {
            const summary = try std.fmt.allocPrint(e.arena, "{d} service(s) skipped (rootstock incompatible):\n  {s}", .{
                skipped.items.len,
                try std.mem.join(e.arena, "\n  ", skipped.items),
            });
            if (strict) {
                e.diag.set(e.arena, "service(s) skipped:\n{s}", .{summary});
                return error.ServiceSkipped;
            }
            try e.warn("{s}", .{summary});
        }

        var disabled: usize = 0;
        for (planted.items) |p| disabled += @intFromBool(p.service.disabled);
        try e.say("generating {d} units ({d} disabled)", .{ planted.items.len, disabled });

        try e.platform.check(e.arena, e.io, e.diag);
        try e.platform.prepareGround(e.arena, e.io, e.config);
        const written = try bed.plant(e.arena, e.io, try e.platform.beds(e.arena, e.io, e.config, spec.services, planted.items, e.log));
        for (written) |path| try e.say("  wrote: {s}", .{path});
        try e.platform.install(e.arena, e.io, e.config, e.diag);
        try e.say("installed {d} units", .{written.len});
        e.writeStamp(spec) catch {};
    }

    pub fn up(e: *Engine, names: []const []const u8, strict: bool, force: bool) !void {
        try e.generate(force, strict);
        try e.checkServices(names);
        if (names.len == 0) {
            try e.say("starting all services...", .{});
        } else {
            try e.say("starting: {s}", .{try std.mem.join(e.arena, ", ", names)});
        }
        try e.platform.start(e.arena, e.io, e.config, names, e.diag);
        try e.say("started", .{});
    }

    pub fn grow(e: *Engine, names: []const []const u8, no_start: bool, strict: bool, force: bool, reload: bool) !void {
        if (no_start) return e.generate(force, strict);
        if (reload) {
            try e.generate(force, strict);
            return e.reloadTrees(names);
        }
        return e.up(names, strict, force);
    }

    pub fn reloadTrees(e: *Engine, names: []const []const u8) !void {
        try e.checkServices(names);
        const spec = try e.parsed();
        var stock = try rootstock.create(e.arena, e.io, e.environ, e.config, e.diag);
        try stock.check(e.arena, e.io, e.diag);

        var done: std.ArrayList([]const u8) = .empty;
        for (spec.services) |service| {
            if (names.len > 0 and !contains(names, service.name)) continue;
            var why: Diagnostic = .{};
            const set = stock.execSet(e.arena, e.io, service, &why) catch |err| {
                if (names.len == 0) continue;
                e.diag.* = why;
                return err;
            };
            const cmd = set.reload orelse {
                if (names.len == 0) continue;
                e.diag.set(e.arena, "{s} has no RELOAD", .{service.name});
                return error.NoReload;
            };
            const label = try supervise.serviceLabel(e.arena, e.config, service.name);
            switch (e.platform) {
                .launchd => {
                    const pid: posix.pid_t = @intCast(try launchd.pidOf(e.arena, e.io, e.config, label) orelse return e.notRunning(service.name));
                    const deps = try supervise.buildDepGates(e.arena, e.config, service, spec.services);
                    if (supervise.needsKeeper(deps, set)) {
                        try e.hup(pid, service.name);
                    } else {
                        keeper.runReload(e.arena, e.io, e.environ, cmd, pid, service.env, supervise.hostWorkdir(service), &why) catch |err| {
                            e.diag.set(e.arena, "{s}: {s}", .{ service.name, why.message });
                            return err;
                        };
                    }
                },
                .orchdi => try e.hup(try orchdi.keeperPid(e.arena, e.io, e.config, label) orelse return e.notRunning(service.name), service.name),
                .systemd => try systemd.reload(e.arena, e.io, e.config, service.name, e.diag),
            }
            try done.append(e.arena, service.name);
        }
        if (done.items.len == 0) {
            try e.say("no running tree has a RELOAD", .{});
        } else {
            try e.say("reloaded: {s}", .{try std.mem.join(e.arena, ", ", done.items)});
        }
    }

    fn notRunning(e: Engine, name: []const u8) error{NotRunning} {
        e.diag.set(e.arena, "{s} is not running, so there is nothing to reload", .{name});
        return error.NotRunning;
    }

    fn hup(e: Engine, pid: posix.pid_t, name: []const u8) !void {
        posix.kill(pid, .HUP) catch |err| {
            e.diag.set(e.arena, "{s}: {t}", .{ name, err });
            return error.ReloadFailed;
        };
    }

    pub fn fell(e: *Engine, names: []const []const u8, keep_data: bool) !void {
        if (names.len == 0) return e.clean(keep_data);
        try e.checkServices(names);
        var ignored: Diagnostic = .{};
        e.platform.stop(e.arena, e.io, e.config, names, &ignored) catch {};
        try e.platform.remove(e.arena, e.io, e.config, names);
        e.dropStamp();
        try e.uproot(names);
        if (!keep_data) {
            for (names) |n| Io.Dir.cwd().deleteTree(e.io, try std.fs.path.join(e.arena, &.{ e.config.data_dir, n })) catch {};
        }
        try e.say("felled: {s}", .{try std.mem.join(e.arena, ", ", names)});
    }

    pub fn clean(e: *Engine, keep_data: bool) !void {
        var ignored: Diagnostic = .{};
        e.platform.stop(e.arena, e.io, e.config, &.{}, &ignored) catch {};
        try e.platform.clean(e.arena, e.io, e.config);
        e.dropStamp();
        try e.say("removed generated units", .{});
        try e.uproot(&.{});
        if (keep_data) return;
        const cwd = Io.Dir.cwd();
        cwd.access(e.io, e.config.data_dir, .{}) catch return;
        cwd.deleteTree(e.io, e.config.data_dir) catch {};
        try e.say("removed data directory: {s}", .{e.config.data_dir});
    }

    fn uproot(e: *Engine, names: []const []const u8) !void {
        const spec = e.parsed() catch {
            try e.warn("the Orchfile could not be read, so the rootstock was not asked to remove what it keeps", .{});
            return;
        };
        var why: Diagnostic = .{};
        var stock = rootstock.create(e.arena, e.io, e.environ, e.config, &why) catch return e.warn("{s}", .{why.message});
        stock.check(e.arena, e.io, &why) catch return e.warn("{s}", .{why.message});
        if (!stock.removes) return;
        for (spec.services) |service| {
            if (names.len > 0 and !contains(names, service.name)) continue;
            stock.remove(e.arena, e.io, service, &why) catch try e.warn("{s}: {s}", .{ service.name, why.message });
        }
    }

    pub fn status(e: *Engine, out: *Io.Writer, as_json: bool) !void {
        try e.platform.status(e.arena, e.io, e.config, out, as_json, e.diag);
    }

    pub fn logs(e: *Engine, service: []const u8, follow: bool, lines: u32) !void {
        try e.platform.logs(e.arena, e.io, e.config, service, follow, lines, e.diag);
    }

    fn lint(e: Engine, service: Service) !void {
        if (e.platform == .launchd) {
            var dropped: std.ArrayList([]const u8) = .empty;
            const r = service.resources;
            if (r.cpus != null) try dropped.append(e.arena, "CPUS");
            if (r.cpu_quota != null) try dropped.append(e.arena, "CPU_QUOTA");
            if (r.tasks_max != null) try dropped.append(e.arena, "TASKS_MAX");
            if (r.io_weight != null) try dropped.append(e.arena, "IO_WEIGHT");
            if (service.timeouts.start != null) try dropped.append(e.arena, "TIMEOUT_START");
            if (service.restart.start_limit_burst != null) try dropped.append(e.arena, "START_LIMIT_BURST");
            if (service.restart.start_limit_interval != null) try dropped.append(e.arena, "START_LIMIT_INTERVAL");
            if (dropped.items.len > 0) {
                try e.warn("service '{s}': {s} not supported on launchd; ignoring", .{ service.name, try std.mem.join(e.arena, ", ", dropped.items) });
            }
        }
        if (service.resources.memory) |mem| {
            if (supervise.parseMemoryBytes(mem) == null) {
                try e.warn("service '{s}': MEMORY '{s}' is not a valid size (grammar: integer followed by K, M or G)", .{ service.name, mem });
            }
        }
        const durations = [_]struct { []const u8, ?[]const u8 }{
            .{ "RESTART_DELAY", service.restart.delay },
            .{ "START_LIMIT_INTERVAL", service.restart.start_limit_interval },
            .{ "TIMEOUT_START", service.timeouts.start },
            .{ "TIMEOUT_STOP", service.timeouts.stop },
            .{ "READINESS_TIMEOUT", service.readiness_timeout },
        };
        for (durations) |d| {
            const value = d[1] orelse continue;
            if (supervise.parseDurationSecs(value) == null) {
                try e.warn("service '{s}': {s} '{s}' is not a valid duration (grammar: integer followed by 's' or 'm')", .{ service.name, d[0], value });
            }
        }
    }

    const Input = struct { path: []const u8, mtime_ns: i64, size: u64 };
    const Stamp = struct { config_hash: u64, inputs: []const Input };

    fn stampPath(e: Engine) ![]const u8 {
        return std.fs.path.join(e.arena, &.{ try e.config.unitsDir(e.arena), try std.fmt.allocPrint(e.arena, ".{s}.orchd-stamp", .{e.config.grove}) });
    }

    fn dropStamp(e: Engine) void {
        Io.Dir.cwd().deleteFile(e.io, e.stampPath() catch return) catch {};
    }

    fn configHash(e: Engine) !u64 {
        var h: std.hash.Wyhash = .init(0);
        const c = e.config;
        for ([_][]const u8{ build_options.version, c.rootstock, c.platform, c.grove, @tagName(c.scope), c.state_dir, c.project_dir, c.data_dir }) |part| {
            h.update(part);
            h.update("\x00");
        }
        for (c.args) |a| {
            h.update(a);
            h.update("\x00");
        }
        var sink: Io.Writer.Discarding = .init(&.{});
        const overrides = try spec_mod.overrides(e.arena, e.environ, c, &sink.writer);
        for (overrides.keys(), overrides.values()) |k, v| {
            h.update(k);
            h.update("=");
            h.update(v);
            h.update("\x00");
        }
        return h.final();
    }

    fn fingerprint(e: Engine, path: []const u8) ?Input {
        const stat = Io.Dir.cwd().statFile(e.io, path, .{}) catch return null;
        return .{ .path = path, .mtime_ns = @intCast(stat.mtime.nanoseconds), .size = stat.size };
    }

    fn writeStamp(e: Engine, spec: Spec) !void {
        var inputs: std.ArrayList(Input) = .empty;
        var sources: std.ArrayList([]const u8) = .empty;
        try sources.append(e.arena, e.config.orchfile);
        try sources.appendSlice(e.arena, e.config.overlays);
        for (spec.services) |s| try sources.appendSlice(e.arena, s.env_files);
        for (sources.items) |path| {
            const fp = e.fingerprint(path) orelse continue;
            for (inputs.items) |seen| {
                if (std.mem.eql(u8, seen.path, fp.path)) break;
            } else try inputs.append(e.arena, fp);
        }
        const units = try e.config.unitsDir(e.arena);
        try Io.Dir.cwd().createDirPath(e.io, units);
        try Io.Dir.cwd().writeFile(e.io, .{
            .sub_path = try e.stampPath(),
            .data = try std.json.Stringify.valueAlloc(e.arena, Stamp{ .config_hash = try e.configHash(), .inputs = inputs.items }, .{ .whitespace = .indent_2 }),
        });
    }

    fn upToDate(e: Engine) bool {
        const units = e.config.unitsDir(e.arena) catch return false;
        var dir = Io.Dir.cwd().openDir(e.io, units, .{ .iterate = true }) catch return false;
        defer dir.close(e.io);
        var it = dir.iterate();
        const has_artifacts = while (it.next(e.io) catch null) |entry| {
            if (std.mem.endsWith(u8, entry.name, ".plist") or std.mem.endsWith(u8, entry.name, ".service") or std.mem.endsWith(u8, entry.name, ".target")) break true;
        } else false;
        if (!has_artifacts) return false;

        const bytes = Io.Dir.cwd().readFileAlloc(e.io, e.stampPath() catch return false, e.arena, .limited(1 << 20)) catch return false;
        const stamp = std.json.parseFromSliceLeaky(Stamp, e.arena, bytes, .{}) catch return false;
        if (stamp.config_hash != (e.configHash() catch return false)) return false;
        for (stamp.inputs) |recorded| {
            const now = e.fingerprint(recorded.path) orelse return false;
            if (now.mtime_ns != recorded.mtime_ns or now.size != recorded.size) return false;
        }
        return true;
    }
};

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

test "the engine refuses a platform it does not know" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var environ: Environ.Map = .init(arena.allocator());
    var config = @import("config.zig").forTest("/s");
    config.platform = "upstart";
    var sink: Io.Writer.Discarding = .init(&.{});
    var diag: Diagnostic = .{};
    try testing.expectError(error.UnknownPlatform, Engine.init(arena.allocator(), testing.io, &environ, config, &sink.writer, &diag));
    try testing.expectEqualStrings("unknown platform 'upstart' (launchd, systemd, orchdi)", diag.message);
}

test "each grove keeps its own stamp, so groves sharing a state dir leave each other's alone" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var environ: Environ.Map = .init(a);
    var sink: Io.Writer.Discarding = .init(&.{});
    var diag: Diagnostic = .{};
    var config = @import("config.zig").forTest("/s");
    config.platform = "orchdi";
    config.grove = "shop";
    const shop = try Engine.init(a, testing.io, &environ, config, &sink.writer, &diag);
    config.grove = "blog";
    const blog = try Engine.init(a, testing.io, &environ, config, &sink.writer, &diag);
    try testing.expectEqualStrings("/s/units/.shop.orchd-stamp", try shop.stampPath());
    try testing.expectEqualStrings("/s/units/.blog.orchd-stamp", try blog.stampPath());
}
