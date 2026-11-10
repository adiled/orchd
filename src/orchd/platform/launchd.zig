const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const types = @import("../types.zig");
const Config = @import("../config.zig").Config;
const supervise = @import("../supervise.zig");
const exe = @import("../exe.zig");
const bed = @import("../bed.zig");
const Service = types.Service;
const ExecSet = types.ExecSet;
const Diagnostic = types.Diagnostic;

pub const default_path = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin";

pub const Xml = struct {
    text: []const u8,

    pub fn format(x: Xml, w: *Io.Writer) Io.Writer.Error!void {
        for (x.text) |c| switch (c) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            '\'' => try w.writeAll("&apos;"),
            else => try w.writeByte(c),
        };
    }
};

fn xml(text: []const u8) Xml {
    return .{ .text = text };
}

pub const Plist = struct {
    label: []const u8,
    service: Service,
    set: ExecSet,
    keeper: ?struct { orchd: []const u8, spec: []const u8 },
    env: []const [2][]const u8,
    workdir: ?[]const u8,
    stdout: []const u8,
    stderr: []const u8,
    exit_timeout: ?u32,
};

pub fn writePlist(w: *Io.Writer, p: Plist) Io.Writer.Error!void {
    try w.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>Label</key>
        \\
    );
    try w.print("  <string>{f}</string>\n", .{xml(p.label)});
    try w.writeAll("  <key>ProgramArguments</key>\n  <array>\n");
    if (p.keeper) |k| {
        try w.print("    <string>{f}</string>\n    <string>tend</string>\n    <string>--spec</string>\n    <string>{f}</string>\n", .{ xml(k.orchd), xml(k.spec) });
    } else {
        try w.writeAll("    <string>/bin/bash</string>\n    <string>-c</string>\n    <string>");
        if (p.set.pre_start) |pre| try w.print("{f} &amp;&amp; ", .{xml(pre)});
        try w.print("exec {f}</string>\n", .{xml(p.set.start)});
    }
    try w.writeAll("  </array>\n  <key>RunAtLoad</key>\n  <true/>\n");

    if (!p.service.oneshot) switch (p.service.restart.policy) {
        .always => try w.writeAll("  <key>KeepAlive</key>\n  <true/>\n"),
        .on_failure => try w.writeAll("  <key>KeepAlive</key>\n  <dict>\n    <key>SuccessfulExit</key>\n    <false/>\n  </dict>\n"),
        .no => {},
    };
    if (p.service.restart.delay) |delay| {
        if (supervise.parseDurationSecs(delay)) |secs| try w.print("  <key>ThrottleInterval</key>\n  <integer>{d}</integer>\n", .{secs});
    }
    if (p.workdir) |wd| try w.print("  <key>WorkingDirectory</key>\n  <string>{f}</string>\n", .{xml(wd)});

    const has_path = for (p.env) |kv| {
        if (std.mem.eql(u8, kv[0], "PATH")) break true;
    } else false;
    if (p.env.len > 0 or !has_path) {
        try w.writeAll("  <key>EnvironmentVariables</key>\n  <dict>\n");
        if (!has_path) try w.writeAll("    <key>PATH</key>\n    <string>" ++ default_path ++ "</string>\n");
        for (p.env) |kv| try w.print("    <key>{f}</key>\n    <string>{f}</string>\n", .{ xml(kv[0]), xml(kv[1]) });
        try w.writeAll("  </dict>\n");
    }
    if (p.service.user) |user| try w.print("  <key>UserName</key>\n  <string>{f}</string>\n", .{xml(user)});
    try w.print("  <key>StandardOutPath</key>\n  <string>{f}</string>\n  <key>StandardErrorPath</key>\n  <string>{f}</string>\n", .{ xml(p.stdout), xml(p.stderr) });

    const r = p.service.resources;
    const resident = if (r.memory) |m| supervise.parseMemoryBytes(m) else null;
    if (r.limit_nofile != null or r.limit_nproc != null or resident != null) {
        try w.writeAll("  <key>SoftResourceLimits</key>\n  <dict>\n");
        if (r.limit_nofile) |n| try w.print("    <key>NumberOfFiles</key>\n    <integer>{d}</integer>\n", .{n});
        if (r.limit_nproc) |n| try w.print("    <key>NumberOfProcesses</key>\n    <integer>{d}</integer>\n", .{n});
        if (resident) |n| try w.print("    <key>ResidentSetSize</key>\n    <integer>{d}</integer>\n", .{n});
        try w.writeAll("  </dict>\n");
    }
    try w.writeAll("  <key>ProcessType</key>\n  <string>Interactive</string>\n");
    if (p.exit_timeout) |secs| try w.print("  <key>ExitTimeOut</key>\n  <integer>{d}</integer>\n", .{secs});
    try w.writeAll("</dict>\n</plist>\n");
}

pub fn installDir(arena: Allocator, config: Config) ![]const u8 {
    return switch (config.scope) {
        .user => std.fs.path.join(arena, &.{ config.home, "Library", "LaunchAgents" }),
        .system => "/Library/LaunchDaemons",
    };
}

fn unitsDir(arena: Allocator, config: Config) ![]const u8 {
    return config.unitsDir(arena);
}

fn disabledDir(arena: Allocator, config: Config) ![]const u8 {
    return std.fs.path.join(arena, &.{ try config.unitsDir(arena), "disabled" });
}

fn plistName(arena: Allocator, label: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}.plist", .{label});
}

pub fn defaultLogPaths(arena: Allocator, config: Config, service_name: []const u8) ![2][]const u8 {
    return .{
        try std.fs.path.join(arena, &.{ config.state_dir, "logs", try std.fmt.allocPrint(arena, "{s}.log", .{service_name}) }),
        try std.fs.path.join(arena, &.{ config.state_dir, "logs", try std.fmt.allocPrint(arena, "{s}.err", .{service_name}) }),
    };
}

fn effectiveEnv(arena: Allocator, io: Io, config: Config, service: Service, log: *Io.Writer) ![]const [2][]const u8 {
    var merged: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    for (service.env_files) |file| {
        const path = try supervise.resolvePath(arena, file, config.project_dir);
        const content = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| {
            try log.print("warning: cannot read env file '{s}': {t}\n", .{ path, err });
            continue;
        };
        var bad: usize = 0;
        const env = supervise.parseEnvFile(arena, content, &bad) catch |err| {
            const why = if (err == error.EmptyKey) "empty key" else "expected KEY=value";
            try log.print("warning: invalid env file '{s}' line {d}: {s}\n", .{ path, bad, why });
            continue;
        };
        for (env.map.keys(), env.map.values()) |k, v| try merged.put(arena, k, v);
    }
    for (service.env.map.keys(), service.env.map.values()) |k, v| try merged.put(arena, k, v);
    const pairs = try arena.alloc([2][]const u8, merged.count());
    for (merged.keys(), merged.values(), pairs) |k, v, *pair| pair.* = .{ k, v };
    std.mem.sort([2][]const u8, pairs, {}, byKey);
    return pairs;
}

fn byKey(_: void, a: [2][]const u8, b: [2][]const u8) bool {
    return std.mem.lessThan(u8, a[0], b[0]);
}

pub fn plistFor(
    arena: Allocator,
    io: Io,
    config: Config,
    service: Service,
    set: ExecSet,
    deps: []const supervise.DepSpec,
    orchd: []const u8,
    log: *Io.Writer,
) !Plist {
    const label = try supervise.serviceLabel(arena, config, service.name);
    const log_paths = try defaultLogPaths(arena, config, service.name);
    const kept = supervise.needsKeeper(deps, set);
    return .{
        .label = label,
        .service = service,
        .set = set,
        .keeper = if (kept) .{ .orchd = orchd, .spec = try supervise.superviseSpecPath(arena, config, label) } else null,
        .env = try effectiveEnv(arena, io, config, service, log),
        .workdir = if (service.workdir) |wd| try supervise.resolvePath(arena, wd, config.project_dir) else null,
        .stdout = if (service.logging.stdout) |s| try supervise.resolvePath(arena, s, config.project_dir) else log_paths[0],
        .stderr = if (service.logging.stderr) |s| try supervise.resolvePath(arena, s, config.project_dir) else log_paths[1],
        .exit_timeout = if (kept)
            supervise.keeperStopTimeout(service, set) + supervise.keeper_grace_secs
        else if (service.timeouts.stop) |t| supervise.parseDurationSecs(t) else null,
    };
}

pub fn beds(
    arena: Allocator,
    io: Io,
    config: Config,
    all: []const Service,
    planted: []const types.Planted,
    log: *Io.Writer,
) ![]const bed.Bed {
    const units = try unitsDir(arena, config);
    const disabled = try disabledDir(arena, config);
    const orchd = exe.selfPath(arena, io);
    var out: std.ArrayList(bed.Bed) = .empty;
    for (planted) |p| {
        const deps = try supervise.buildDepGates(arena, config, p.service, all);
        const plist = try plistFor(arena, io, config, p.service, p.set, deps, orchd, log);
        var artifacts: std.ArrayList(bed.Artifact) = .empty;
        if (plist.keeper) |k| {
            const spec = try supervise.buildSuperviseSpec(arena, config, p.service, p.set, deps);
            try artifacts.append(arena, .{
                .kind = "supervise-spec",
                .path = k.spec,
                .content = try std.json.Stringify.valueAlloc(arena, spec, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }),
            });
        }
        const name = try plistName(arena, plist.label);
        const dir, const other = if (p.service.disabled) .{ disabled, units } else .{ units, disabled };
        try artifacts.append(arena, .{
            .kind = "plist",
            .path = try std.fs.path.join(arena, &.{ dir, name }),
            .content = try bed.render(arena, writePlist, .{plist}),
        });
        try out.append(arena, .{
            .label = plist.label,
            .name = p.service.name,
            .artifacts = artifacts.items,
            .stale = try arena.dupe([]const u8, &.{try std.fs.path.join(arena, &.{ other, name })}),
        });
    }
    return out.items;
}

pub fn generate(
    arena: Allocator,
    io: Io,
    config: Config,
    all: []const Service,
    planted: []const types.Planted,
    log: *Io.Writer,
) ![]const []const u8 {
    try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(arena, &.{ config.state_dir, "logs" }));
    return bed.plant(arena, io, try beds(arena, io, config, all, planted, log));
}

fn plistsIn(arena: Allocator, io: Io, dir_path: []const u8, prefix: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return out.items;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".plist") or !std.mem.startsWith(u8, entry.name, prefix)) continue;
        try out.append(arena, try arena.dupe(u8, entry.name));
    }
    return out.items;
}

pub fn check(arena: Allocator, io: Io, diag: *Diagnostic) !void {
    const out = exe.communicate(arena, io, &.{ "launchctl", "help" }, null) catch {
        diag.set(arena, "launchctl not found on PATH", .{});
        return error.PrerequisiteMissing;
    };
    if (!out.ok() and out.stdout.len == 0 and out.stderr.len == 0) {
        diag.set(arena, "launchctl not found on PATH", .{});
        return error.PrerequisiteMissing;
    }
}

pub fn install(arena: Allocator, io: Io, config: Config, diag: *Diagnostic) !void {
    const cwd = Io.Dir.cwd();
    const dest = try installDir(arena, config);
    cwd.createDirPath(io, dest) catch |err| {
        diag.set(arena, "create {s}: {t}", .{ dest, err });
        return error.InstallFailed;
    };
    const units = try unitsDir(arena, config);
    for (try plistsIn(arena, io, units, "")) |name| {
        const from = try std.fs.path.join(arena, &.{ units, name });
        const to = try std.fs.path.join(arena, &.{ dest, name });
        cwd.deleteFile(io, to) catch {};
        Io.Dir.copyFile(cwd, from, cwd, to, io, .{}) catch |err| {
            diag.set(arena, "copy {s} -> {s}: {t}", .{ from, to, err });
            return error.InstallFailed;
        };
    }
    for (try plistsIn(arena, io, try disabledDir(arena, config), "")) |name| {
        cwd.deleteFile(io, try std.fs.path.join(arena, &.{ dest, name })) catch {};
    }
}

pub fn clean(arena: Allocator, io: Io, config: Config) !void {
    const cwd = Io.Dir.cwd();
    const dest = try installDir(arena, config);
    const prefix = try std.fmt.allocPrint(arena, "{s}.", .{config.grove});
    for ([_][]const u8{ try unitsDir(arena, config), try disabledDir(arena, config) }) |dir| {
        for (try plistsIn(arena, io, dir, prefix)) |name| {
            _ = try bootout(arena, io, config, name[0 .. name.len - ".plist".len]);
            cwd.deleteFile(io, try std.fs.path.join(arena, &.{ dest, name })) catch {};
            cwd.deleteFile(io, try std.fs.path.join(arena, &.{ dir, name })) catch {};
        }
    }
    cwd.createDirPath(io, try unitsDir(arena, config)) catch {};
}

pub fn remove(arena: Allocator, io: Io, config: Config, names: []const []const u8) !void {
    const cwd = Io.Dir.cwd();
    for (names) |service| {
        const label = try supervise.serviceLabel(arena, config, service);
        _ = try bootout(arena, io, config, label);
        const name = try plistName(arena, label);
        cwd.deleteFile(io, try std.fs.path.join(arena, &.{ try installDir(arena, config), name })) catch {};
        cwd.deleteFile(io, try std.fs.path.join(arena, &.{ try unitsDir(arena, config), name })) catch {};
        cwd.deleteFile(io, try std.fs.path.join(arena, &.{ try disabledDir(arena, config), name })) catch {};
        cwd.deleteFile(io, try supervise.superviseSpecPath(arena, config, label)) catch {};
    }
}

fn domain(arena: Allocator, config: Config) ![]const u8 {
    return switch (config.scope) {
        .user => std.fmt.allocPrint(arena, "gui/{d}", .{std.c.getuid()}),
        .system => "system",
    };
}

fn target(arena: Allocator, config: Config, label: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ try domain(arena, config), label });
}

fn loaded(arena: Allocator, io: Io, tgt: []const u8) bool {
    const out = exe.communicate(arena, io, &.{ "launchctl", "print", tgt }, null) catch return false;
    return out.ok();
}

fn bootout(arena: Allocator, io: Io, config: Config, label: []const u8) !bool {
    const tgt = try target(arena, config, label);
    for (0..2) |_| {
        if (!loaded(arena, io, tgt)) return true;
        _ = exe.communicate(arena, io, &.{ "launchctl", "bootout", tgt }, null) catch {};
        for (0..300) |_| {
            if (!loaded(arena, io, tgt)) return true;
            try io.sleep(.fromMilliseconds(100), .awake);
        }
    }
    return !loaded(arena, io, tgt);
}

fn labelsFor(arena: Allocator, io: Io, config: Config, names: []const []const u8) ![]const []const u8 {
    if (names.len > 0) {
        const out = try arena.alloc([]const u8, names.len);
        for (names, out) |n, *l| l.* = try supervise.serviceLabel(arena, config, n);
        return out;
    }
    const prefix = try std.fmt.allocPrint(arena, "{s}.", .{config.grove});
    const found = try plistsIn(arena, io, try installDir(arena, config), prefix);
    for (found) |*name| name.* = name.*[0 .. name.len - ".plist".len];
    return found;
}

fn plistSource(arena: Allocator, io: Io, config: Config, label: []const u8) !?[]const u8 {
    const name = try plistName(arena, label);
    for ([_][]const u8{ try installDir(arena, config), try disabledDir(arena, config) }) |dir| {
        const path = try std.fs.path.join(arena, &.{ dir, name });
        Io.Dir.cwd().access(io, path, .{}) catch continue;
        return path;
    }
    return null;
}

pub fn start(arena: Allocator, io: Io, config: Config, names: []const []const u8, diag: *Diagnostic) !void {
    const dom = try domain(arena, config);
    for (try labelsFor(arena, io, config, names)) |label| {
        const plist = try plistSource(arena, io, config, label) orelse {
            diag.set(arena, "no bed is planted for {s}", .{label});
            return error.NotPlanted;
        };
        if (!try bootout(arena, io, config, label)) {
            diag.set(arena, "launchd still holds {s} after bootout", .{try target(arena, config, label)});
            return error.LifecycleFailed;
        }
        const out = exe.communicate(arena, io, &.{ "launchctl", "bootstrap", dom, plist }, null) catch |err| {
            diag.set(arena, "launchctl bootstrap: {t}", .{err});
            return error.LifecycleFailed;
        };
        if (!out.ok()) {
            diag.set(arena, "launchctl bootstrap {s} {s} failed: {s}", .{ dom, plist, out.reason() });
            return error.LifecycleFailed;
        }
    }
}

pub fn stop(arena: Allocator, io: Io, config: Config, names: []const []const u8, diag: *Diagnostic) !void {
    var stuck: std.ArrayList([]const u8) = .empty;
    for (try labelsFor(arena, io, config, names)) |label| {
        if (!try bootout(arena, io, config, label)) try stuck.append(arena, label);
    }
    if (stuck.items.len > 0) {
        diag.set(arena, "launchd still holds {s} after bootout", .{try std.mem.join(arena, ", ", stuck.items)});
        return error.LifecycleFailed;
    }
}

pub const State = struct {
    active: []const u8 = "inactive",
    sub: []const u8 = "dead",
    pid: ?u32 = null,
};

pub fn parseState(text: []const u8) State {
    var state: State = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (state.pid == null and std.mem.startsWith(u8, t, "pid =")) {
            const v = std.mem.trimEnd(u8, std.mem.trim(u8, t["pid =".len..], " \t"), ",");
            if (std.fmt.parseInt(u32, v, 10) catch null) |p| {
                if (p > 0) state.pid = p;
            }
        }
        if (std.mem.eql(u8, state.sub, "dead") and std.mem.startsWith(u8, t, "state =")) {
            state.sub = std.mem.trimEnd(u8, std.mem.trim(u8, t["state =".len..], " \t"), ",");
            state.active = if (std.mem.eql(u8, state.sub, "running")) "active" else "inactive";
        }
    }
    return state;
}

fn query(arena: Allocator, io: Io, config: Config, label: []const u8) !State {
    const out = exe.communicate(arena, io, &.{ "launchctl", "print", try target(arena, config, label) }, null) catch return .{};
    if (!out.ok()) return .{};
    return parseState(out.stdout);
}

pub fn pidOf(arena: Allocator, io: Io, config: Config, label: []const u8) !?u32 {
    return (try query(arena, io, config, label)).pid;
}

pub fn status(arena: Allocator, io: Io, config: Config, w: *Io.Writer, as_json: bool, diag: *Diagnostic) !void {
    const Row = struct { name: []const u8, state: State };
    const units = try unitsDir(arena, config);
    Io.Dir.cwd().access(io, units, .{}) catch |err| {
        diag.set(arena, "cannot read units directory '{s}': {t}. Run 'orchd grow' first.", .{ units, err });
        return error.LifecycleFailed;
    };
    const prefix = try std.fmt.allocPrint(arena, "{s}.", .{config.grove});
    var rows: std.ArrayList(Row) = .empty;
    for ([_]struct { []const u8, bool }{ .{ units, false }, .{ try disabledDir(arena, config), true } }) |source| {
        const dir, const is_disabled = source;
        for (try plistsIn(arena, io, dir, prefix)) |name| {
            const label = name[0 .. name.len - ".plist".len];
            var state = try query(arena, io, config, label);
            if (is_disabled and state.pid == null and std.mem.eql(u8, state.active, "inactive")) state.active = "disabled";
            try rows.append(arena, .{ .name = label[prefix.len..], .state = state });
        }
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
    const paths = try defaultLogPaths(arena, config, service);
    const n = try std.fmt.allocPrint(arena, "{d}", .{lines});
    var child = try std.process.spawn(io, .{
        .argv = if (follow) &.{ "tail", "-n", n, "-f", paths[0], paths[1] } else &.{ "tail", "-n", n, paths[0], paths[1] },
    });
    const term = try child.wait(io);
    if (!term.success()) {
        diag.set(arena, "tail exited with code {d}", .{switch (term) {
            .exited => |c| @as(i32, c),
            else => -1,
        }});
        return error.LifecycleFailed;
    }
}

fn testService(name: []const u8, run: []const u8) Service {
    return .{ .name = name, .mode = .host, .run_command = run };
}

fn render(arena: Allocator, service: Service, set: ExecSet, deps: []const supervise.DepSpec) ![]const u8 {
    const config = @import("../config.zig").forTest("/test/.orch");
    var sink: Io.Writer.Discarding = .init(&.{});
    const plist = try plistFor(arena, testing.io, config, service, set, deps, "/usr/local/bin/orchd", &sink.writer);
    var out: Io.Writer.Allocating = .init(arena);
    try writePlist(&out.writer, plist);
    return out.written();
}

fn has(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "a plain tree is a bash exec with the default PATH, logs under state, and no exit timeout" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try render(arena.allocator(), testService("web", "python server.py"), .{ .start = "python server.py" }, &.{});
    try testing.expectEqualStrings(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>Label</key>
        \\  <string>orch.web</string>
        \\  <key>ProgramArguments</key>
        \\  <array>
        \\    <string>/bin/bash</string>
        \\    <string>-c</string>
        \\    <string>exec python server.py</string>
        \\  </array>
        \\  <key>RunAtLoad</key>
        \\  <true/>
        \\  <key>EnvironmentVariables</key>
        \\  <dict>
        \\    <key>PATH</key>
        \\    <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        \\  </dict>
        \\  <key>StandardOutPath</key>
        \\  <string>/test/.orch/logs/web.log</string>
        \\  <key>StandardErrorPath</key>
        \\  <string>/test/.orch/logs/web.err</string>
        \\  <key>ProcessType</key>
        \\  <string>Interactive</string>
        \\</dict>
        \\</plist>
        \\
    , p);
}

test "restart policies become KeepAlive, oneshots never keep alive, delay throttles" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = testService("web", "server");
    s.restart.policy = .always;
    s.restart.delay = "5s";
    const always = try render(a, s, .{ .start = "server" }, &.{});
    try testing.expect(has(always, "  <key>KeepAlive</key>\n  <true/>\n"));
    try testing.expect(has(always, "<key>ThrottleInterval</key>\n  <integer>5</integer>"));
    s.restart.policy = .on_failure;
    try testing.expect(has(try render(a, s, .{ .start = "server" }, &.{}), "<key>SuccessfulExit</key>\n    <false/>"));
    s.oneshot = true;
    try testing.expect(!has(try render(a, s, .{ .start = "server" }, &.{}), "KeepAlive"));
}

test "teardown or gates hand the tree to the keeper, which outlasts its stop budget" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = testService("pg", "container run pg");
    const kept = try render(a, s, .{ .start = "container run pg", .stop = "container stop orch-pg" }, &.{});
    try testing.expect(has(kept, "    <string>/usr/local/bin/orchd</string>\n    <string>tend</string>\n    <string>--spec</string>\n    <string>/test/.orch/supervise/orch.pg.json</string>\n"));
    try testing.expect(has(kept, "<key>ExitTimeOut</key>\n  <integer>40</integer>"));
    s.timeouts.stop = "45s";
    try testing.expect(has(try render(a, s, .{ .start = "x", .stop = "y" }, &.{}), "<integer>55</integer>"));
    const gated = try render(a, testService("web", "x"), .{ .start = "x" }, &.{.{ .poll_cmd = "true", .timeout_secs = 1, .required = true }});
    try testing.expect(has(gated, "<string>tend</string>"));
    var plain = testService("web", "x");
    plain.timeouts.stop = "15s";
    try testing.expect(has(try render(a, plain, .{ .start = "x" }, &.{}), "<key>ExitTimeOut</key>\n  <integer>15</integer>"));
}

test "pre_start chains before exec, and everything is escaped" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try render(arena.allocator(), testService("web", "x"), .{ .start = "run --a 'b' <c>", .pre_start = "make & co" }, &.{});
    try testing.expect(has(p, "<string>make &amp; co &amp;&amp; exec run --a &apos;b&apos; &lt;c&gt;</string>"));
}

test "env is sorted, a given PATH replaces the default, and limits become soft resource limits" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = testService("web", "x");
    try s.env.map.put(a, "ZED", "1");
    try s.env.map.put(a, "PATH", "/opt/bin");
    try s.env.map.put(a, "ALPHA", "2");
    s.resources = .{ .memory = "512M", .limit_nofile = 4096, .limit_nproc = 64 };
    s.user = "nobody";
    s.workdir = "app";
    const p = try render(a, s, .{ .start = "x" }, &.{});
    try testing.expect(has(p, "  <dict>\n    <key>ALPHA</key>\n    <string>2</string>\n    <key>PATH</key>\n    <string>/opt/bin</string>\n    <key>ZED</key>\n"));
    try testing.expect(!has(p, default_path));
    try testing.expect(has(p, "<key>NumberOfFiles</key>\n    <integer>4096</integer>\n    <key>NumberOfProcesses</key>\n    <integer>64</integer>\n    <key>ResidentSetSize</key>\n    <integer>536870912</integer>"));
    try testing.expect(has(p, "<key>UserName</key>\n  <string>nobody</string>"));
    try testing.expect(has(p, "<key>WorkingDirectory</key>\n  <string>/test/project/app</string>"));
    s.resources = .{ .memory = "lots" };
    try testing.expect(!has(try render(a, s, .{ .start = "x" }, &.{}), "SoftResourceLimits"));
}

test "env files are inlined in order, and the service's own env wins" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "one.env", .data = "# c\nMODE=file\nexport TOK=abc\nQUOTED=\"hi there\"\nLATER=one\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "two.env", .data = "LATER=two\n" });
    var s = testService("app", "x");
    s.env_files = &.{ try std.fs.path.join(a, &.{ root, "one.env" }), try std.fs.path.join(a, &.{ root, "two.env" }) };
    try s.env.map.put(a, "MODE", "env");
    const p = try render(a, s, .{ .start = "x" }, &.{});
    try testing.expect(has(p, "<key>MODE</key>\n    <string>env</string>"));
    try testing.expect(has(p, "<key>TOK</key>\n    <string>abc</string>"));
    try testing.expect(has(p, "<key>QUOTED</key>\n    <string>hi there</string>"));
    try testing.expect(has(p, "<key>LATER</key>\n    <string>two</string>"));
}

test "launchctl print is read for the job's own state and pid, not nested ones" {
    const running = parseState("com.apple.xpc.launchd.agent = {\n\tstate = running\n\tpid = 28700\n\tjetsam coalition = {\n\t\ttype = state = active\n\t}\n}\n");
    try testing.expectEqualStrings("active", running.active);
    try testing.expectEqualStrings("running", running.sub);
    try testing.expectEqual(28700, running.pid.?);
    const stopped = parseState("x = {\n\tstate = not running\n\tlast exit code = 0\n}\n");
    try testing.expectEqualStrings("inactive", stopped.active);
    try testing.expectEqualStrings("not running", stopped.sub);
    try testing.expectEqual(null, stopped.pid);
    const pid_only = parseState("x = {\n\tpid = 5\n}\n");
    try testing.expectEqualStrings("dead", pid_only.sub);
    try testing.expectEqual(5, pid_only.pid.?);
    try testing.expectEqualStrings("inactive", parseState("").active);
}

test "the install dir is LaunchAgents for a user, LaunchDaemons for the system" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var config = @import("../config.zig").forTest("/s");
    try testing.expectEqualStrings("/Users/test/Library/LaunchAgents", try installDir(arena.allocator(), config));
    config.scope = .system;
    try testing.expectEqualStrings("/Library/LaunchDaemons", try installDir(arena.allocator(), config));
}

test "disabled beds are planted apart, and installing leaves them out of LaunchAgents" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    var config = @import("../config.zig").forTest(try std.fs.path.join(a, &.{ root, "state" }));
    config.home = try std.fs.path.join(a, &.{ root, "home" });
    const web = testService("web", "x");
    var off = testService("off", "y");
    off.disabled = true;
    var sink: Io.Writer.Discarding = .init(&.{});
    _ = try generate(a, testing.io, config, &.{ web, off }, &.{ .{ .service = web, .set = .{ .start = "x" } }, .{ .service = off, .set = .{ .start = "y" } } }, &sink.writer);
    var diag: Diagnostic = .{};
    try install(a, testing.io, config, &diag);
    try tmp.dir.access(testing.io, "state/units/orch.web.plist", .{});
    try tmp.dir.access(testing.io, "state/units/disabled/orch.off.plist", .{});
    try tmp.dir.access(testing.io, "home/Library/LaunchAgents/orch.web.plist", .{});
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "home/Library/LaunchAgents/orch.off.plist", .{}));
}
