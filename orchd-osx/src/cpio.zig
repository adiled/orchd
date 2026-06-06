//! cpio.zig — build a newc cpio initramfs from a rootfs dir + our guest init.
//!
//! The kernel unpacks this into a tmpfs root and runs /init from it. The newc
//! format is simple ASCII headers + file data, so unlike a block filesystem it
//! is correct-by-construction: no superblock/bitmap/inode-table to get subtly
//! wrong. It is the rootfs transport for orchd-osx. Note: the initramfs loads
//! fully into RAM, so very large images need a matching VM memory size.
//!
//! newc entry: "070701" + 13 x 8-hex fields + name(+NUL), padded to 4 bytes,
//! then file data padded to 4 bytes. Archive ends with a "TRAILER!!!" entry.

const std = @import("std");

pub const Error = error{ OutOfMemory, OpenFailed, WriteFailed };

const Archive = struct {
    out: std.ArrayList(u8),
    a: std.mem.Allocator,
    ino: u32 = 100,

    fn writeHex8(field: []u8, value: u64) void {
        const hex = "0123456789ABCDEF";
        var v = value;
        var i: usize = 8;
        while (i > 0) {
            i -= 1;
            field[i] = hex[@intCast(v & 0xF)];
            v >>= 4;
        }
    }

    fn pad4(self: *Archive) Error!void {
        while (self.out.items.len % 4 != 0) self.out.append(self.a, 0) catch return Error.OutOfMemory;
    }

    /// Emit one entry header + name. `mode` is the full st_mode (type + perms).
    fn header(self: *Archive, name: []const u8, mode: u32, data_len: u64, nlink: u32) Error!void {
        var h: [110]u8 = undefined;
        @memcpy(h[0..6], "070701");
        writeHex8(h[6..14], self.ino);
        writeHex8(h[14..22], mode);
        writeHex8(h[22..30], 0); // uid
        writeHex8(h[30..38], 0); // gid
        writeHex8(h[38..46], nlink);
        writeHex8(h[46..54], 0); // mtime
        writeHex8(h[54..62], data_len);
        writeHex8(h[62..70], 0); // devmajor
        writeHex8(h[70..78], 0); // devminor
        writeHex8(h[78..86], 0); // rdevmajor
        writeHex8(h[86..94], 0); // rdevminor
        writeHex8(h[94..102], name.len + 1); // namesize incl NUL
        writeHex8(h[102..110], 0); // check
        self.ino += 1;
        self.out.appendSlice(self.a, &h) catch return Error.OutOfMemory;
        self.out.appendSlice(self.a, name) catch return Error.OutOfMemory;
        self.out.append(self.a, 0) catch return Error.OutOfMemory;
        try self.pad4();
    }

    fn file(self: *Archive, name: []const u8, mode: u32, data: []const u8) Error!void {
        try self.header(name, S_IFREG | (mode & 0o7777), data.len, 1);
        self.out.appendSlice(self.a, data) catch return Error.OutOfMemory;
        try self.pad4();
    }

    fn dir(self: *Archive, name: []const u8) Error!void {
        try self.header(name, S_IFDIR | 0o755, 0, 2);
    }

    fn symlink(self: *Archive, name: []const u8, target: []const u8) Error!void {
        try self.header(name, S_IFLNK | 0o777, target.len, 1);
        self.out.appendSlice(self.a, target) catch return Error.OutOfMemory;
        try self.pad4();
    }

    fn trailer(self: *Archive) Error!void {
        try self.header("TRAILER!!!", 0, 0, 1);
    }
};

const S_IFREG: u32 = 0o100000;
const S_IFDIR: u32 = 0o040000;
const S_IFLNK: u32 = 0o120000;

/// Build a cpio initramfs at `out_path`. Installs `init_bytes` at /init (0755)
/// and copies the tree under `rootfs_dir` in. Standard dirs (/proc /sys /dev)
/// are created so the guest init can mount them.
pub fn build(
    allocator: std.mem.Allocator,
    io: std.Io,
    rootfs_dir: []const u8,
    out_path: []const u8,
    init_bytes: []const u8,
) !void {
    var ar: Archive = .{ .out = .empty, .a = allocator };
    defer ar.out.deinit(allocator);

    // Standard mountpoints (init mounts proc/sys/dev onto these).
    try ar.dir("proc");
    try ar.dir("sys");
    try ar.dir("dev");

    // Our guest init at /init (the kernel runs this from the initramfs).
    try ar.file("init", 0o755, init_bytes);

    // Copy the rootfs tree (if present).
    var root = std.Io.Dir.cwd().openDir(io, rootfs_dir, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
    if (root) |*r| {
        defer r.close(io);
        try copyTree(&ar, io, allocator, r, "");
    }

    try ar.trailer();

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = ar.out.items });
}

/// Recursively add a directory's entries under `prefix` (no leading slash).
fn copyTree(ar: *Archive, io: std.Io, allocator: std.mem.Allocator, d: *std.Io.Dir, prefix: []const u8) !void {
    var it = d.iterate();
    while (try it.next(io)) |entry| {
        const name = if (prefix.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
        defer allocator.free(name);

        switch (entry.kind) {
            .directory => {
                try ar.dir(name);
                var sub = try d.openDir(io, entry.name, .{ .iterate = true });
                defer sub.close(io);
                try copyTree(ar, io, allocator, &sub, name);
            },
            .sym_link => {
                var buf: [4096]u8 = undefined;
                const n = try d.readLink(io, entry.name, &buf);
                try ar.symlink(name, buf[0..n]);
            },
            .file => {
                const data = try d.readFileAlloc(io, entry.name, allocator, .unlimited);
                defer allocator.free(data);
                // Preserve the real file mode from the host tree (OCI layers
                // carry it through the unpack). Fall back to 0644 if stat fails.
                const st = d.statFile(io, entry.name, .{}) catch null;
                const mode: u32 = if (st) |s| @intCast(s.permissions.toMode() & 0o7777) else 0o644;
                try ar.file(name, mode, data);
            },
            else => {},
        }
    }
}

// --- tests ---

test "cpio archive has newc magic, init entry, and trailer" {
    const a = std.testing.allocator;
    var ar: Archive = .{ .out = .empty, .a = a };
    defer ar.out.deinit(a);
    try ar.dir("proc");
    try ar.file("init", 0o755, "ELF...");
    try ar.trailer();

    const buf = ar.out.items;
    try std.testing.expect(std.mem.startsWith(u8, buf, "070701"));
    try std.testing.expect(std.mem.indexOf(u8, buf, "init") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf, "TRAILER!!!") != null);
    // 4-byte aligned overall.
    try std.testing.expectEqual(@as(usize, 0), buf.len % 4);
}
