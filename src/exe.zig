const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub fn isExecutable(io: Io, path: []const u8) bool {
    const cwd = Io.Dir.cwd();
    const stat = cwd.statFile(io, path, .{}) catch return false;
    if (stat.kind != .file) return false;
    cwd.access(io, path, .{ .execute = true }) catch return false;
    return true;
}

pub fn find(arena: Allocator, io: Io, file: []const u8, beside: ?[]const u8, path_var: []const u8) !?[]const u8 {
    if (beside) |dir| {
        const candidate = try std.fs.path.join(arena, &.{ dir, file });
        if (isExecutable(io, candidate)) return candidate;
    }
    var dirs = std.mem.tokenizeScalar(u8, path_var, ':');
    while (dirs.next()) |dir| {
        const candidate = try std.fs.path.join(arena, &.{ dir, file });
        if (isExecutable(io, candidate)) return candidate;
    }
    return null;
}

pub fn selfDir(arena: Allocator, io: Io) ?[]const u8 {
    return std.process.executableDirPathAlloc(io, arena) catch null;
}

pub fn selfPath(arena: Allocator, io: Io) []const u8 {
    return std.process.executablePathAlloc(io, arena) catch "orchd";
}

pub const Output = struct {
    term: std.process.Child.Term,
    stdout: []const u8,
    stderr: []const u8,

    pub fn ok(out: Output) bool {
        return out.term.success();
    }

    pub fn code(out: Output) i32 {
        return switch (out.term) {
            .exited => |c| c,
            else => -1,
        };
    }

    pub fn reason(out: Output) []const u8 {
        return std.mem.trim(u8, out.stderr, " \t\r\n");
    }
};

pub fn communicate(arena: Allocator, io: Io, argv: []const []const u8, input: ?[]const u8) !Output {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = if (input == null) .ignore else .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    if (input) |bytes| {
        const stdin = child.stdin.?;
        stdin.writeStreamingAll(io, bytes) catch |err| switch (err) {
            error.BrokenPipe => {},
            else => return err,
        };
        stdin.close(io);
        child.stdin = null;
    }

    var buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi: Io.File.MultiReader = undefined;
    multi.init(arena, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi.deinit();
    while (multi.fill(64, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try multi.checkAnyError();
    const term = try child.wait(io);
    return .{ .term = term, .stdout = try multi.toOwnedSlice(0), .stderr = try multi.toOwnedSlice(1) };
}

test "communicate feeds stdin and hands back both streams and the exit" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try communicate(arena.allocator(), testing.io, &.{ "/bin/sh", "-c", "tr a-z A-Z; echo oops >&2; exit 3" }, "envelope");
    try testing.expectEqualStrings("ENVELOPE", out.stdout);
    try testing.expectEqualStrings("oops", out.reason());
    try testing.expectEqual(3, out.code());
    try testing.expect(!out.ok());
}

test "a child that never reads stdin is still heard" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const big = try arena.allocator().alloc(u8, 1 << 20);
    @memset(big, 'x');
    const out = try communicate(arena.allocator(), testing.io, &.{ "/bin/sh", "-c", "echo no image for web >&2; exit 3" }, big);
    try testing.expectEqualStrings("no image for web", out.reason());
    try testing.expectEqual(3, out.code());
}

test "a tool is found beside orchd first, then on PATH, and only if it can run" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    try tmp.dir.createDirPath(testing.io, "beside");
    try tmp.dir.createDirPath(testing.io, "path");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "path/tool", .data = "#!/bin/sh\n", .flags = .{ .permissions = .fromMode(0o755) } });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "path/plain", .data = "x", .flags = .{ .permissions = .fromMode(0o644) } });
    const beside = try std.fs.path.join(a, &.{ root, "beside" });
    const path_var = try std.fmt.allocPrint(a, "/nonexistent:{s}/path", .{root});

    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ root, "path", "tool" }), (try find(a, testing.io, "tool", beside, path_var)).?);
    try testing.expectEqual(null, try find(a, testing.io, "plain", beside, path_var));
    try testing.expectEqual(null, try find(a, testing.io, "absent", beside, path_var));

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "beside/tool", .data = "#!/bin/sh\n", .flags = .{ .permissions = .fromMode(0o755) } });
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ beside, "tool" }), (try find(a, testing.io, "tool", beside, path_var)).?);
}
