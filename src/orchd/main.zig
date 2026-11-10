const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const cli = @import("cli.zig");
const keeper = @import("keeper.zig");
const settings = @import("settings.zig");
const supervise = @import("supervise.zig");
const orchard = @import("orchard.zig");
const Engine = @import("engine.zig").Engine;
const Diagnostic = @import("types.zig").Diagnostic;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer: Io.File.Writer = .initStreaming(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stdout.flush() catch {};
    defer stderr.flush() catch {};

    var problem: []const u8 = "";
    const parsed = cli.parse(arena, argv[1..], build_options.version, &problem) catch |err| switch (err) {
        error.InvalidArguments => {
            try stderr.print("error: {s}\n\nFor more information, try '--help'.\n", .{problem});
            return 2;
        },
        error.OutOfMemory => return err,
    };
    const command = switch (parsed) {
        .help => |text| {
            try stdout.writeAll(text);
            return 0;
        },
        .version => {
            try stdout.print("orchd {s}\n", .{build_options.version});
            return 0;
        },
        .run => |c| c,
    };

    if (command.command == .tend) {
        if (command.command.tend.spec) |spec| return keeper.run(arena, io, init.environ_map, spec, stderr);
    }

    const config = try settings.load(arena, io, init.environ_map, command.global);
    var diag: Diagnostic = .{};
    run(arena, io, init.environ_map, config, command.command, stdout, stderr, &diag) catch |err| {
        try stdout.flush();
        if (diag.message.len > 0) {
            try stderr.print("error: {s}\n", .{diag.message});
        } else {
            try stderr.print("error: {t}\n", .{err});
        }
        return 1;
    };
    return 0;
}

fn run(
    arena: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    config: @import("config.zig").Config,
    command: cli.Command,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    diag: *Diagnostic,
) !void {
    switch (command) {
        .sow => return orchard.sow(arena, io, environ, config, stdout, diag),
        .plant => return orchard.plant(arena, io, config, stdout, stderr, diag),
        .tend => |t| if (t.service) |service| {
            const label = try supervise.serviceLabel(arena, config, service);
            const status = keeper.run(arena, io, environ, try supervise.superviseSpecPath(arena, config, label), stderr);
            try stderr.flush();
            std.process.exit(status);
        } else return orchard.tend(arena, io, config, !t.no_start, stderr, diag),
        else => {},
    }

    var engine = try Engine.init(arena, io, environ, config, stderr, diag);
    switch (command) {
        .grow => |g| try engine.grow(g.services, g.no_start, g.strict, g.force, g.reload),
        .survey => |s| try engine.status(stdout, s.json),
        .fell => |f| try engine.fell(f.services, f.keep_data),
        .logs => |l| {
            try stdout.flush();
            try stderr.flush();
            try engine.logs(l.service, l.follow, l.lines);
        },
        .sow, .plant, .tend => unreachable,
    }
}

test {
    _ = @import("types.zig");
    _ = @import("config.zig");
    _ = @import("supervise.zig");
    _ = @import("keeper.zig");
    _ = @import("cli.zig");
    _ = @import("exe.zig");
    _ = @import("settings.zig");
    _ = @import("spec.zig");
    _ = @import("home.zig");
    _ = @import("rootstock.zig");
    _ = @import("bed.zig");
    _ = @import("platform.zig");
    _ = @import("platform/orchdi.zig");
    _ = @import("platform/launchd.zig");
    _ = @import("platform/systemd.zig");
    _ = @import("engine.zig");
    _ = @import("orchard.zig");
}
