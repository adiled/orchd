const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const testing = std.testing;
const types = @import("types.zig");
const Config = @import("config.zig").Config;
const rootstock = @import("rootstock.zig");
const bed = @import("bed.zig");
const Platform = @import("platform.zig").Platform;
const Diagnostic = types.Diagnostic;

pub const Cutting = struct {
    service: types.Service,
    exec: types.ExecSet,
};

pub const Cuttings = struct {
    version: []const u8,
    rootstock: []const u8,
    cuttings: []const Cutting,
};

pub const Beds = struct {
    platform: []const u8,
    grove: []const u8,
    scope: []const u8,
    beds: []const bed.Bed,
};

const json_out: std.json.Stringify.Options = .{ .whitespace = .indent_2, .emit_null_optional_fields = false };

fn readStdin(arena: Allocator, io: Io) ![]const u8 {
    var buffer: [4096]u8 = undefined;
    var reader: Io.File.Reader = .initStreaming(.stdin(), io, &buffer);
    return reader.interface.allocRemaining(arena, .limited(64 << 20));
}

fn decode(comptime T: type, arena: Allocator, bytes: []const u8, diag: *Diagnostic) !T {
    return std.json.parseFromSliceLeaky(T, arena, bytes, .{ .ignore_unknown_fields = true }) catch |err| {
        diag.set(arena, "invalid JSON on stdin: {t}", .{err});
        return error.InvalidInput;
    };
}

fn platformOf(arena: Allocator, name: []const u8, diag: *Diagnostic) !Platform {
    return Platform.parse(name) orelse {
        diag.set(arena, "unknown platform '{s}' (launchd, systemd, orchdi)", .{name});
        return error.UnknownPlatform;
    };
}

pub fn sow(arena: Allocator, io: Io, environ: *const Environ.Map, config: Config, out: *Io.Writer, diag: *Diagnostic) !void {
    const spec = try decode(types.Spec, arena, try readStdin(arena, io), diag);
    const stock = try rootstock.create(arena, io, environ, config, diag);
    var cuttings: std.ArrayList(Cutting) = .empty;
    for (spec.services) |service| {
        if (service.disabled) continue;
        var why: Diagnostic = .{};
        const set = stock.execSet(arena, io, service, &why) catch |err| {
            diag.set(arena, "sow: service '{s}': {s}", .{ service.name, why.message });
            return err;
        };
        try cuttings.append(arena, .{ .service = service, .exec = set });
    }
    try std.json.Stringify.value(Cuttings{ .version = spec.version, .rootstock = config.rootstock, .cuttings = cuttings.items }, json_out, out);
    try out.writeAll("\n");
}

pub fn plantBeds(arena: Allocator, io: Io, config: Config, cuttings: Cuttings, log: *Io.Writer, diag: *Diagnostic) !Beds {
    const platform = try platformOf(arena, config.platform, diag);
    const services = try arena.alloc(types.Service, cuttings.cuttings.len);
    const planted = try arena.alloc(types.Planted, cuttings.cuttings.len);
    for (cuttings.cuttings, services, planted) |c, *s, *p| {
        s.* = c.service;
        p.* = .{ .service = c.service, .set = c.exec };
    }
    return .{
        .platform = config.platform,
        .grove = config.grove,
        .scope = @tagName(config.scope),
        .beds = try platform.beds(arena, io, config, services, planted, log),
    };
}

pub fn plant(arena: Allocator, io: Io, config: Config, out: *Io.Writer, log: *Io.Writer, diag: *Diagnostic) !void {
    const cuttings = try decode(Cuttings, arena, try readStdin(arena, io), diag);
    try std.json.Stringify.value(try plantBeds(arena, io, config, cuttings, log, diag), json_out, out);
    try out.writeAll("\n");
}

pub fn tend(arena: Allocator, io: Io, config: Config, start: bool, log: *Io.Writer, diag: *Diagnostic) !void {
    const beds = try decode(Beds, arena, try readStdin(arena, io), diag);
    const platform = try platformOf(arena, beds.platform, diag);
    for (try bed.plant(arena, io, beds.beds)) |path| {
        if (!config.quiet) try log.print("  wrote: {s}\n", .{path});
    }
    try platform.install(arena, io, config, diag);
    if (start) try platform.start(arena, io, config, &.{}, diag);
}

test "plant renders each cutting's bed for the platform, disabled ones apart" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var config = @import("config.zig").forTest("/s");
    config.platform = "orchdi";
    var sink: Io.Writer.Discarding = .init(&.{});
    var diag: Diagnostic = .{};
    const cuttings = try decode(Cuttings, a,
        \\{"version":"1.0.0-rc","rootstock":"bare","cuttings":[
        \\ {"service":{"name":"web","mode":"host","run_command":"sleep 1"},"exec":{"start":"sleep 1","pre_start":null}},
        \\ {"service":{"name":"off","mode":"host","disabled":true},"exec":{"start":"sleep 2"}}]}
    , &diag);
    const beds = try plantBeds(a, testing.io, config, cuttings, &sink.writer, &diag);
    try testing.expectEqualStrings("orchdi", beds.platform);
    try testing.expectEqualStrings("user", beds.scope);
    try testing.expectEqual(2, beds.beds.len);
    try testing.expectEqualStrings("/s/supervise/orch.web.json", beds.beds[0].artifacts[0].path);
    try testing.expectEqualStrings("/s/supervise/disabled/orch.off.json", beds.beds[1].artifacts[0].path);
    try testing.expectEqualStrings("/s/supervise/orch.off.json", beds.beds[1].stale[0]);
}
