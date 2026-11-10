const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const contract = @import("contract");
const bare = @import("plugin.zig");

const Verb = enum { contract, check, prepare, @"exec-set" };

const name = "orchd-rootstock-bare";
const usage = "usage: " ++ name ++ " contract|check|prepare|exec-set\n";

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buffer);
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer: Io.File.Writer = .initStreaming(.stderr(), io, &stderr_buffer);

    const status = try run(io, arena, args, &stdout_writer.interface, &stderr_writer.interface);
    try stdout_writer.interface.flush();
    try stderr_writer.interface.flush();
    return status;
}

fn run(io: Io, arena: Allocator, args: []const []const u8, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    const verb = parseVerb(args) orelse {
        try stderr.writeAll(usage);
        return 2;
    };
    switch (verb) {
        .contract => try stdout.print("{d}\n", .{contract.base}),
        .check => {},
        .prepare => {
            const envelope = try contract.readEnvelope(arena, io, name, stderr) orelse return 1;
            bare.prepare(io, .cwd(), envelope) catch |err| {
                try stderr.print("cannot make {s}/{s}: {s}\n", .{
                    envelope.data_dir,
                    envelope.service.name,
                    @errorName(err),
                });
                return 1;
            };
        },
        .@"exec-set" => {
            const envelope = try contract.readEnvelope(arena, io, name, stderr) orelse return 1;
            const set = bare.execSet(envelope.service) catch |refusal| {
                try bare.explain(refusal, envelope.service, stderr);
                return 1;
            };
            try set.write(stdout);
        },
    }
    return 0;
}

fn parseVerb(args: []const []const u8) ?Verb {
    if (args.len != 2) return null;
    return std.meta.stringToEnum(Verb, args[1]);
}

test "the verbs are the four the contract names" {
    try testing.expectEqual(.contract, parseVerb(&.{ "bare", "contract" }));
    try testing.expectEqual(.check, parseVerb(&.{ "bare", "check" }));
    try testing.expectEqual(.prepare, parseVerb(&.{ "bare", "prepare" }));
    try testing.expectEqual(.@"exec-set", parseVerb(&.{ "bare", "exec-set" }));
    try testing.expectEqual(null, parseVerb(&.{ "bare", "exec_set" }));
    try testing.expectEqual(null, parseVerb(&.{"bare"}));
    try testing.expectEqual(null, parseVerb(&.{ "bare", "check", "extra" }));
}

test "contract speaks the one contract bare knows" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err: Io.Writer.Allocating = .init(testing.allocator);
    defer err.deinit();
    try testing.expectEqual(0, try run(testing.io, testing.allocator, &.{ "bare", "contract" }, &out.writer, &err.writer));
    try testing.expectEqualStrings("1\n", out.written());
}

test "an unknown verb gets the usage and status 2" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err: Io.Writer.Allocating = .init(testing.allocator);
    defer err.deinit();
    try testing.expectEqual(2, try run(testing.io, testing.allocator, &.{ "bare", "grow" }, &out.writer, &err.writer));
    try testing.expectEqualStrings(usage, err.written());
}

test {
    _ = bare;
}
