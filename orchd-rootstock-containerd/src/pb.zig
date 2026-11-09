const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const Writer = struct {
    arena: Allocator,
    out: std.ArrayList(u8) = .empty,

    pub fn init(arena: Allocator) Writer {
        return .{ .arena = arena };
    }

    fn rawVarint(w: *Writer, value: u64) !void {
        var v = value;
        while (v >= 0x80) : (v >>= 7) try w.out.append(w.arena, @as(u8, @truncate(v)) | 0x80);
        try w.out.append(w.arena, @truncate(v));
    }

    fn tag(w: *Writer, field: u32, wire: u3) !void {
        try w.rawVarint((@as(u64, field) << 3) | wire);
    }

    pub fn uint(w: *Writer, field: u32, value: u64) !void {
        if (value == 0) return;
        try w.tag(field, 0);
        try w.rawVarint(value);
    }

    pub fn boolean(w: *Writer, field: u32, value: bool) !void {
        if (value) try w.uint(field, 1);
    }

    pub fn string(w: *Writer, field: u32, value: []const u8) !void {
        if (value.len == 0) return;
        try w.message(field, value);
    }

    pub fn message(w: *Writer, field: u32, encoded: []const u8) !void {
        try w.tag(field, 2);
        try w.rawVarint(encoded.len);
        try w.out.appendSlice(w.arena, encoded);
    }

    pub fn mapEntry(w: *Writer, field: u32, key: []const u8, value: []const u8) !void {
        var entry: Writer = .init(w.arena);
        try entry.string(1, key);
        try entry.string(2, value);
        try w.message(field, entry.bytes());
    }

    pub fn bytes(w: Writer) []const u8 {
        return w.out.items;
    }
};

pub const Value = union(enum) {
    varint: u64,
    fixed64: u64,
    bytes: []const u8,
    fixed32: u32,
};

pub const Field = struct {
    number: u32,
    value: Value,

    pub fn asBytes(f: Field) []const u8 {
        return switch (f.value) {
            .bytes => |b| b,
            else => "",
        };
    }

    pub fn asUint(f: Field) u64 {
        return switch (f.value) {
            .varint => |v| v,
            .fixed64 => |v| v,
            .fixed32 => |v| v,
            .bytes => 0,
        };
    }
};

pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) Reader {
        return .{ .data = data };
    }

    fn rawVarint(r: *Reader) !u64 {
        var result: u64 = 0;
        var shift: u7 = 0;
        while (true) {
            if (r.pos >= r.data.len) return error.Truncated;
            const byte = r.data[r.pos];
            r.pos += 1;
            if (shift >= 64) return error.VarintTooLong;
            result |= @as(u64, byte & 0x7f) << @intCast(shift);
            if (byte & 0x80 == 0) return result;
            shift += 7;
        }
    }

    fn take(r: *Reader, n: usize) ![]const u8 {
        if (n > r.data.len - r.pos) return error.Truncated;
        defer r.pos += n;
        return r.data[r.pos..][0..n];
    }

    pub fn next(r: *Reader) !?Field {
        if (r.pos >= r.data.len) return null;
        const key = try r.rawVarint();
        const number: u32 = @intCast(key >> 3);
        const value: Value = switch (@as(u3, @truncate(key))) {
            0 => .{ .varint = try r.rawVarint() },
            1 => .{ .fixed64 = std.mem.readInt(u64, (try r.take(8))[0..8], .little) },
            2 => .{ .bytes = try r.take(@intCast(try r.rawVarint())) },
            5 => .{ .fixed32 = std.mem.readInt(u32, (try r.take(4))[0..4], .little) },
            else => return error.UnsupportedWireType,
        };
        return .{ .number = number, .value = value };
    }
};

test "varints, strings and nested messages encode as protobuf does" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var w: Writer = .init(arena.allocator());
    try w.boolean(1, true);
    try testing.expectEqualSlices(u8, &.{ 0x08, 0x01 }, w.bytes());

    var big: Writer = .init(arena.allocator());
    try big.uint(3, 300);
    try big.string(2, "hi");
    try big.string(4, "");
    try big.uint(5, 0);
    try testing.expectEqualSlices(u8, &.{ 0x18, 0xac, 0x02, 0x12, 0x02, 'h', 'i' }, big.bytes());

    var outer: Writer = .init(arena.allocator());
    try outer.message(1, big.bytes());
    try outer.mapEntry(2, "k", "v");
    try testing.expectEqualSlices(u8, &.{ 0x0a, 0x07, 0x18, 0xac, 0x02, 0x12, 0x02, 'h', 'i', 0x12, 0x06, 0x0a, 0x01, 'k', 0x12, 0x01, 'v' }, outer.bytes());
}

test "a reader walks fields back out, and refuses what is cut short" {
    var r: Reader = .init(&.{ 0x18, 0xac, 0x02, 0x12, 0x02, 'h', 'i', 0x25, 1, 0, 0, 0 });
    const a = (try r.next()).?;
    try testing.expectEqual(3, a.number);
    try testing.expectEqual(300, a.asUint());
    const b = (try r.next()).?;
    try testing.expectEqualStrings("hi", b.asBytes());
    const c = (try r.next()).?;
    try testing.expectEqual(1, c.asUint());
    try testing.expectEqual(null, try r.next());

    var cut: Reader = .init(&.{ 0x12, 0x05, 'h' });
    try testing.expectError(error.Truncated, cut.next());
}
