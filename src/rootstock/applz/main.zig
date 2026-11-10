const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const testing = std.testing;
const contract = @import("contract");
const plugin = @import("plugin.zig");

const Verb = enum { contract, check, prepare, @"exec-set" };

const name = "orchd-rootstock-applz";
const usage = "usage: " ++ name ++ " contract|check|prepare|exec-set\n";

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buffer);
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer: Io.File.Writer = .initStreaming(.stderr(), io, &stderr_buffer);

    const status = try run(io, arena, init.environ_map, args, &stdout_writer.interface, &stderr_writer.interface);
    try stdout_writer.interface.flush();
    try stderr_writer.interface.flush();
    return status;
}

fn run(io: Io, arena: Allocator, environ: *const Environ.Map, args: []const []const u8, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    const verb = parseVerb(args) orelse {
        try stderr.writeAll(usage);
        return 2;
    };
    switch (verb) {
        .contract => try stdout.print("{d}\n", .{contract.base}),
        .check => {
            const applz = try findApplz(arena, io, environ) orelse return missing(stderr);
            if (!try runQuiet(io, &.{ applz, "check" })) {
                try stderr.writeAll("applz check failed: Virtualization.framework is not usable here\n");
                return 1;
            }
        },
        .prepare => {
            const envelope = try contract.readEnvelope(arena, io, name, stderr) orelse return 1;
            return prepare(arena, io, environ, envelope, stderr);
        },
        .@"exec-set" => {
            const envelope = try contract.readEnvelope(arena, io, name, stderr) orelse return 1;
            const applz = if (envelope.service.mode == .container)
                try findApplz(arena, io, environ) orelse return missing(stderr)
            else
                "applz";
            const files = try envelope.envFiles(arena, io);
            const set = plugin.execSet(arena, envelope, applz, files) catch |err| switch (err) {
                error.NoRunCommand, error.NoImage => |refusal| {
                    try plugin.explain(refusal, envelope.service, stderr);
                    return 1;
                },
                else => |e| return e,
            };
            try set.write(stdout);
        },
    }
    return 0;
}

fn prepare(arena: Allocator, io: Io, environ: *const Environ.Map, envelope: contract.Envelope, stderr: *Io.Writer) !u8 {
    const cwd = Io.Dir.cwd();
    const s = envelope.service;
    if (s.mode == .host) {
        const dir = try std.fs.path.join(arena, &.{ envelope.data_dir, s.name });
        cwd.createDirPath(io, dir) catch |err| {
            try stderr.print("cannot make {s}: {t}\n", .{ dir, err });
            return 1;
        };
        return 0;
    }
    for (s.volumes) |v| {
        if (!v.is_named) continue;
        const dir = try envelope.volumeDir(arena, v.source);
        cwd.createDirPath(io, dir) catch |err| {
            try stderr.print("cannot make volume {s} at {s}: {t}\n", .{ v.source, dir, err });
            return 1;
        };
    }
    const image = s.image orelse {
        try plugin.explain(error.NoImage, s, stderr);
        return 1;
    };
    const applz = try findApplz(arena, io, environ) orelse return missing(stderr);
    if (!try runQuiet(io, &.{ applz, "pull", image })) {
        try stderr.print("applz pull {s} failed\n", .{image});
        return 1;
    }
    return 0;
}

fn findApplz(arena: Allocator, io: Io, environ: *const Environ.Map) !?[]const u8 {
    if (std.process.executableDirPathAlloc(io, arena)) |dir| {
        const beside = try std.fs.path.join(arena, &.{ dir, "applz" });
        if (executable(io, beside)) return beside;
    } else |_| {}
    var dirs = std.mem.tokenizeScalar(u8, environ.get("PATH") orelse "", ':');
    while (dirs.next()) |dir| {
        const candidate = try std.fs.path.join(arena, &.{ dir, "applz" });
        if (executable(io, candidate)) return candidate;
    }
    return null;
}

fn executable(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{ .execute = true }) catch return false;
    return true;
}

fn missing(stderr: *Io.Writer) !u8 {
    try stderr.writeAll("applz not found beside orchd-rootstock-applz or on PATH\n");
    return 1;
}

fn runQuiet(io: Io, argv: []const []const u8) !bool {
    var child = try std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore });
    return (try child.wait(io)).success();
}

fn parseVerb(args: []const []const u8) ?Verb {
    if (args.len != 2) return null;
    return std.meta.stringToEnum(Verb, args[1]);
}

test "the verbs are the four the contract names" {
    try testing.expectEqual(.@"exec-set", parseVerb(&.{ "p", "exec-set" }));
    try testing.expectEqual(.contract, parseVerb(&.{ "p", "contract" }));
    try testing.expectEqual(null, parseVerb(&.{ "p", "run" }));
    try testing.expectEqual(null, parseVerb(&.{"p"}));
}

test {
    _ = plugin;
}
