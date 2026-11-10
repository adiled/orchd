const std = @import("std");
const posix = std.posix;
const testing = std.testing;

pub const Stream = enum { stdout, stderr };

pub const Line = struct {
    stream: Stream,
    partial: bool,
    content: []const u8,
};

pub fn parse(line: []const u8) ?Line {
    var rest = line;
    _ = cut(&rest) orelse return null;
    const stream = std.meta.stringToEnum(Stream, cut(&rest) orelse return null) orelse return null;
    const tag = cut(&rest) orelse return null;
    return .{ .stream = stream, .partial = std.mem.startsWith(u8, tag, "P"), .content = rest };
}

fn cut(rest: *[]const u8) ?[]const u8 {
    const space = std.mem.indexOfScalar(u8, rest.*, ' ') orelse {
        if (rest.len == 0) return null;
        defer rest.* = "";
        return rest.*;
    };
    defer rest.* = rest.*[space + 1 ..];
    return rest.*[0..space];
}

pub const Tail = struct {
    path: [:0]const u8,
    fd: posix.fd_t = -1,
    pending: [1 << 16]u8 = undefined,
    pending_len: usize = 0,

    pub fn pump(t: *Tail, out: posix.fd_t, err: posix.fd_t) void {
        if (t.fd < 0) {
            t.fd = std.c.open(t.path, .{ .ACCMODE = .RDONLY });
            if (t.fd < 0) return;
        }
        while (true) {
            const room = t.pending[t.pending_len..];
            if (room.len == 0) {
                t.emit(t.pending[0..t.pending_len], out, err);
                t.pending_len = 0;
                continue;
            }
            const n = posix.read(t.fd, room) catch return;
            if (n == 0) return;
            t.pending_len += n;
            var start: usize = 0;
            const filled = t.pending[0..t.pending_len];
            while (std.mem.indexOfScalarPos(u8, filled, start, '\n')) |nl| {
                t.emit(filled[start..nl], out, err);
                start = nl + 1;
            }
            std.mem.copyForwards(u8, t.pending[0 .. t.pending_len - start], filled[start..]);
            t.pending_len -= start;
        }
    }

    fn emit(_: *Tail, raw: []const u8, out: posix.fd_t, err: posix.fd_t) void {
        const line = parse(raw) orelse Line{ .stream = .stdout, .partial = false, .content = raw };
        const fd = if (line.stream == .stderr) err else out;
        write(fd, line.content);
        if (!line.partial) write(fd, "\n");
    }

    pub fn close(t: *Tail) void {
        if (t.fd >= 0) _ = std.c.close(t.fd);
        t.fd = -1;
    }
};

fn write(fd: posix.fd_t, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const wrote = std.c.write(fd, rest.ptr, rest.len);
        if (wrote <= 0) return;
        rest = rest[@intCast(wrote)..];
    }
}

test "a CRI log line gives its stream, whether it is partial, and its content" {
    const full = parse("2026-11-10T00:17:09.669794202Z stdout F hello world").?;
    try testing.expectEqual(.stdout, full.stream);
    try testing.expect(!full.partial);
    try testing.expectEqualStrings("hello world", full.content);
    const partial = parse("2026-11-10T00:17:09.6Z stderr P half ").?;
    try testing.expectEqual(.stderr, partial.stream);
    try testing.expect(partial.partial);
    try testing.expectEqualStrings("half ", partial.content);
    try testing.expectEqualStrings("", parse("2026-11-10T00:17:09.6Z stdout F").?.content);
    try testing.expectEqual(null, parse("not a cri line"));
    try testing.expectEqual(null, parse(""));
}

test "the tail follows the file as it grows, splits streams, and joins partial lines" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const log_path = try std.fmt.allocPrintSentinel(a, "{s}/web.log", .{root}, 0);
    const out = try create(a, root, "out");
    const err = try create(a, root, "err");
    defer _ = std.c.close(out);
    defer _ = std.c.close(err);

    var tail: Tail = .{ .path = log_path };
    defer tail.close();
    tail.pump(out, err);

    const log = try create(a, root, "web.log");
    defer _ = std.c.close(log);
    write(log, "t stdout F one\nt stderr F oops\nt stdout P tw");
    tail.pump(out, err);
    write(log, "o-\nt stdout F o\n");
    tail.pump(out, err);

    try testing.expectEqualStrings("one\ntwo-o\n", try tmp.dir.readFileAlloc(testing.io, "out", a, .limited(1 << 10)));
    try testing.expectEqualStrings("oops\n", try tmp.dir.readFileAlloc(testing.io, "err", a, .limited(1 << 10)));
}

fn create(a: std.mem.Allocator, root: []const u8, name: []const u8) !posix.fd_t {
    const path = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ root, name }, 0);
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(c_uint, 0o644));
    if (fd < 0) return error.CannotCreate;
    return fd;
}
