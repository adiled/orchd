const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const contract = @import("contract");
const plugin = @import("plugin.zig");
const run = @import("run.zig");

const name = "orchd-rootstock-containerd";
const usage = "usage: " ++ name ++ " contract | check | prepare | exec-set | remove | run --spec-base64 <data>\n";

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buffer);
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer: Io.File.Writer = .initStreaming(.stderr(), io, &stderr_buffer);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;
    defer stdout.flush() catch {};
    defer stderr.flush() catch {};

    const socket = init.environ_map.get("ORCHD_CONTAINERD_SOCKET") orelse plugin.default_socket;
    if (args.len < 2) {
        try stderr.writeAll(usage);
        return 2;
    }
    const verb = args[1];

    if (std.mem.eql(u8, verb, "contract")) {
        try stdout.print("{d} {d}\n", .{ contract.base, contract.removal });
    } else if (std.mem.eql(u8, verb, "check")) {
        const v = run.version(arena, io, socket) catch |err| {
            try stderr.print("containerd not reachable at {s}: {t}\n", .{ socket, err });
            return 1;
        };
        try stderr.print("containerd {s} ({s}) at {s}\n", .{ v.version, v.revision, socket });
    } else if (std.mem.eql(u8, verb, "prepare")) {
        const envelope = try contract.readEnvelope(arena, io, name, stderr) orelse return 1;
        return prepare(arena, io, envelope, stderr);
    } else if (std.mem.eql(u8, verb, "exec-set")) {
        const envelope = try contract.readEnvelope(arena, io, name, stderr) orelse return 1;
        const self = std.process.executablePathAlloc(io, arena) catch name;
        const no_pivot_root = std.mem.eql(u8, init.environ_map.get("ORCHD_CONTAINERD_NO_PIVOT_ROOT") orelse "", "1");
        const set = plugin.execSet(arena, envelope, self, socket, no_pivot_root, try envelope.envFiles(arena, io)) catch |err| {
            try plugin.explain(err, envelope.service, stderr);
            return 1;
        };
        try set.write(stdout);
    } else if (std.mem.eql(u8, verb, "remove")) {
        const envelope = try contract.readEnvelope(arena, io, name, stderr) orelse return 1;
        if (envelope.service.mode == .container) run.remove(arena, io, try plugin.removalSpec(arena, envelope, socket), stderr);
    } else if (std.mem.eql(u8, verb, "run")) {
        if (args.len != 4 or !std.mem.eql(u8, args[2], "--spec-base64")) {
            try stderr.writeAll(usage);
            return 2;
        }
        const spec = plugin.decodeRunSpec(arena, args[3]) catch |err| {
            try stderr.print("containerd-run: bad --spec-base64: {t}\n", .{err});
            return 1;
        };
        return run.run(arena, io, spec, stderr);
    } else {
        try stderr.writeAll(usage);
        return 2;
    }
    return 0;
}

fn prepare(arena: Allocator, io: Io, envelope: contract.Envelope, stderr: *Io.Writer) !u8 {
    const s = envelope.service;
    var dirs: std.ArrayList([]const u8) = .empty;
    if (s.mode == .host) try dirs.append(arena, try std.fs.path.join(arena, &.{ envelope.data_dir, s.name }));
    for (s.volumes) |v| if (v.is_named) try dirs.append(arena, try envelope.volumeDir(arena, v.source));
    for (dirs.items) |dir| Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        try stderr.print("cannot make {s}: {t}\n", .{ dir, err });
        return 1;
    };
    return 0;
}

test {
    _ = @import("containerd.zig");
    _ = @import("image.zig");
    _ = @import("oci.zig");
    _ = plugin;
    _ = run;
}
