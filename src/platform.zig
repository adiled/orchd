const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const Config = @import("config.zig").Config;
const bed = @import("bed.zig");
const launchd = @import("platform/launchd.zig");
const systemd = @import("platform/systemd.zig");
const orchdi = @import("platform/orchdi.zig");
const Diagnostic = types.Diagnostic;
const Service = types.Service;

pub const Platform = enum {
    launchd,
    systemd,
    orchdi,

    pub fn parse(name: []const u8) ?Platform {
        return std.meta.stringToEnum(Platform, name);
    }

    pub fn check(p: Platform, arena: Allocator, io: Io, diag: *Diagnostic) !void {
        return switch (p) {
            .launchd => launchd.check(arena, io, diag),
            .systemd => systemd.check(arena, io, diag),
            .orchdi => {},
        };
    }

    pub fn beds(p: Platform, arena: Allocator, io: Io, config: Config, all: []const Service, planted: []const types.Planted, log: *Io.Writer) ![]const bed.Bed {
        return switch (p) {
            .launchd => launchd.beds(arena, io, config, all, planted, log),
            .systemd => systemd.beds(arena, config, all, planted),
            .orchdi => orchdi.beds(arena, config, all, planted),
        };
    }

    pub fn prepareGround(p: Platform, arena: Allocator, io: Io, config: Config) !void {
        if (p == .launchd) try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(arena, &.{ config.state_dir, "logs" }));
    }

    pub fn install(p: Platform, arena: Allocator, io: Io, config: Config, diag: *Diagnostic) !void {
        return switch (p) {
            .launchd => launchd.install(arena, io, config, diag),
            .systemd => systemd.install(arena, io, config, diag),
            .orchdi => {},
        };
    }

    pub fn clean(p: Platform, arena: Allocator, io: Io, config: Config) !void {
        return switch (p) {
            .launchd => launchd.clean(arena, io, config),
            .systemd => systemd.clean(arena, io, config),
            .orchdi => orchdi.clean(arena, io, config),
        };
    }

    pub fn remove(p: Platform, arena: Allocator, io: Io, config: Config, names: []const []const u8) !void {
        return switch (p) {
            .launchd => launchd.remove(arena, io, config, names),
            .systemd => systemd.remove(arena, io, config, names),
            .orchdi => orchdi.remove(arena, io, config, names),
        };
    }

    pub fn start(p: Platform, arena: Allocator, io: Io, config: Config, names: []const []const u8, diag: *Diagnostic) !void {
        return switch (p) {
            .launchd => launchd.start(arena, io, config, names, diag),
            .systemd => systemd.start(arena, io, config, names, diag),
            .orchdi => orchdi.start(arena, io, config, names, diag),
        };
    }

    pub fn stop(p: Platform, arena: Allocator, io: Io, config: Config, names: []const []const u8, diag: *Diagnostic) !void {
        return switch (p) {
            .launchd => launchd.stop(arena, io, config, names, diag),
            .systemd => systemd.stop(arena, io, config, names, diag),
            .orchdi => orchdi.stop(arena, io, config, names),
        };
    }

    pub fn status(p: Platform, arena: Allocator, io: Io, config: Config, w: *Io.Writer, as_json: bool, diag: *Diagnostic) !void {
        return switch (p) {
            .launchd => launchd.status(arena, io, config, w, as_json, diag),
            .systemd => systemd.status(arena, io, config, w, as_json, diag),
            .orchdi => orchdi.status(arena, io, config, w, as_json),
        };
    }

    pub fn logs(p: Platform, arena: Allocator, io: Io, config: Config, service: []const u8, follow: bool, lines: u32, diag: *Diagnostic) !void {
        return switch (p) {
            .launchd => launchd.logs(arena, io, config, service, follow, lines, diag),
            .systemd => systemd.logs(arena, io, config, service, follow, lines, diag),
            .orchdi => orchdi.logs(arena, io, config, service, follow, lines),
        };
    }
};

test "a platform is named launchd, systemd or orchdi" {
    try std.testing.expectEqual(.orchdi, Platform.parse("orchdi"));
    try std.testing.expectEqual(null, Platform.parse("upstart"));
}
