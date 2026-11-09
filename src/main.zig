const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const cli = @import("cli.zig");
const keeper = @import("keeper.zig");

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

    switch (command.command) {
        .tend => |t| if (t.spec) |spec| return keeper.run(arena, io, init.environ_map, spec, stderr),
        else => {},
    }
    try stderr.writeAll("error: not yet\n");
    return 1;
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
    _ = @import("rootstock.zig");
    _ = @import("platform/orchdi.zig");
    _ = @import("platform/launchd.zig");
}
