const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const testing = std.testing;
const types = @import("types.zig");
const Config = @import("config.zig").Config;
const exe = @import("exe.zig");
const home = @import("home.zig");

pub const schema_version = 1;

pub const Overrides = std.StringArrayHashMapUnmanaged([]const u8);

pub fn supplied(config: Config) [2][2][]const u8 {
    return .{ .{ "ORCH_DATA", config.data_dir }, .{ "ORCH_PROJECT", config.project_dir } };
}

pub fn overrides(arena: Allocator, environ: *const Environ.Map, config: Config, log: *Io.Writer) !Overrides {
    var out: Overrides = .empty;
    var it = environ.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!std.mem.startsWith(u8, key, "ORCH_ARG_") or key.len == "ORCH_ARG_".len) continue;
        try out.put(arena, key["ORCH_ARG_".len..], entry.value_ptr.*);
    }
    for (config.args) |arg| {
        const eq = std.mem.indexOfScalar(u8, arg, '=') orelse {
            if (config.verbose) try log.print("warning: ignoring --arg '{s}' (expected name=value)\n", .{arg});
            continue;
        };
        try out.put(arena, arg[0..eq], arg[eq + 1 ..]);
    }
    return out;
}

pub fn argv(arena: Allocator, orch: []const u8, config: Config, args: Overrides) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(arena, &.{ orch, "resolve", "--json", config.orchfile });
    try out.appendSlice(arena, config.overlays);
    for (supplied(config)) |pair| try out.appendSlice(arena, &.{ "--arg", try std.fmt.allocPrint(arena, "{s}={s}", .{ pair[0], pair[1] }) });
    for (args.keys(), args.values()) |key, value| {
        try out.appendSlice(arena, &.{ "--arg", try std.fmt.allocPrint(arena, "{s}={s}", .{ key, value }) });
    }
    return out.items;
}

pub fn parse(
    arena: Allocator,
    io: Io,
    environ: *const Environ.Map,
    config: Config,
    log: *Io.Writer,
    diag: *types.Diagnostic,
) !types.Spec {
    const orch = try exe.find(arena, io, "orch", exe.selfDir(arena, io), environ.get("PATH") orelse "") orelse {
        diag.set(arena, "orch not found beside orchd or on PATH", .{});
        return error.OrchNotFound;
    };
    const args = try overrides(arena, environ, config, log);

    const result = std.process.run(arena, io, .{ .argv = try argv(arena, orch, config, args) }) catch |err| {
        diag.set(arena, "orch resolve could not run: {t}", .{err});
        return error.OrchResolve;
    };
    if (!result.term.success()) {
        if (std.mem.indexOf(u8, result.stderr, "'--json'") != null) {
            diag.set(arena, "{s} predates `orch resolve`; orchd needs orch 0.3 or newer", .{orch});
        } else {
            diag.set(arena, "{s}", .{try complaint(arena, result.stderr)});
        }
        return error.OrchResolve;
    }
    const spec = types.parseSpec(arena, result.stdout) catch |err| {
        diag.set(arena, "orch resolve printed a spec orchd cannot read: {t}", .{err});
        return error.OrchResolve;
    };

    var unknown: std.ArrayList([]const u8) = .empty;
    for (args.keys()) |key| {
        if (!spec.args.map.contains(key)) try unknown.append(arena, key);
    }
    std.mem.sort([]const u8, unknown.items, {}, lessThan);
    for (unknown.items) |key| {
        try log.print("warning: no ARG named '{s}' is declared; the override is ignored\n", .{key});
    }
    return admit(arena, config, spec, diag);
}

pub fn admit(arena: Allocator, config: Config, spec: types.Spec, diag: *types.Diagnostic) !types.Spec {
    const version = spec.schema_version orelse {
        diag.set(arena, "the spec has no schema_version; orchd reads what `orch resolve --json` prints, from orch 0.3 on", .{});
        return error.SchemaVersion;
    };
    if (version != schema_version) {
        diag.set(arena, "the spec is schema_version {d}; orchd reads {d}", .{ version, schema_version });
        return error.SchemaVersion;
    }
    var admitted = spec;
    admitted.services = try home.expand(arena, spec.services, home.here(arena, config.home), diag);
    return admitted;
}

fn complaint(arena: Allocator, stderr: []const u8) ![]const u8 {
    var errors: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "error: ")) try errors.append(arena, line["error: ".len..]);
    }
    if (errors.items.len == 0) return std.mem.trim(u8, stderr, " \t\r\n");
    return std.mem.join(arena, "\n", errors.items);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

test "orch resolves the Orchfile and overlays, with orchd's values before the user's overrides" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var config = @import("config.zig").forTest("/s");
    config.orchfile = "/srv/project/Orchfile";
    config.overlays = &.{"/srv/project/dev.orch"};
    config.data_dir = "/srv/data";
    config.project_dir = "/srv/project";
    var args: Overrides = .empty;
    try args.put(a, "ORCH_DATA", "/mine");
    const got = try argv(a, "/bin/orch", config, args);
    const want = [_][]const u8{
        "/bin/orch",       "resolve",             "--json", "/srv/project/Orchfile",     "/srv/project/dev.orch",
        "--arg",           "ORCH_DATA=/srv/data", "--arg",  "ORCH_PROJECT=/srv/project", "--arg",
        "ORCH_DATA=/mine",
    };
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "ARG overrides come from ORCH_ARG_ env, then --arg, which wins" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var environ: Environ.Map = .init(a);
    try environ.put("ORCH_ARG_PORT", "8080");
    try environ.put("ORCH_ARG_HOST", "env");
    try environ.put("ORCH_ARG_", "ignored-no-name");
    try environ.put("PATH", "/bin");
    var config = @import("config.zig").forTest("/s");
    config.args = &.{ "HOST=cli", "malformed" };
    var sink: Io.Writer.Discarding = .init(&.{});
    const got = try overrides(a, &environ, config, &sink.writer);
    try testing.expectEqualStrings("8080", got.get("PORT").?);
    try testing.expectEqualStrings("cli", got.get("HOST").?);
    try testing.expectEqual(2, got.count());
}

test "what orch complains about is its error lines, without its warnings or usage" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "parse error: line 3: WORKDIR path \"app\" must be absolute or start with ~\nparse error: line 4: undefined variable",
        try complaint(a, "warning: --arg ORCH_PROJECT matches no ARG declared in the files\nerror: parse error: line 3: WORKDIR path \"app\" must be absolute or start with ~\nerror: parse error: line 4: undefined variable\n\nUsage:\n  orch resolve\n"),
    );
    try testing.expectEqualStrings("it broke", try complaint(a, "  it broke\n"));
}

test "a spec is admitted only at the schema orchd reads" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = @import("config.zig").forTest("/s");
    var diag: types.Diagnostic = .{};
    try testing.expectError(error.SchemaVersion, admit(a, config, .{ .version = "1.0.0-rc" }, &diag));
    try testing.expectError(error.SchemaVersion, admit(a, config, .{ .schema_version = 2, .version = "1.0.0-rc" }, &diag));
    try testing.expectEqualStrings("the spec is schema_version 2; orchd reads 1", diag.message);
    const spec = try admit(a, config, .{ .schema_version = 1, .version = "1.0.0-rc", .services = &.{
        .{ .name = "api", .mode = .host, .workdir = "/srv/api" },
    } }, &diag);
    try testing.expectEqualStrings("/srv/api", spec.services[0].workdir.?);
}
