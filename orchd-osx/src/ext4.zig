//! ext4.zig — rootfs directory -> ext4 image file (the VM's /dev/vda).
//!
//! Boundary: "given an unpacked rootfs dir, produce an ext4 image at out_path".
//! Knows nothing about VMs or OCI. Parity with what ContainerizationEXT4 does,
//! built from scratch in Zig (no mkfs dependency).
//!
//! STATUS: first cut, single block group. We build a real on-disk ext4:
//!   - 4096-byte blocks, one block group (so images up to ~128 MiB).
//!   - Classic ext2/3-style inodes (128-byte) with direct + single/double
//!     indirect block pointers. No extents, no journal, no 64-bit feature, no
//!     htree dirs. We set s_rev_level = 1 and a minimal feature set so Linux
//!     mounts it read-write as ext4 (it falls back to ext2-compatible paths).
//!   - The full rootfs tree is copied in: directories, regular files, symlinks
//!     (fast symlinks inline, slow symlinks in a data block). The tree is held
//!     in memory as a DirBuilder graph and serialized in one pass, which lets
//!     init_bytes be installed at a nested init_path (e.g. /usr/bin/foo,
//!     creating intermediate dirs) with mode 0755.
//!
//! ON-DISK LAYOUT (block numbers, 4 KiB each):
//!   block 0      : 1024 pad + superblock (1024) + remainder of block
//!   block 1      : block group descriptor table
//!   block 2      : block bitmap (1 block)
//!   block 3      : inode bitmap (1 block)
//!   block 4..    : inode table (inode_count * 128 bytes, rounded to blocks)
//!   then         : data blocks (allocated sequentially as we write the tree)
//!
//! TODO before a real container can boot off this:
//!   - Multiple block groups for images > 128 MiB.
//!   - Switch to extent-mapped inodes (faster, what modern e2fsprogs writes).
//!   - Preserve file modes/uid/gid more faithfully from the source tree.
//!   - Hard links (we currently materialize each link as its own inode).

const std = @import("std");

pub const Error = error{ NotImplemented, TooSmall, TooLarge };

// --- ext4 constants ---
const block_size: u32 = 4096;
const block_size_log = 2; // log2(block_size) - 10 = log2(4096)-10 = 2
const inode_size: u16 = 128;
const sb_magic: u16 = 0xEF53;
const root_ino: u32 = 2;
const first_ino: u32 = 11; // first non-reserved inode

// Inode mode bits.
const S_IFDIR: u16 = 0o40000;
const S_IFREG: u16 = 0o100000;
const S_IFLNK: u16 = 0o120000;

// Directory entry file types (ext4 filetype feature).
const FT_REG: u8 = 1;
const FT_DIR: u8 = 2;
const FT_SYMLINK: u8 = 7;

/// In-memory builder. We materialize the whole image in a heap buffer, then
/// flush it once. Fine for the image sizes we target (a few to tens of MiB).
const Builder = struct {
    allocator: std.mem.Allocator,
    buf: []u8,
    total_blocks: u32,
    inodes_count: u32,
    inode_table_start: u32, // block number
    first_data_block_num: u32, // first allocatable data block
    next_free_block: u32,
    next_free_ino: u32,
    blocks_used: u32,
    inodes_used: u32,

    fn blockPtr(self: *Builder, block: u32) []u8 {
        const off: usize = @as(usize, block) * block_size;
        return self.buf[off .. off + block_size];
    }

    fn allocBlock(self: *Builder) !u32 {
        if (self.next_free_block >= self.total_blocks) return Error.TooSmall;
        const b = self.next_free_block;
        self.next_free_block += 1;
        self.blocks_used += 1;
        return b;
    }

    fn allocIno(self: *Builder) !u32 {
        if (self.next_free_ino > self.inodes_count) return Error.TooSmall;
        const i = self.next_free_ino;
        self.next_free_ino += 1;
        self.inodes_used += 1;
        return i;
    }

    fn inodePtr(self: *Builder, ino: u32) []u8 {
        // inodes are 1-based.
        const idx = ino - 1;
        const off: usize = @as(usize, self.inode_table_start) * block_size + @as(usize, idx) * inode_size;
        return self.buf[off .. off + inode_size];
    }
};

// --- inode layout (ext2/3, 128 bytes) ---
// We write the fields the kernel needs to read a tree: mode, size, link count,
// and the 15 block pointers (12 direct, 1 single-indirect, 1 double-indirect,
// 1 triple-indirect — we only populate up to double-indirect).
const I_MODE = 0x00;
const I_SIZE_LO = 0x04;
const I_LINKS_COUNT = 0x1A;
const I_BLOCKS_LO = 0x1C;
const I_BLOCK = 0x28; // 15 * u32

fn setInode(
    b: *Builder,
    ino: u32,
    mode: u16,
    size: u64,
    links: u16,
    block_ptrs: []const u32,
    i512_blocks: u32,
) void {
    const p = b.inodePtr(ino);
    @memset(p, 0);
    std.mem.writeInt(u16, p[I_MODE..][0..2], mode, .little);
    std.mem.writeInt(u32, p[I_SIZE_LO..][0..4], @truncate(size), .little);
    std.mem.writeInt(u16, p[I_LINKS_COUNT..][0..2], links, .little);
    // i_blocks is counted in 512-byte sectors.
    std.mem.writeInt(u32, p[I_BLOCKS_LO..][0..4], i512_blocks, .little);
    for (block_ptrs, 0..) |bp, i| {
        if (i >= 15) break;
        std.mem.writeInt(u32, p[I_BLOCK + i * 4 ..][0..4], bp, .little);
    }
}

/// Build an ext4 image at `out_path` from the files under `rootfs_dir`,
/// sized `size_bytes`. `init_path`/`init_bytes` install our guest init into the
/// image at the location the kernel cmdline boots (e.g. /orchd-init).
pub fn build(
    allocator: std.mem.Allocator,
    rootfs_dir: []const u8,
    out_path: []const u8,
    size_bytes: u64,
    init_path: []const u8,
    init_bytes: []const u8,
) !void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try buildIo(allocator, io, rootfs_dir, out_path, size_bytes, init_path, init_bytes);
}

fn buildIo(
    allocator: std.mem.Allocator,
    io: std.Io,
    rootfs_dir: []const u8,
    out_path: []const u8,
    size_bytes: u64,
    init_path: []const u8,
    init_bytes: []const u8,
) !void {
    var b = try initBuilder(allocator, size_bytes);
    defer allocator.free(b.buf);

    // Inodes 1..10 are reserved; root is inode 2. Real allocations start at 11.
    // We account the 10 reserved inodes plus root as "used" up front.
    b.inodes_used = first_ino - 1; // inodes 1..10
    b.next_free_ino = first_ino;

    // Build the root directory, recursively populating from rootfs_dir.
    var dir = std.Io.Dir.cwd().openDir(io, rootfs_dir, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return Error.NotImplemented, // caller must create rootfs first
        else => return e,
    };
    defer dir.close(io);

    var root = DirBuilder.init(allocator, root_ino, root_ino);
    defer root.deinit();

    try writeTree(&b, io, allocator, dir, &root);

    // Install init binary at init_path (relative to root).
    try installFile(&b, allocator, &root, init_path, init_bytes, 0o755);

    // Now flush the whole directory tree (children before parents).
    try finishTree(&b, &root, S_IFDIR | 0o755);

    // Write fs metadata (superblock, group descriptor, bitmaps).
    try writeMetadata(&b);

    // Flush to disk.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = b.buf });
}

/// The single-block-group size bound, in blocks. One block group addresses
/// exactly `blocks_per_group` blocks, and `blocks_per_group` is fixed by the
/// block bitmap holding 8 bits per byte over one block: 4096 bytes * 8 =
/// 32768 blocks. At a 4 KiB block size that is 32768 * 4096 = 128 MiB.
///
/// Going past this needs a second block group, which means: a per-group block
/// bitmap, inode bitmap and inode table; a backup superblock + GDT at the
/// group's start (sparse_super lets us skip most, but group 1 is a backup
/// group); and a multi-entry block group descriptor table. That is the next
/// real chunk of work (see the module TODO); until then we hard-cap here so a
/// caller asking for > 128 MiB fails loudly instead of silently corrupting.
const max_blocks_single_group: u32 = 8 * block_size; // 32768 blocks = 128 MiB

fn initBuilder(allocator: std.mem.Allocator, size_bytes: u64) !Builder {
    if (size_bytes < 64 * 1024) return Error.TooSmall;
    const total_blocks_u64 = size_bytes / block_size;
    // Single block group only: see `max_blocks_single_group`. 128 MiB is the
    // hard bound at a 4 KiB block size. TooLarge fires here, before we allocate
    // the image buffer, so the caller never gets a half-built fs.
    if (total_blocks_u64 > max_blocks_single_group) return Error.TooLarge;
    const total_blocks: u32 = @intCast(total_blocks_u64);

    // Inode count: a generous ratio. One inode per 16 KiB, capped to fit a
    // single inode-bitmap block (8 * 4096 = 32768 inodes max).
    var inodes_count: u32 = @intCast(@min(@as(u64, 8) * block_size, @max(@as(u64, 16), size_bytes / (16 * 1024))));
    inodes_count = std.mem.alignForward(u32, inodes_count, 8);

    const inode_table_blocks = std.math.divCeil(u32, inodes_count * inode_size, block_size) catch unreachable;

    // Fixed-position metadata blocks.
    // block 0: superblock; block 1: group desc; block 2: block bitmap;
    // block 3: inode bitmap; block 4..: inode table.
    const inode_table_start: u32 = 4;
    const first_data_block_num: u32 = inode_table_start + inode_table_blocks;
    if (first_data_block_num >= total_blocks) return Error.TooSmall;

    const buf = try allocator.alloc(u8, @intCast(total_blocks * @as(u64, block_size)));
    @memset(buf, 0);

    return .{
        .allocator = allocator,
        .buf = buf,
        .total_blocks = total_blocks,
        .inodes_count = inodes_count,
        .inode_table_start = inode_table_start,
        .first_data_block_num = first_data_block_num,
        .next_free_block = first_data_block_num,
        .next_free_ino = first_ino,
        .blocks_used = first_data_block_num, // metadata blocks count as used
        .inodes_used = 0,
    };
}

// ---------------------------------------------------------------------------
// Directory building
// ---------------------------------------------------------------------------

const DirEntry = struct {
    ino: u32,
    name: []u8, // owned
    file_type: u8,
    /// If this entry is a subdirectory built in-memory, the child builder is
    /// kept here so the whole tree can be serialized in one finalize pass at
    /// the end. null for files, symlinks, and already-finished subtrees.
    child: ?*DirBuilder = null,
};

/// Accumulates entries for one directory. The full directory tree is held in
/// memory as a DirBuilder graph and serialized in one finalize pass (see
/// `finishTree`). Holding the tree lets us inject nested install paths (e.g.
/// /usr/bin/foo) before anything is committed to disk.
const DirBuilder = struct {
    allocator: std.mem.Allocator,
    ino: u32,
    parent_ino: u32,
    entries: std.ArrayList(DirEntry),

    fn init(allocator: std.mem.Allocator, ino: u32, parent_ino: u32) DirBuilder {
        return .{ .allocator = allocator, .ino = ino, .parent_ino = parent_ino, .entries = .empty };
    }

    fn deinit(self: *DirBuilder) void {
        for (self.entries.items) |e| {
            if (e.child) |c| {
                c.deinit();
                self.allocator.destroy(c);
            }
            self.allocator.free(e.name);
        }
        self.entries.deinit(self.allocator);
    }

    fn add(self: *DirBuilder, ino: u32, name: []const u8, file_type: u8) !void {
        try self.entries.append(self.allocator, .{
            .ino = ino,
            .name = try self.allocator.dupe(u8, name),
            .file_type = file_type,
        });
    }

    /// Find an existing subdirectory entry by name that is still an in-memory
    /// child builder (i.e. injectable). Returns null if absent or if the name
    /// exists but is not an injectable directory.
    fn findChildDir(self: *DirBuilder, name: []const u8) ?*DirBuilder {
        for (self.entries.items) |e| {
            if (e.file_type == FT_DIR and e.child != null and std.mem.eql(u8, e.name, name)) {
                return e.child;
            }
        }
        return null;
    }

    /// Add (or return existing) a child subdirectory builder for `name`,
    /// allocating a fresh inode if it does not yet exist.
    fn ensureChildDir(self: *DirBuilder, b: *Builder, name: []const u8) !*DirBuilder {
        if (self.findChildDir(name)) |c| return c;
        const child_ino = try b.allocIno();
        const child = try self.allocator.create(DirBuilder);
        child.* = DirBuilder.init(self.allocator, child_ino, self.ino);
        errdefer {
            child.deinit();
            self.allocator.destroy(child);
        }
        try self.entries.append(self.allocator, .{
            .ino = child_ino,
            .name = try self.allocator.dupe(u8, name),
            .file_type = FT_DIR,
            .child = child,
        });
        return child;
    }
};

/// Recurse the source directory, creating inodes/data for files and symlinks
/// and in-memory child DirBuilders for subdirectories, recording them in `out`
/// (the DirBuilder for this level). Directories are NOT serialized here; the
/// whole tree is serialized once in `finishTree` after install paths are
/// injected.
fn writeTree(
    b: *Builder,
    io: std.Io,
    allocator: std.mem.Allocator,
    src: std.Io.Dir,
    out: *DirBuilder,
) !void {
    var it = src.iterate();
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                const child = try out.ensureChildDir(b, entry.name);
                var child_dir = try src.openDir(io, entry.name, .{ .iterate = true });
                defer child_dir.close(io);
                try writeTree(b, io, allocator, child_dir, child);
            },
            .file => {
                const data = try src.readFileAlloc(io, entry.name, allocator, .unlimited);
                defer allocator.free(data);
                const st = src.statFile(io, entry.name, .{}) catch null;
                const mode: u16 = if (st) |s| @intCast(s.permissions.toMode() & 0o7777) else 0o644;
                const child_ino = try writeRegularFile(b, data, mode);
                try out.add(child_ino, entry.name, FT_REG);
            },
            .sym_link => {
                var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const n = try src.readLink(io, entry.name, &link_buf);
                const child_ino = try writeSymlink(b, link_buf[0..n]);
                try out.add(child_ino, entry.name, FT_SYMLINK);
            },
            else => {
                // Skip device nodes, fifos, sockets in this first cut.
            },
        }
    }
}

/// Write a regular file's data into freshly allocated blocks and return its
/// inode number. Supports direct + single-indirect + double-indirect pointers.
fn writeRegularFile(b: *Builder, data: []const u8, mode: u16) !u32 {
    const ino = try b.allocIno();
    const blocks = try writeData(b, data);
    defer b.allocator.free(blocks.ptrs);
    setInode(b, ino, S_IFREG | mode, data.len, 1, blocks.direct[0..blocks.direct_len], blocks.i512);
    return ino;
}

const DataLayout = struct {
    direct: [15]u32 = .{0} ** 15,
    direct_len: usize = 0,
    ptrs: []u32, // all data block numbers (owned), for i_blocks accounting
    i512: u32,
};

/// Copy `data` into data blocks; set up direct/indirect pointers. Returns the
/// 15-pointer array (first 12 direct, [12] single-indirect, [13] double).
fn writeData(b: *Builder, data: []const u8) !DataLayout {
    const nblocks: u32 = @intCast(std.math.divCeil(usize, data.len, block_size) catch 0);
    var ptrs = try b.allocator.alloc(u32, nblocks);
    errdefer b.allocator.free(ptrs);

    var off: usize = 0;
    var i: u32 = 0;
    while (i < nblocks) : (i += 1) {
        const blk = try b.allocBlock();
        ptrs[i] = blk;
        const dst = b.blockPtr(blk);
        const n = @min(block_size, data.len - off);
        @memcpy(dst[0..n], data[off .. off + n]);
        off += n;
    }

    var layout = DataLayout{ .ptrs = ptrs, .i512 = 0, .direct_len = 0 };

    // Direct pointers: up to 12.
    const ptrs_per_block = block_size / 4;
    var meta_blocks: u32 = 0;

    var d: usize = 0;
    while (d < nblocks and d < 12) : (d += 1) {
        layout.direct[d] = ptrs[d];
    }
    layout.direct_len = @min(nblocks, 12);

    // Single indirect.
    if (nblocks > 12) {
        const ind = try b.allocBlock();
        meta_blocks += 1;
        layout.direct[12] = ind;
        const ind_buf = b.blockPtr(ind);
        @memset(ind_buf, 0);
        var k: u32 = 0;
        while (k < ptrs_per_block and (12 + k) < nblocks) : (k += 1) {
            std.mem.writeInt(u32, ind_buf[k * 4 ..][0..4], ptrs[12 + k], .little);
        }
    }

    // Double indirect.
    if (nblocks > 12 + ptrs_per_block) {
        const dind = try b.allocBlock();
        meta_blocks += 1;
        layout.direct[13] = dind;
        const dind_buf = b.blockPtr(dind);
        @memset(dind_buf, 0);
        var remaining_first: u32 = 12 + ptrs_per_block;
        var slot: u32 = 0;
        while (remaining_first < nblocks) : (slot += 1) {
            const single = try b.allocBlock();
            meta_blocks += 1;
            std.mem.writeInt(u32, dind_buf[slot * 4 ..][0..4], single, .little);
            const single_buf = b.blockPtr(single);
            @memset(single_buf, 0);
            var k: u32 = 0;
            while (k < ptrs_per_block and remaining_first < nblocks) : (k += 1) {
                std.mem.writeInt(u32, single_buf[k * 4 ..][0..4], ptrs[remaining_first], .little);
                remaining_first += 1;
            }
        }
    }

    layout.i512 = (nblocks + meta_blocks) * (block_size / 512);
    return layout;
}

/// Write a symlink inode. Fast symlinks (<= 60 bytes) store the target inline
/// in the block-pointer area; longer ones get a data block.
fn writeSymlink(b: *Builder, target: []const u8) !u32 {
    const ino = try b.allocIno();
    if (target.len <= 60) {
        const p = b.inodePtr(ino);
        @memset(p, 0);
        std.mem.writeInt(u16, p[I_MODE..][0..2], S_IFLNK | 0o777, .little);
        std.mem.writeInt(u32, p[I_SIZE_LO..][0..4], @intCast(target.len), .little);
        std.mem.writeInt(u16, p[I_LINKS_COUNT..][0..2], 1, .little);
        @memcpy(p[I_BLOCK .. I_BLOCK + target.len], target);
    } else {
        const blk = try b.allocBlock();
        const dst = b.blockPtr(blk);
        @memcpy(dst[0..target.len], target);
        var ptrs = [_]u32{0} ** 15;
        ptrs[0] = blk;
        setInode(b, ino, S_IFLNK | 0o777, target.len, 1, ptrs[0..1], block_size / 512);
    }
    return ino;
}

/// Install a file at a (possibly nested) path under root. Creates intermediate
/// directories as needed, reusing existing in-memory directories from the
/// source tree where they exist. `path` is like "/orchd-init", "sbin/init",
/// or "/usr/bin/foo".
fn installFile(
    b: *Builder,
    allocator: std.mem.Allocator,
    root: *DirBuilder,
    path: []const u8,
    data: []const u8,
    mode: u16,
) !void {
    _ = allocator;
    const trimmed = std.mem.trimStart(u8, path, "/");
    if (trimmed.len == 0) return;

    // Walk the directory components, creating/reusing intermediate dirs. The
    // final component is the file name.
    var dir = root;
    var rest = trimmed;
    while (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
        const comp = rest[0..slash];
        rest = rest[slash + 1 ..];
        if (comp.len == 0) continue; // tolerate doubled slashes
        dir = try dir.ensureChildDir(b, comp);
    }
    const file_name = rest;
    if (file_name.len == 0) return Error.NotImplemented; // path ended in '/'

    const ino = try writeRegularFile(b, data, mode);
    try dir.add(ino, file_name, FT_REG);
}

/// Serialize the whole in-memory directory tree rooted at `d`, depth-first:
/// finish children before their parent so child inodes/data exist before the
/// parent dir block references them. Subdirectories carry FT_DIR entries.
fn finishTree(b: *Builder, d: *DirBuilder, mode: u16) !void {
    for (d.entries.items) |e| {
        if (e.child) |c| try finishTree(b, c, S_IFDIR | 0o755);
    }
    try finishDir(b, d, mode);
}

/// Serialize a DirBuilder into data blocks and write its inode. Adds "." and
/// ".." automatically. First cut: a single directory data block (so each
/// directory holds a bounded number of entries). TODO: spill to more blocks.
fn finishDir(b: *Builder, d: *DirBuilder, mode: u16) !void {
    const blk = try b.allocBlock();
    const buf = b.blockPtr(blk);
    @memset(buf, 0);

    var pos: usize = 0;
    pos = writeDirEntry(buf, pos, d.ino, ".", FT_DIR, false);
    pos = writeDirEntry(buf, pos, d.parent_ino, "..", FT_DIR, false);

    var links: u16 = 2; // "." and the parent's link to us
    for (d.entries.items, 0..) |e, idx| {
        const last = idx == d.entries.items.len - 1;
        pos = writeDirEntry(buf, pos, e.ino, e.name, e.file_type, last);
        if (e.file_type == FT_DIR) links += 1; // child's ".." points back
    }
    // The final record must span to the end of the block.
    patchLastRecLen(buf, pos);

    var ptrs = [_]u32{0} ** 15;
    ptrs[0] = blk;
    setInode(b, d.ino, mode, block_size, links, ptrs[0..1], block_size / 512);
}

/// Append one ext4 directory entry. Returns the new write position. If `last`,
/// the rec_len is stretched to the block end (patched later anyway).
fn writeDirEntry(buf: []u8, pos: usize, ino: u32, name: []const u8, file_type: u8, last: bool) usize {
    _ = last;
    const name_len: u8 = @intCast(name.len);
    // rec_len = 8 (header) + name, rounded up to 4 bytes.
    const rec_len: u16 = @intCast(std.mem.alignForward(usize, 8 + name.len, 4));
    std.mem.writeInt(u32, buf[pos..][0..4], ino, .little);
    std.mem.writeInt(u16, buf[pos + 4 ..][0..2], rec_len, .little);
    buf[pos + 6] = name_len;
    buf[pos + 7] = file_type;
    @memcpy(buf[pos + 8 .. pos + 8 + name.len], name);
    return pos + rec_len;
}

/// Stretch the last directory record's rec_len so the records cover the whole
/// block, as ext4 requires. `end` is where the last record's data ended.
fn patchLastRecLen(buf: []u8, end: usize) void {
    // Re-walk to find the last record start.
    var pos: usize = 0;
    var last_start: usize = 0;
    while (pos < end) {
        last_start = pos;
        const rec_len = std.mem.readInt(u16, buf[pos + 4 ..][0..2], .little);
        if (rec_len == 0) break;
        pos += rec_len;
    }
    const new_len: u16 = @intCast(block_size - last_start);
    std.mem.writeInt(u16, buf[last_start + 4 ..][0..2], new_len, .little);
}

// ---------------------------------------------------------------------------
// Filesystem metadata: superblock, group descriptor, bitmaps
// ---------------------------------------------------------------------------

fn writeMetadata(b: *Builder) !void {
    writeSuperblock(b);
    writeGroupDescriptor(b);
    writeBlockBitmap(b);
    writeInodeBitmap(b);
}

// Superblock field offsets (within the 1024-byte superblock structure).
const SB_INODES_COUNT = 0x00;
const SB_BLOCKS_COUNT_LO = 0x04;
const SB_FREE_BLOCKS_LO = 0x0C;
const SB_FREE_INODES = 0x10;
const SB_FIRST_DATA_BLOCK = 0x14;
const SB_LOG_BLOCK_SIZE = 0x18;
const SB_BLOCKS_PER_GROUP = 0x20;
const SB_INODES_PER_GROUP = 0x28;
const SB_MAGIC = 0x38;
const SB_STATE = 0x3A;
const SB_ERRORS = 0x3C;
const SB_REV_LEVEL = 0x4C;
const SB_FIRST_INO = 0x54;
const SB_INODE_SIZE = 0x58;
const SB_FEATURE_INCOMPAT = 0x60;

const INCOMPAT_FILETYPE: u32 = 0x2; // dir entries carry a file type byte

fn writeSuperblock(b: *Builder) void {
    // The superblock lives at byte offset 1024 from the start of the image.
    const sb = b.buf[1024 .. 1024 + 1024];
    @memset(sb, 0);

    std.mem.writeInt(u32, sb[SB_INODES_COUNT..][0..4], b.inodes_count, .little);
    std.mem.writeInt(u32, sb[SB_BLOCKS_COUNT_LO..][0..4], b.total_blocks, .little);
    std.mem.writeInt(u32, sb[SB_FREE_BLOCKS_LO..][0..4], b.total_blocks - b.blocks_used, .little);
    std.mem.writeInt(u32, sb[SB_FREE_INODES..][0..4], b.inodes_count - b.inodes_used, .little);
    std.mem.writeInt(u32, sb[SB_FIRST_DATA_BLOCK..][0..4], 0, .little); // 4K blocks -> first data block is 0
    std.mem.writeInt(u32, sb[SB_LOG_BLOCK_SIZE..][0..4], block_size_log, .little);
    std.mem.writeInt(u32, sb[SB_BLOCKS_PER_GROUP..][0..4], 8 * block_size, .little);
    std.mem.writeInt(u32, sb[SB_INODES_PER_GROUP..][0..4], b.inodes_count, .little);
    std.mem.writeInt(u16, sb[SB_MAGIC..][0..2], sb_magic, .little);
    std.mem.writeInt(u16, sb[SB_STATE..][0..2], 1, .little); // cleanly unmounted
    std.mem.writeInt(u16, sb[SB_ERRORS..][0..2], 1, .little); // continue on error
    std.mem.writeInt(u32, sb[SB_REV_LEVEL..][0..4], 1, .little); // dynamic rev
    std.mem.writeInt(u32, sb[SB_FIRST_INO..][0..4], first_ino, .little);
    std.mem.writeInt(u16, sb[SB_INODE_SIZE..][0..2], inode_size, .little);
    std.mem.writeInt(u32, sb[SB_FEATURE_INCOMPAT..][0..4], INCOMPAT_FILETYPE, .little);
}

// Block group descriptor (32 bytes, classic non-64bit form). Sits in block 1.
const GD_BLOCK_BITMAP = 0x00;
const GD_INODE_BITMAP = 0x04;
const GD_INODE_TABLE = 0x08;
const GD_FREE_BLOCKS = 0x0C;
const GD_FREE_INODES = 0x0E;
const GD_USED_DIRS = 0x10;

fn writeGroupDescriptor(b: *Builder) void {
    const gd = b.blockPtr(1)[0..32];
    @memset(gd, 0);
    std.mem.writeInt(u32, gd[GD_BLOCK_BITMAP..][0..4], 2, .little);
    std.mem.writeInt(u32, gd[GD_INODE_BITMAP..][0..4], 3, .little);
    std.mem.writeInt(u32, gd[GD_INODE_TABLE..][0..4], b.inode_table_start, .little);
    std.mem.writeInt(u16, gd[GD_FREE_BLOCKS..][0..2], @intCast(b.total_blocks - b.blocks_used), .little);
    std.mem.writeInt(u16, gd[GD_FREE_INODES..][0..2], @intCast(b.inodes_count - b.inodes_used), .little);
    std.mem.writeInt(u16, gd[GD_USED_DIRS..][0..2], 1, .little); // at least root
}

fn writeBlockBitmap(b: *Builder) void {
    const bm = b.blockPtr(2);
    @memset(bm, 0);
    // Mark blocks [0, blocks_used) as allocated.
    var i: u32 = 0;
    while (i < b.blocks_used) : (i += 1) setBit(bm, i);
    // Mark padding bits past total_blocks as used (ext4 convention).
    var j: u32 = b.total_blocks;
    while (j < 8 * block_size) : (j += 1) setBit(bm, j);
}

fn writeInodeBitmap(b: *Builder) void {
    const bm = b.blockPtr(3);
    @memset(bm, 0);
    // Inodes 1..(next_free_ino-1) are allocated. Bit index is (ino-1).
    var i: u32 = 1;
    while (i < b.next_free_ino) : (i += 1) setBit(bm, i - 1);
    // Reserved inodes 1..10 are always marked used.
    var r: u32 = 0;
    while (r < first_ino - 1) : (r += 1) setBit(bm, r);
    // Mark padding past inodes_count.
    var j: u32 = b.inodes_count;
    while (j < 8 * block_size) : (j += 1) setBit(bm, j);
}

fn setBit(bitmap: []u8, idx: u32) void {
    bitmap[idx / 8] |= (@as(u8, 1) << @intCast(idx % 8));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn readSb(buf: []const u8, comptime T: type, off: usize) T {
    return std.mem.readInt(T, buf[1024 + off ..][0..@sizeOf(T)], .little);
}

test "superblock fields on a small generated image" {
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Make a tiny rootfs.
    const rootfs = "ext4_test_rootfs";
    std.Io.Dir.cwd().deleteTree(io, rootfs) catch {};
    try std.Io.Dir.cwd().createDirPath(io, rootfs);
    defer std.Io.Dir.cwd().deleteTree(io, rootfs) catch {};
    {
        var d = try std.Io.Dir.cwd().openDir(io, rootfs, .{ .iterate = true });
        defer d.close(io);
        try d.writeFile(io, .{ .sub_path = "hello.txt", .data = "hi\n" });
        try d.createDirPath(io, "etc");
        try d.writeFile(io, .{ .sub_path = "etc/motd", .data = "welcome\n" });
    }

    const out = "ext4_test_image.img";
    std.Io.Dir.cwd().deleteFile(io, out) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, out) catch {};

    const size: u64 = 8 * 1024 * 1024; // 8 MiB
    try buildIo(a, io, rootfs, out, size, "/orchd-init", "#!/bin/true\n");

    const img = try std.Io.Dir.cwd().readFileAlloc(io, out, a, .unlimited);
    defer a.free(img);

    try std.testing.expectEqual(@as(usize, size), img.len);

    // s_magic at 1024 + 0x38.
    try std.testing.expectEqual(sb_magic, std.mem.readInt(u16, img[1024 + 0x38 ..][0..2], .little));
    // block size: log_block_size == 2 => 4096.
    try std.testing.expectEqual(@as(u32, block_size_log), readSb(img, u32, SB_LOG_BLOCK_SIZE));
    // blocks_count == size / 4096.
    try std.testing.expectEqual(@as(u32, @intCast(size / block_size)), readSb(img, u32, SB_BLOCKS_COUNT_LO));
    // inode_size == 128.
    try std.testing.expectEqual(inode_size, readSb(img, u16, SB_INODE_SIZE));
    // rev level dynamic (1).
    try std.testing.expectEqual(@as(u32, 1), readSb(img, u32, SB_REV_LEVEL));
    // first_ino == 11.
    try std.testing.expectEqual(first_ino, readSb(img, u32, SB_FIRST_INO));
    // filetype incompat feature set.
    try std.testing.expectEqual(INCOMPAT_FILETYPE, readSb(img, u32, SB_FEATURE_INCOMPAT));

    // free blocks must be < total blocks (we used some).
    const total = readSb(img, u32, SB_BLOCKS_COUNT_LO);
    const free_blocks = readSb(img, u32, SB_FREE_BLOCKS_LO);
    try std.testing.expect(free_blocks < total);
    try std.testing.expect(free_blocks > 0);
}

test "root directory inode and its data block are well-formed" {
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const rootfs = "ext4_test_rootfs2";
    std.Io.Dir.cwd().deleteTree(io, rootfs) catch {};
    try std.Io.Dir.cwd().createDirPath(io, rootfs);
    defer std.Io.Dir.cwd().deleteTree(io, rootfs) catch {};
    {
        var d = try std.Io.Dir.cwd().openDir(io, rootfs, .{ .iterate = true });
        defer d.close(io);
        try d.writeFile(io, .{ .sub_path = "a.txt", .data = "aaa" });
    }

    const out = "ext4_test_image2.img";
    std.Io.Dir.cwd().deleteFile(io, out) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, out) catch {};
    try buildIo(a, io, rootfs, out, 4 * 1024 * 1024, "/orchd-init", "x");

    const img = try std.Io.Dir.cwd().readFileAlloc(io, out, a, .unlimited);
    defer a.free(img);

    // Locate root inode (inode 2) in the inode table, which starts at block 4
    // in our fixed layout.
    const it_off: usize = 4 * block_size + (root_ino - 1) * inode_size;
    const mode = std.mem.readInt(u16, img[it_off + I_MODE ..][0..2], .little);
    try std.testing.expectEqual(S_IFDIR | @as(u16, 0o755), mode);

    // Root's first data block pointer.
    const root_block = std.mem.readInt(u32, img[it_off + I_BLOCK ..][0..4], .little);
    try std.testing.expect(root_block >= 4);

    // First dir entry must be "." pointing at inode 2.
    const dblock = img[root_block * block_size ..][0..block_size];
    try std.testing.expectEqual(root_ino, std.mem.readInt(u32, dblock[0..4], .little));
    const name_len = dblock[6];
    try std.testing.expectEqual(@as(u8, 1), name_len);
    try std.testing.expectEqual(@as(u8, '.'), dblock[8]);
    // file type byte == directory.
    try std.testing.expectEqual(FT_DIR, dblock[7]);
}

// --- image-readback helpers (tests) ---

/// Read the raw inode bytes for `ino` from a built image (fixed layout: inode
/// table starts at block 4).
fn inodeSlice(img: []const u8, ino: u32) []const u8 {
    const off: usize = 4 * block_size + (ino - 1) * inode_size;
    return img[off .. off + inode_size];
}

/// Look up a name within a directory inode's first data block. Returns the
/// child inode number, or null if not found. Walks the ext4 linked-list dir
/// records (good enough for single-block dirs, which is all we emit today).
fn lookupEntry(img: []const u8, dir_ino: u32, name: []const u8) ?u32 {
    const inode = inodeSlice(img, dir_ino);
    const dblock_num = std.mem.readInt(u32, inode[I_BLOCK..][0..4], .little);
    if (dblock_num == 0) return null;
    const block = img[@as(usize, dblock_num) * block_size ..][0..block_size];
    var pos: usize = 0;
    while (pos + 8 <= block_size) {
        const ino = std.mem.readInt(u32, block[pos..][0..4], .little);
        const rec_len = std.mem.readInt(u16, block[pos + 4 ..][0..2], .little);
        if (rec_len == 0) break;
        const name_len = block[pos + 6];
        if (ino != 0 and name_len == name.len and
            std.mem.eql(u8, block[pos + 8 .. pos + 8 + name_len], name))
        {
            return ino;
        }
        pos += rec_len;
    }
    return null;
}

/// Read back a regular file's contents from the image by following its inode's
/// direct block pointers (sufficient for files <= 12 blocks = 48 KiB).
fn readFileFromImage(img: []const u8, a: std.mem.Allocator, ino: u32) ![]u8 {
    const inode = inodeSlice(img, ino);
    const size = std.mem.readInt(u32, inode[I_SIZE_LO..][0..4], .little);
    const out = try a.alloc(u8, size);
    errdefer a.free(out);
    var remaining: usize = size;
    var written: usize = 0;
    var i: usize = 0;
    while (remaining > 0 and i < 12) : (i += 1) {
        const bn = std.mem.readInt(u32, inode[I_BLOCK + i * 4 ..][0..4], .little);
        std.debug.assert(bn != 0);
        const n = @min(@as(usize, block_size), remaining);
        @memcpy(out[written .. written + n], img[@as(usize, bn) * block_size ..][0..n]);
        written += n;
        remaining -= n;
    }
    std.debug.assert(remaining == 0);
    return out;
}

test "regular file contents readable back via its inode/blocks" {
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const rootfs = "ext4_test_rootfs3";
    std.Io.Dir.cwd().deleteTree(io, rootfs) catch {};
    try std.Io.Dir.cwd().createDirPath(io, rootfs);
    defer std.Io.Dir.cwd().deleteTree(io, rootfs) catch {};

    // A multi-block payload to exercise more than one direct pointer.
    const payload = "0123456789ABCDEF" ** 600; // 9600 bytes > 2 blocks
    {
        var d = try std.Io.Dir.cwd().openDir(io, rootfs, .{ .iterate = true });
        defer d.close(io);
        try d.writeFile(io, .{ .sub_path = "data.bin", .data = payload });
    }

    const out = "ext4_test_image3.img";
    std.Io.Dir.cwd().deleteFile(io, out) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, out) catch {};
    try buildIo(a, io, rootfs, out, 8 * 1024 * 1024, "/orchd-init", "x");

    const img = try std.Io.Dir.cwd().readFileAlloc(io, out, a, .unlimited);
    defer a.free(img);

    // Reach the file through the root directory's entries, then read its data.
    const file_ino = lookupEntry(img, root_ino, "data.bin") orelse return error.EntryNotFound;
    const inode = inodeSlice(img, file_ino);
    const mode = std.mem.readInt(u16, inode[I_MODE..][0..2], .little);
    try std.testing.expect(mode & S_IFREG == S_IFREG);
    try std.testing.expectEqual(@as(u32, payload.len), std.mem.readInt(u32, inode[I_SIZE_LO..][0..4], .little));

    const got = try readFileFromImage(img, a, file_ino);
    defer a.free(got);
    try std.testing.expectEqualSlices(u8, payload, got);
}

test "nested install path reachable through parent dir entries" {
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const rootfs = "ext4_test_rootfs4";
    std.Io.Dir.cwd().deleteTree(io, rootfs) catch {};
    try std.Io.Dir.cwd().createDirPath(io, rootfs);
    defer std.Io.Dir.cwd().deleteTree(io, rootfs) catch {};
    {
        // Pre-create /usr so the install reuses the existing dir for one
        // component and creates /usr/bin fresh.
        var d = try std.Io.Dir.cwd().openDir(io, rootfs, .{ .iterate = true });
        defer d.close(io);
        try d.createDirPath(io, "usr");
        try d.writeFile(io, .{ .sub_path = "usr/marker", .data = "m" });
    }

    const out = "ext4_test_image4.img";
    std.Io.Dir.cwd().deleteFile(io, out) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, out) catch {};

    const init_payload = "#!/bin/sh\nexec /sbin/orchd-init\n";
    try buildIo(a, io, rootfs, out, 8 * 1024 * 1024, "/usr/bin/foo", init_payload);

    const img = try std.Io.Dir.cwd().readFileAlloc(io, out, a, .unlimited);
    defer a.free(img);

    // Walk root -> usr -> bin -> foo through the on-disk dir entries.
    const usr_ino = lookupEntry(img, root_ino, "usr") orelse return error.NoUsr;
    // The pre-existing usr/marker must survive alongside the injected bin dir.
    const marker_ino = lookupEntry(img, usr_ino, "marker") orelse return error.NoMarker;
    try std.testing.expect(marker_ino != 0);
    const bin_ino = lookupEntry(img, usr_ino, "bin") orelse return error.NoBin;
    const foo_ino = lookupEntry(img, bin_ino, "foo") orelse return error.NoFoo;

    // /usr/bin must be a directory; /usr/bin/foo a regular file with our bytes.
    const bin_mode = std.mem.readInt(u16, inodeSlice(img, bin_ino)[I_MODE..][0..2], .little);
    try std.testing.expect(bin_mode & S_IFDIR == S_IFDIR);

    const got = try readFileFromImage(img, a, foo_ino);
    defer a.free(got);
    try std.testing.expectEqualSlices(u8, init_payload, got);
}

test "TooLarge fires past the single block group bound" {
    const a = std.testing.allocator;
    // 128 MiB exactly is the max; one block over must be rejected before any
    // image buffer is allocated.
    const over = @as(u64, max_blocks_single_group) * block_size + block_size;
    try std.testing.expectError(Error.TooLarge, initBuilder(a, over));

    // The bound itself is accepted (free the buffer it allocates).
    const at = @as(u64, max_blocks_single_group) * block_size;
    const bld = try initBuilder(a, at);
    a.free(bld.buf);
}
