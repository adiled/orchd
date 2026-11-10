const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const contract = @import("contract");
const plugin = @import("plugin.zig");
const run = @import("run.zig");

const name = "orchd-rootstock-cri";
const usage = "usage: " ++ name ++ " contract | check | prepare | exec-set | remove | run --spec-base64 <data>\n";

const Verb = enum { contract, check, prepare, @"exec-set", remove, run };

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

    const verb = (if (args.len >= 2) std.meta.stringToEnum(Verb, args[1]) else null) orelse {
        try stderr.writeAll(usage);
        return 2;
    };
    const configured = init.environ_map.get("ORCHD_CRI_ENDPOINT");
    const network = plugin.Network.parse(init.environ_map.get("ORCHD_CRI_NETWORK")) orelse {
        try plugin.explainEndpoint(error.UnknownNetwork, stderr);
        return 1;
    };
    switch (verb) {
        .contract => try stdout.print("{d} {d}\n", .{ contract.base, contract.removal }),
        .check => {
            const endpoint = run.findEndpoint(arena, io, configured) catch |err| {
                try plugin.explainEndpoint(err, stderr);
                return 1;
            };
            const health = run.check(arena, io, endpoint) catch |err| {
                try stderr.print("CRI runtime not reachable at {s}: {t}\n", .{ endpoint, err });
                return 1;
            };
            const v = health.version;
            const runtime = health.readiness.runtime;
            if (!runtime.ready) {
                try stderr.print("{s} {s} at {s} is not ready: {s} {s}\n", .{ v.runtime_name, v.runtime_version, endpoint, runtime.reason, runtime.message });
                return 1;
            }
            const pod_network = health.readiness.network;
            if (network == .pod and !pod_network.ready) {
                try stderr.print("{s} {s} at {s} has no pod network ({s} {s}): give it a CNI network, or set ORCHD_CRI_NETWORK=host\n", .{ v.runtime_name, v.runtime_version, endpoint, pod_network.reason, pod_network.message });
                return 1;
            }
            try stderr.print("{s} {s} (CRI {s}) at {s}, {t} network\n", .{ v.runtime_name, v.runtime_version, v.runtime_api_version, endpoint, network });
        },
        .prepare => {
            const envelope = try contract.readEnvelope(arena, io, name, stderr) orelse return 1;
            return prepare(arena, io, envelope, stderr);
        },
        .@"exec-set" => {
            const envelope = try contract.readEnvelope(arena, io, name, stderr) orelse return 1;
            const endpoint = if (envelope.service.mode == .host) "" else run.findEndpoint(arena, io, configured) catch |err| {
                try plugin.explainEndpoint(err, stderr);
                return 1;
            };
            const self = std.process.executablePathAlloc(io, arena) catch name;
            const set = plugin.execSet(arena, envelope, self, endpoint, network, try envelope.envFiles(arena, io)) catch |err| {
                try plugin.explain(err, envelope.service, stderr);
                return 1;
            };
            try set.write(stdout);
        },
        .remove => {
            const envelope = try contract.readEnvelope(arena, io, name, stderr) orelse return 1;
            if (envelope.service.mode == .host) return 0;
            const endpoint = run.findEndpoint(arena, io, configured) catch return 0;
            run.remove(arena, io, try plugin.removalSpec(arena, envelope, endpoint), stderr);
        },
        .run => {
            if (args.len != 4 or !std.mem.eql(u8, args[2], "--spec-base64")) {
                try stderr.writeAll(usage);
                return 2;
            }
            const spec = plugin.decodeRunSpec(arena, args[3]) catch |err| {
                try stderr.print("cri-run: bad --spec-base64: {t}\n", .{err});
                return 1;
            };
            return run.run(arena, io, spec, stderr);
        },
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
    _ = @import("cri.zig");
    _ = @import("log.zig");
    _ = plugin;
    _ = run;
}
