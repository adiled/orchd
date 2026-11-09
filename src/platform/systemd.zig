const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const types = @import("../types.zig");
const Config = @import("../config.zig").Config;
const supervise = @import("../supervise.zig");
const exe = @import("../exe.zig");
const Service = types.Service;
const ExecSet = types.ExecSet;
const Diagnostic = types.Diagnostic;

pub const Bash = struct {
    cmd: []const u8,

    pub fn format(b: Bash, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeAll("/bin/bash -c '");
        for (b.cmd) |c| if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c);
        try w.writeAll("'");
    }
};

pub const EnvValue = struct {
    text: []const u8,

    pub fn format(v: EnvValue, w: *Io.Writer) Io.Writer.Error!void {
        for (v.text) |c| switch (c) {
            '\\' => try w.writeAll("\\\\"),
            '"' => try w.writeAll("\\\""),
            '%' => try w.writeAll("%%"),
            else => try w.writeByte(c),
        };
    }
};

pub const UnitPath = struct {
    path: []const u8,

    pub fn format(p: UnitPath, w: *Io.Writer) Io.Writer.Error!void {
        for (p.path) |c| switch (c) {
            '\\' => try w.writeAll("\\\\"),
            '%' => try w.writeAll("%%"),
            ' ', '\t', '\n', '\r', 0x0b, 0x0c => {
                try w.writeByte('\\');
                try w.writeByte(c);
            },
            else => try w.writeByte(c),
        };
    }
};

pub const Gates = std.StringHashMapUnmanaged(void);

pub fn gatesNeeded(arena: Allocator, services: []const Service) !Gates {
    var depended: Gates = .empty;
    var required: Gates = .empty;
    for (services) |s| {
        if (s.disabled) continue;
        for (s.requires) |d| {
            try depended.put(arena, d, {});
            try required.put(arena, d, {});
        }
        for (s.after) |d| try depended.put(arena, d, {});
    }
    var gates: Gates = .empty;
    for (services) |s| {
        if (s.disabled or !depended.contains(s.name)) continue;
        if (s.healthcheck != null or required.contains(s.name)) try gates.put(arena, s.name, {});
    }
    return gates;
}

fn gateName(arena: Allocator, config: Config, service_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}-{s}-ready.service", .{ config.grove, service_name });
}

fn orderedAfter(arena: Allocator, config: Config, gates: Gates, dep: []const u8) ![]const u8 {
    return if (gates.contains(dep)) gateName(arena, config, dep) else config.unitName(arena, dep);
}

pub fn writeUnit(arena: Allocator, w: *Io.Writer, config: Config, service: Service, set: ExecSet, gates: Gates) !void {
    const target = try config.targetName(arena);
    try w.print("[Unit]\nDescription=orch: {s}\nPartOf={s}\n", .{ service.name, target });

    var after: std.ArrayList([]const u8) = .empty;
    var binds: std.ArrayList([]const u8) = .empty;
    for (service.requires) |dep| {
        try binds.append(arena, try config.unitName(arena, dep));
        try after.append(arena, try orderedAfter(arena, config, gates, dep));
    }
    for (service.after) |dep| try after.append(arena, try orderedAfter(arena, config, gates, dep));
    if (after.items.len > 0) try w.print("After={s}\n", .{try std.mem.join(arena, " ", after.items)});
    if (binds.items.len > 0) try w.print("BindsTo={s}\n", .{try std.mem.join(arena, " ", binds.items)});
    if (service.restart.start_limit_burst) |b| try w.print("StartLimitBurst={d}\n", .{b});
    if (service.restart.start_limit_interval) |i| try w.print("StartLimitIntervalSec={s}\n", .{i});

    try w.writeAll("\n[Service]\n");
    try w.writeAll(if (service.oneshot) "Type=oneshot\nRemainAfterExit=yes\n" else "Type=simple\n");
    if (set.pre_start) |c| try w.print("ExecStartPre={f}\n", .{Bash{ .cmd = c }});
    try w.print("ExecStart={f}\n", .{Bash{ .cmd = set.start }});
    if (set.stop) |c| try w.print("ExecStop={f}\n", .{Bash{ .cmd = c }});
    if (set.reload) |c| try w.print("ExecReload={f}\n", .{Bash{ .cmd = c }});
    if (set.post_stop) |c| try w.print("ExecStopPost={f}\n", .{Bash{ .cmd = c }});
    if (service.workdir) |wd| try w.print("WorkingDirectory={f}\n", .{UnitPath{ .path = try supervise.resolvePath(arena, wd, config.project_dir) }});

    const keys = try arena.dupe([]const u8, service.env.map.keys());
    std.mem.sort([]const u8, keys, {}, lessThan);
    for (keys) |k| try w.print("Environment=\"{s}={f}\"\n", .{ k, EnvValue{ .text = service.env.map.get(k).? } });
    for (service.env_files) |f| try w.print("EnvironmentFile={f}\n", .{UnitPath{ .path = try supervise.resolvePath(arena, f, config.project_dir) }});
    if (service.user) |u| try w.print("User={s}\n", .{u});

    if (!service.oneshot) {
        try w.print("Restart={s}\n", .{switch (service.restart.policy) {
            .no => "no",
            .always => "always",
            .on_failure => "on-failure",
        }});
        if (service.restart.delay) |d| try w.print("RestartSec={s}\n", .{d});
    }
    if (service.timeouts.start) |t| try w.print("TimeoutStartSec={s}\n", .{t});
    if (service.timeouts.stop) |t| try w.print("TimeoutStopSec={s}\n", .{t});

    const r = service.resources;
    if (r.memory) |m| try w.print("MemoryMax={s}\n", .{m});
    if (r.cpu_quota) |q| {
        try w.print("CPUQuota={s}\n", .{q});
    } else if (r.cpus) |cpus| {
        try w.print("CPUQuota={d}%\n", .{@as(u32, @intFromFloat(cpus * 100.0))});
    }
    if (r.limit_nofile) |n| try w.print("LimitNOFILE={d}\n", .{n});
    if (r.limit_nproc) |n| try w.print("LimitNPROC={d}\n", .{n});
    if (r.tasks_max) |n| try w.print("TasksMax={d}\n", .{n});
    if (r.io_weight) |n| try w.print("IOWeight={d}\n", .{n});
    if (service.logging.stdout) |s| try w.print("StandardOutput=file:{f}\n", .{UnitPath{ .path = try supervise.resolvePath(arena, s, config.project_dir) }});
    if (service.logging.stderr) |s| try w.print("StandardError=file:{f}\n", .{UnitPath{ .path = try supervise.resolvePath(arena, s, config.project_dir) }});

    try w.print("\n[Install]\nWantedBy={s}\n", .{target});
}

pub fn writeReadyGate(arena: Allocator, w: *Io.Writer, config: Config, service: Service) !void {
    const unit = try config.unitName(arena, service.name);
    try w.print("[Unit]\nDescription=orch: wait for {s} health\nAfter={s}\nBindsTo={s}\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\n", .{ service.name, unit, unit });
    if (service.healthcheck) |hc| {
        const poll = try std.fmt.allocPrint(arena, "until {s} >/dev/null 2>&1; do sleep 2; done; exit 0", .{try supervise.healthcheckToCmd(arena, hc)});
        try w.print("ExecStart={f}\nTimeoutStartSec={s}\n", .{ Bash{ .cmd = poll }, service.readiness_timeout orelse "90s" });
    } else {
        try w.writeAll("ExecStart=/bin/true\n");
    }
}

pub fn writeTarget(arena: Allocator, w: *Io.Writer, config: Config, planted: []const types.Planted) !void {
    try w.writeAll("[Unit]\nDescription=orch managed services\n");
    for (planted) |p| {
        if (!p.service.disabled) try w.print("Wants={s}\n", .{try config.unitName(arena, p.service.name)});
    }
    try w.writeAll("\n[Install]\nWantedBy=multi-user.target\n");
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub fn systemdDir(arena: Allocator, config: Config) ![]const u8 {
    return switch (config.scope) {
        .user => std.fs.path.join(arena, &.{ config.xdg_config_home orelse try std.fs.path.join(arena, &.{ config.home, ".config" }), "systemd", "user" }),
        .system => "/etc/systemd/system",
    };
}

fn writeFileWith(arena: Allocator, io: Io, path: []const u8, comptime render: anytype, args: anytype) !void {
    var out: Io.Writer.Allocating = .init(arena);
    try @call(.auto, render, .{ arena, &out.writer } ++ args);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() });
}

pub fn generate(arena: Allocator, io: Io, config: Config, all: []const Service, planted: []const types.Planted) ![]const []const u8 {
    const units = try config.unitsDir(arena);
    try Io.Dir.cwd().createDirPath(io, units);
    const gates = try gatesNeeded(arena, all);
    var written: std.ArrayList([]const u8) = .empty;

    for (planted) |p| {
        const path = try std.fs.path.join(arena, &.{ units, try config.unitName(arena, p.service.name) });
        try writeFileWith(arena, io, path, writeUnit, .{ config, p.service, p.set, gates });
        try written.append(arena, path);
    }
    for (all) |s| {
        if (!gates.contains(s.name)) continue;
        const path = try std.fs.path.join(arena, &.{ units, try gateName(arena, config, s.name) });
        try writeFileWith(arena, io, path, writeReadyGate, .{ config, s });
        try written.append(arena, path);
    }
    const target = try std.fs.path.join(arena, &.{ units, try config.targetName(arena) });
    try writeFileWith(arena, io, target, writeTarget, .{ config, planted });
    try written.append(arena, target);
    return written.items;
}

fn systemctl(arena: Allocator, io: Io, config: Config, args: []const []const u8, diag: *Diagnostic) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, "systemctl");
    if (config.scope == .user) try argv.append(arena, "--user");
    try argv.appendSlice(arena, args);
    const joined = try std.mem.join(arena, " ", args);
    const out = exe.communicate(arena, io, argv.items, null) catch |err| {
        diag.set(arena, "systemctl {s}: {t}", .{ joined, err });
        return error.LifecycleFailed;
    };
    if (!out.ok()) {
        diag.set(arena, "systemctl {s} failed: {s}", .{ joined, out.reason() });
        return error.LifecycleFailed;
    }
}

pub fn check(arena: Allocator, io: Io, diag: *Diagnostic) !void {
    Io.Dir.cwd().access(io, "/run/systemd/system", .{}) catch {
        diag.set(arena, "systemd is not running (no /run/systemd/system)", .{});
        return error.PrerequisiteMissing;
    };
}

pub fn install(arena: Allocator, io: Io, config: Config, diag: *Diagnostic) !void {
    const cwd = Io.Dir.cwd();
    const dest = try systemdDir(arena, config);
    cwd.createDirPath(io, dest) catch |err| {
        diag.set(arena, "create {s}: {t}", .{ dest, err });
        return error.InstallFailed;
    };
    const units = try config.unitsDir(arena);
    var dir = cwd.openDir(io, units, .{ .iterate = true }) catch return systemctl(arena, io, config, &.{"daemon-reload"}, diag);
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const from = try std.fs.path.join(arena, &.{ units, entry.name });
        const to = try std.fs.path.join(arena, &.{ dest, entry.name });
        cwd.deleteFile(io, to) catch {};
        cwd.symLink(io, from, to, .{}) catch |err| {
            diag.set(arena, "failed to symlink {s} -> {s}: {t}", .{ from, to, err });
            return error.InstallFailed;
        };
    }
    try systemctl(arena, io, config, &.{"daemon-reload"}, diag);
}

pub fn clean(arena: Allocator, io: Io, config: Config) !void {
    const cwd = Io.Dir.cwd();
    const units = try config.unitsDir(arena);
    const dest = try systemdDir(arena, config);
    const prefix = try std.fmt.allocPrint(arena, "{s}-", .{config.grove});
    const target = try config.targetName(arena);
    if (cwd.openDir(io, units, .{ .iterate = true })) |opened| {
        var dir = opened;
        defer dir.close(io);
        var names: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (!std.mem.startsWith(u8, entry.name, prefix) and !std.mem.eql(u8, entry.name, target)) continue;
            try names.append(arena, try arena.dupe(u8, entry.name));
        }
        for (names.items) |name| {
            cwd.deleteFile(io, try std.fs.path.join(arena, &.{ dest, name })) catch {};
            cwd.deleteFile(io, try std.fs.path.join(arena, &.{ units, name })) catch {};
        }
    } else |_| {}
    cwd.createDirPath(io, units) catch {};
    var diag: Diagnostic = .{};
    systemctl(arena, io, config, &.{"daemon-reload"}, &diag) catch {};
}

pub fn remove(arena: Allocator, io: Io, config: Config, names: []const []const u8) !void {
    const cwd = Io.Dir.cwd();
    const units = try config.unitsDir(arena);
    const dest = try systemdDir(arena, config);
    for (names) |service| {
        for ([_][]const u8{ try config.unitName(arena, service), try gateName(arena, config, service) }) |unit| {
            cwd.deleteFile(io, try std.fs.path.join(arena, &.{ dest, unit })) catch {};
            cwd.deleteFile(io, try std.fs.path.join(arena, &.{ units, unit })) catch {};
        }
    }
    var diag: Diagnostic = .{};
    systemctl(arena, io, config, &.{"daemon-reload"}, &diag) catch {};
}

fn unitsOrTarget(arena: Allocator, config: Config, verb: []const u8, names: []const []const u8) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.append(arena, verb);
    if (names.len == 0) {
        try args.append(arena, try config.targetName(arena));
    } else for (names) |n| try args.append(arena, try config.unitName(arena, n));
    return args.items;
}

pub fn start(arena: Allocator, io: Io, config: Config, names: []const []const u8, diag: *Diagnostic) !void {
    try systemctl(arena, io, config, try unitsOrTarget(arena, config, "start", names), diag);
}

pub fn stop(arena: Allocator, io: Io, config: Config, names: []const []const u8, diag: *Diagnostic) !void {
    try systemctl(arena, io, config, try unitsOrTarget(arena, config, "stop", names), diag);
}

pub fn reload(arena: Allocator, io: Io, config: Config, service: []const u8, diag: *Diagnostic) !void {
    try systemctl(arena, io, config, &.{ "reload", try config.unitName(arena, service) }, diag);
}

pub const State = struct {
    active: []const u8 = "unknown",
    sub: []const u8 = "unknown",
    pid: ?u32 = null,
};

pub fn parseShow(text: []const u8) State {
    var state: State = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "ActiveState=")) {
            state.active = line["ActiveState=".len..];
        } else if (std.mem.startsWith(u8, line, "SubState=")) {
            state.sub = line["SubState=".len..];
        } else if (std.mem.startsWith(u8, line, "MainPID=")) {
            const p = std.fmt.parseInt(u32, line["MainPID=".len..], 10) catch 0;
            if (p > 0) state.pid = p;
        }
    }
    return state;
}

pub fn status(arena: Allocator, io: Io, config: Config, w: *Io.Writer, as_json: bool, diag: *Diagnostic) !void {
    const Row = struct { name: []const u8, state: State };
    const units = try config.unitsDir(arena);
    var dir = Io.Dir.cwd().openDir(io, units, .{ .iterate = true }) catch |err| {
        diag.set(arena, "cannot read units directory '{s}': {t}. Run 'orchd grow' first.", .{ units, err });
        return error.LifecycleFailed;
    };
    defer dir.close(io);
    const prefix = try std.fmt.allocPrint(arena, "{s}-", .{config.grove});
    var rows: std.ArrayList(Row) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const name = entry.name;
        if (!std.mem.endsWith(u8, name, ".service") or std.mem.endsWith(u8, name, "-ready.service") or !std.mem.startsWith(u8, name, prefix)) continue;
        const unit = try arena.dupe(u8, name);
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(arena, "systemctl");
        if (config.scope == .user) try argv.append(arena, "--user");
        try argv.appendSlice(arena, &.{ "show", unit, "--property=ActiveState,SubState,MainPID" });
        const out = exe.communicate(arena, io, argv.items, null) catch |err| {
            diag.set(arena, "systemctl show: {t}", .{err});
            return error.LifecycleFailed;
        };
        try rows.append(arena, .{ .name = unit[prefix.len .. unit.len - ".service".len], .state = parseShow(out.stdout) });
    }
    std.mem.sort(Row, rows.items, {}, struct {
        fn lessThan(_: void, a: Row, b: Row) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    if (as_json) {
        try w.writeAll("[");
        for (rows.items, 0..) |row, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("\n  {{\"name\":\"{s}\",\"state\":\"{s}\",\"sub\":\"{s}\",\"pid\":", .{ row.name, row.state.active, row.state.sub });
            if (row.state.pid) |p| try w.print("{d}}}", .{p}) else try w.writeAll("null}");
        }
        try w.writeAll("\n]\n");
        return;
    }
    try w.print("{s:<24} {s:<12} {s:<12} {s}\n", .{ "SERVICE", "STATE", "SUB", "PID" });
    try w.splatByteAll('-', 60);
    try w.writeAll("\n");
    for (rows.items) |row| {
        var pid_buf: [16]u8 = undefined;
        const pid = if (row.state.pid) |p| try std.fmt.bufPrint(&pid_buf, "{d}", .{p}) else "-";
        try w.print("{s:<24} {s:<12} {s:<12} {s}\n", .{ row.name, row.state.active, row.state.sub, pid });
    }
}

pub fn logs(arena: Allocator, io: Io, config: Config, service: []const u8, follow: bool, lines: u32, diag: *Diagnostic) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, "journalctl");
    if (config.scope == .user) try argv.append(arena, "--user");
    try argv.appendSlice(arena, &.{ "-u", try config.unitName(arena, service), "--no-pager", "-n", try std.fmt.allocPrint(arena, "{d}", .{lines}) });
    if (follow) try argv.append(arena, "-f");
    var child = try std.process.spawn(io, .{ .argv = argv.items });
    const term = try child.wait(io);
    if (!term.success()) {
        diag.set(arena, "journalctl exited with code {d}", .{switch (term) {
            .exited => |c| @as(i32, c),
            else => -1,
        }});
        return error.LifecycleFailed;
    }
}

fn unitFor(arena: Allocator, service: Service, set: ExecSet, all: []const Service) ![]const u8 {
    const config = @import("../config.zig").forTest("/test/.orch");
    var out: Io.Writer.Allocating = .init(arena);
    try writeUnit(arena, &out.writer, config, service, set, try gatesNeeded(arena, all));
    return out.written();
}

fn has(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "a plain service is a simple unit in the grove's target" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s: Service = .{ .name = "django", .mode = .host, .run_command = "python manage.py runserver 0.0.0.0:9090" };
    try testing.expectEqualStrings(
        \\[Unit]
        \\Description=orch: django
        \\PartOf=orch.target
        \\
        \\[Service]
        \\Type=simple
        \\ExecStart=/bin/bash -c 'python manage.py runserver 0.0.0.0:9090'
        \\Restart=no
        \\
        \\[Install]
        \\WantedBy=orch.target
        \\
    , try unitFor(arena.allocator(), s, .{ .start = s.run_command.? }, &.{s}));
}

test "requires binds and orders after the dependency's ready gate, after only orders" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var db: Service = .{ .name = "db", .mode = .host, .run_command = "x", .healthcheck = "pg_isready" };
    const cache: Service = .{ .name = "cache", .mode = .host, .run_command = "x" };
    var web: Service = .{ .name = "web", .mode = .host, .run_command = "x" };
    web.requires = &.{"db"};
    web.after = &.{"cache"};
    db.readiness_timeout = "30s";
    const all = [_]Service{ db, cache, web };
    const unit = try unitFor(a, web, .{ .start = "x" }, &all);
    try testing.expect(has(unit, "After=orch-db-ready.service orch-cache.service\nBindsTo=orch-db.service\n"));

    const gates = try gatesNeeded(a, &all);
    try testing.expect(gates.contains("db"));
    try testing.expect(!gates.contains("cache"));
    var out: Io.Writer.Allocating = .init(a);
    try writeReadyGate(a, &out.writer, @import("../config.zig").forTest("/s"), db);
    try testing.expect(has(out.written(), "ExecStart=/bin/bash -c 'until pg_isready >/dev/null 2>&1; do sleep 2; done; exit 0'\nTimeoutStartSec=30s\n"));
}

test "every exec is bash with quotes escaped, and the unit carries env, limits and logs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Service = .{ .name = "app", .mode = .host, .run_command = "x", .workdir = "my app", .user = "svc" };
    try s.env.map.put(a, "B", "say \"hi\" 100%");
    try s.env.map.put(a, "A", "1");
    s.env_files = &.{".env"};
    s.restart = .{ .policy = .on_failure, .delay = "5s", .start_limit_burst = 3, .start_limit_interval = "60s" };
    s.timeouts = .{ .start = "30s", .stop = "10s" };
    s.resources = .{ .memory = "512M", .cpus = 1.5, .limit_nofile = 65536, .tasks_max = 10, .io_weight = 50 };
    s.logging = .{ .stdout = "out.log" };
    const unit = try unitFor(a, s, .{ .start = "echo 'it''s'", .pre_start = "make", .stop = "kill", .reload = "kill -HUP $MAINPID", .post_stop = "rm x" }, &.{s});
    try testing.expect(has(unit, "StartLimitBurst=3\nStartLimitIntervalSec=60s\n"));
    try testing.expect(has(unit, "ExecStartPre=/bin/bash -c 'make'\nExecStart=/bin/bash -c 'echo '\\''it'\\'''\\''s'\\'''\nExecStop=/bin/bash -c 'kill'\nExecReload=/bin/bash -c 'kill -HUP $MAINPID'\nExecStopPost=/bin/bash -c 'rm x'\n"));
    try testing.expect(has(unit, "WorkingDirectory=/test/project/my\\ app\n"));
    try testing.expect(has(unit, "Environment=\"A=1\"\nEnvironment=\"B=say \\\"hi\\\" 100%%\"\nEnvironmentFile=/test/project/.env\nUser=svc\n"));
    try testing.expect(has(unit, "Restart=on-failure\nRestartSec=5s\nTimeoutStartSec=30s\nTimeoutStopSec=10s\nMemoryMax=512M\nCPUQuota=150%\nLimitNOFILE=65536\nTasksMax=10\nIOWeight=50\nStandardOutput=file:/test/project/out.log\n"));
}

test "a oneshot remains after exit and never restarts" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var s: Service = .{ .name = "migrate", .mode = .host, .run_command = "x", .oneshot = true };
    s.restart.policy = .always;
    const unit = try unitFor(arena.allocator(), s, .{ .start = "x" }, &.{s});
    try testing.expect(has(unit, "Type=oneshot\nRemainAfterExit=yes\n"));
    try testing.expect(!has(unit, "Restart="));
}

test "the target wants every enabled tree, not the disabled ones" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: Io.Writer.Allocating = .init(arena.allocator());
    const web: Service = .{ .name = "web", .mode = .host };
    const off: Service = .{ .name = "off", .mode = .host, .disabled = true };
    try writeTarget(arena.allocator(), &out.writer, @import("../config.zig").forTest("/s"), &.{ .{ .service = web, .set = .{ .start = "x" } }, .{ .service = off, .set = .{ .start = "y" } } });
    try testing.expectEqualStrings("[Unit]\nDescription=orch managed services\nWants=orch-web.service\n\n[Install]\nWantedBy=multi-user.target\n", out.written());
}

test "systemctl show is read for state, sub-state and a live pid" {
    const s = parseShow("ActiveState=active\nSubState=running\nMainPID=42\n");
    try testing.expectEqualStrings("active", s.active);
    try testing.expectEqualStrings("running", s.sub);
    try testing.expectEqual(42, s.pid.?);
    try testing.expectEqual(null, parseShow("MainPID=0\n").pid);
    try testing.expectEqualStrings("unknown", parseShow("").active);
}

test "user units live under XDG config, system ones in /etc" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var config = @import("../config.zig").forTest("/s");
    try testing.expectEqualStrings("/Users/test/.config/systemd/user", try systemdDir(arena.allocator(), config));
    config.xdg_config_home = "/xdg";
    try testing.expectEqualStrings("/xdg/systemd/user", try systemdDir(arena.allocator(), config));
    config.scope = .system;
    try testing.expectEqualStrings("/etc/systemd/system", try systemdDir(arena.allocator(), config));
}
