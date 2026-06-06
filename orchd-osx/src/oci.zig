//! oci.zig — image reference -> local rootfs directory + process config.
//!
//! Boundary: "given an image ref, produce an unpacked rootfs dir and the
//! process defaults (entrypoint/cmd/env/cwd) from the OCI config". Feeds
//! ext4.zig (rootfs -> disk) and the ExecSpec (process to run). Knows nothing
//! about VMs.
//!
//! STATUS: first cut. The pure pieces are implemented and unit-tested:
//!   - reference parsing (registry/repo/tag/digest split, docker.io defaults)
//!   - OCI image-config JSON parsing (Entrypoint++Cmd -> argv, Env, WorkingDir)
//!   - a gzip+tar layer extractor that writes a directory tree (files, dirs,
//!     symlinks) and honours whiteouts (.wh. entries); multi-file tars stream
//!     through the iterator so block padding stays in sync.
//!   - unpackLayout(): an OFFLINE image->rootfs path that reads a local OCI
//!     image layout on disk (index.json -> manifest -> config + layer blobs
//!     under blobs/<algo>/) and unpacks it, fully unit-tested by building a
//!     tiny layout in a temp dir.
//! resolve() wires these together over a Docker Registry v2 / OCI pull with
//! the docker.io bearer-token auth flow, sharing rootfs assembly with
//! unpackLayout(). All registry HTTP(S) goes through `curl` (curlGet /
//! curlGetToFile) so we use the OS TLS stack instead of Zig 0.16's std TLS,
//! which fails to load system CAs and trips TlsInitializationFailed against
//! real-world CDNs. There is a network integration test at the bottom that
//! pulls docker.io/library/alpine:latest and asserts the unpacked rootfs.

const std = @import("std");

pub const Error = error{
    NotImplemented,
    ImageNotFound,
    BadReference,
    AuthFailed,
    ManifestError,
    UnsupportedMediaType,
    NoMatchingPlatform,
    HttpStatus,
    CurlFailed,
};

/// A resolved image: an unpacked rootfs plus the process defaults from its
/// OCI config. `argv` is Entrypoint ++ Cmd.
pub const Image = struct {
    rootfs_dir: []const u8,
    argv: []const []const u8,
    env: []const []const u8,
    cwd: []const u8,
};

// ---------------------------------------------------------------------------
// Reference parsing
// ---------------------------------------------------------------------------

/// A parsed image reference, e.g. "docker.io/library/alpine:latest" splits into
/// registry="registry-1.docker.io", repo="library/alpine", tag="latest".
///
/// Slices either point into the input `reference` or into `owned` (which the
/// caller frees with `deinit`). Defaults match Docker's CLI behaviour:
///   - no registry  -> docker.io (-> registry-1.docker.io for the API host)
///   - no namespace -> "library/" prefix on docker.io
///   - no tag/digest -> "latest"
pub const Reference = struct {
    /// API host to hit (already mapped: docker.io -> registry-1.docker.io).
    registry: []const u8,
    /// Repository path, e.g. "library/alpine".
    repo: []const u8,
    /// Either a tag ("latest") or, if `is_digest`, a "sha256:..." digest.
    reference: []const u8,
    is_digest: bool,
    owned: ?[]u8,

    pub fn deinit(self: Reference, allocator: std.mem.Allocator) void {
        if (self.owned) |o| allocator.free(o);
    }
};

/// Parse an image reference. `owned` ends up holding a synthesized repo string
/// when we have to inject the "library/" default namespace.
pub fn parseReference(allocator: std.mem.Allocator, reference: []const u8) (Error || std.mem.Allocator.Error)!Reference {
    if (reference.len == 0) return Error.BadReference;

    var rest = reference;

    // A leading host[:port]/ counts as a registry iff the first path segment
    // contains a '.' or ':' or equals "localhost" (Docker's heuristic).
    var registry_raw: []const u8 = "docker.io";
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
        const first = rest[0..slash];
        const looks_like_host =
            std.mem.indexOfScalar(u8, first, '.') != null or
            std.mem.indexOfScalar(u8, first, ':') != null or
            std.mem.eql(u8, first, "localhost");
        if (looks_like_host) {
            registry_raw = first;
            rest = rest[slash + 1 ..];
        }
    }

    // Split off the tag or digest. A digest is "@sha256:..."; a tag is ":...".
    // Be careful: a registry port colon already got peeled above, so any colon
    // remaining in `rest` after the last slash is a tag separator.
    var name = rest;
    var ref_part: []const u8 = "latest";
    var is_digest = false;
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| {
        name = rest[0..at];
        ref_part = rest[at + 1 ..];
        is_digest = true;
    } else {
        const last_slash = std.mem.lastIndexOfScalar(u8, rest, '/') orelse 0;
        if (std.mem.indexOfScalarPos(u8, rest, last_slash, ':')) |colon| {
            name = rest[0..colon];
            ref_part = rest[colon + 1 ..];
        }
    }
    if (name.len == 0) return Error.BadReference;

    // docker.io specifics: map host, default the namespace.
    var registry = registry_raw;
    var repo: []const u8 = name;
    var owned: ?[]u8 = null;
    if (std.mem.eql(u8, registry_raw, "docker.io")) {
        registry = "registry-1.docker.io";
        if (std.mem.indexOfScalar(u8, name, '/') == null) {
            repo = try std.fmt.allocPrint(allocator, "library/{s}", .{name});
            owned = @constCast(repo);
        }
    }

    return .{
        .registry = registry,
        .repo = repo,
        .reference = ref_part,
        .is_digest = is_digest,
        .owned = owned,
    };
}

// ---------------------------------------------------------------------------
// OCI image-config JSON parsing
// ---------------------------------------------------------------------------

/// The process defaults extracted from an OCI image config. Slices are owned by
/// the returned `std.json.Parsed`; keep it alive (caller calls `.deinit()`).
const ConfigDoc = struct {
    config: ?struct {
        Entrypoint: ?[]const []const u8 = null,
        Cmd: ?[]const []const u8 = null,
        Env: ?[]const []const u8 = null,
        WorkingDir: ?[]const u8 = null,
    } = null,
};

/// Resolved process config. argv/env are freshly allocated and owned by the
/// caller; free with `deinit`. cwd points into `cwd_buf` (also owned).
pub const ProcessConfig = struct {
    argv: []const []const u8,
    env: []const []const u8,
    cwd: []const u8,

    pub fn deinit(self: ProcessConfig, allocator: std.mem.Allocator) void {
        for (self.argv) |s| allocator.free(s);
        allocator.free(self.argv);
        for (self.env) |s| allocator.free(s);
        allocator.free(self.env);
        allocator.free(self.cwd);
    }
};

/// Parse the OCI image config JSON, producing argv = Entrypoint ++ Cmd,
/// env = Env, cwd = WorkingDir (default "/").
pub fn parseConfig(allocator: std.mem.Allocator, json: []const u8) !ProcessConfig {
    const parsed = try std.json.parseFromSlice(ConfigDoc, allocator, json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const cfg = parsed.value.config;

    // argv = Entrypoint ++ Cmd
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (argv.items) |s| allocator.free(s);
        argv.deinit(allocator);
    }
    if (cfg) |c| {
        if (c.Entrypoint) |ep| for (ep) |s| try argv.append(allocator, try allocator.dupe(u8, s));
        if (c.Cmd) |cmd| for (cmd) |s| try argv.append(allocator, try allocator.dupe(u8, s));
    }

    var env: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (env.items) |s| allocator.free(s);
        env.deinit(allocator);
    }
    if (cfg) |c| {
        if (c.Env) |e| for (e) |s| try env.append(allocator, try allocator.dupe(u8, s));
    }

    const cwd_src: []const u8 = blk: {
        if (cfg) |c| if (c.WorkingDir) |wd| if (wd.len > 0) break :blk wd;
        break :blk "/";
    };
    const cwd = try allocator.dupe(u8, cwd_src);
    errdefer allocator.free(cwd);

    return .{
        .argv = try argv.toOwnedSlice(allocator),
        .env = try env.toOwnedSlice(allocator),
        .cwd = cwd,
    };
}

// ---------------------------------------------------------------------------
// gzip + tar layer extraction
// ---------------------------------------------------------------------------

/// Extract one gzip'd tar layer (`gz_bytes`) into `dest` (an open, iterable
/// directory). Honours overlay whiteouts: a "<dir>/.wh.<name>" entry deletes
/// "<dir>/<name>" from the lower layers we have already written; ".wh..wh..opq"
/// is treated as a directory-clear (best-effort).
pub fn extractLayerGzip(
    allocator: std.mem.Allocator,
    io: std.Io,
    dest: std.Io.Dir,
    gz_bytes: []const u8,
) !void {
    var gz_reader: std.Io.Reader = .fixed(gz_bytes);
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&gz_reader, .gzip, &decompress_buf);
    try extractLayerTar(allocator, io, dest, &decompress.reader);
}

/// Extract a plain (uncompressed) tar stream from `tar_reader` into `dest`.
pub fn extractLayerTar(
    allocator: std.mem.Allocator,
    io: std.Io,
    dest: std.Io.Dir,
    tar_reader: *std.Io.Reader,
) !void {
    var name_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    // Diagnostics make the iterator SKIP entry types it does not model (device
    // nodes, fifos, hardlinks) instead of erroring with TarUnsupportedHeader.
    // Real images (nginx etc.) carry such entries; skipping them is fine for a
    // container rootfs.
    var diag: std.tar.Diagnostics = .{ .allocator = allocator };
    defer diag.deinit();
    var it: std.tar.Iterator = .init(tar_reader, .{
        .file_name_buffer = &name_buf,
        .link_name_buffer = &link_buf,
        .diagnostics = &diag,
    });

    while (try it.next()) |entry| {
        const name = std.mem.trimStart(u8, entry.name, "/");
        if (name.len == 0) continue;

        // Whiteout handling (AUFS/overlay convention).
        const base = std.fs.path.basename(name);
        if (std.mem.startsWith(u8, base, ".wh.")) {
            const dir_part = std.fs.path.dirname(name) orelse "";
            if (std.mem.eql(u8, base, ".wh..wh..opq")) {
                // Opaque dir: clear contents of dir_part. Best-effort.
                clearDir(io, dest, dir_part);
            } else {
                const target_name = base[".wh.".len..];
                const target = if (dir_part.len == 0)
                    target_name
                else
                    std.fmt.bufPrint(&link_buf, "{s}/{s}", .{ dir_part, target_name }) catch continue;
                dest.deleteTree(io, target) catch {};
            }
            continue;
        }

        switch (entry.kind) {
            .directory => {
                dest.createDirPath(io, name) catch |e| switch (e) {
                    error.PathAlreadyExists => {},
                    else => return e,
                };
            },
            .sym_link => {
                if (std.fs.path.dirname(name)) |d| {
                    dest.createDirPath(io, d) catch |e| switch (e) {
                        error.PathAlreadyExists => {},
                        else => return e,
                    };
                }
                dest.deleteFile(io, name) catch {};
                dest.symLink(io, entry.link_name, name, .{}) catch |e| switch (e) {
                    error.PathAlreadyExists => {},
                    else => return e,
                };
            },
            .file => {
                if (std.fs.path.dirname(name)) |d| {
                    dest.createDirPath(io, d) catch |e| switch (e) {
                        error.PathAlreadyExists => {},
                        else => return e,
                    };
                }
                const perms = std.Io.File.Permissions.fromMode(
                    if (entry.mode == 0) 0o644 else @intCast(entry.mode & 0o7777),
                );
                var f = try dest.createFile(io, name, .{ .permissions = perms });
                defer f.close(io);
                // Stream the body through the iterator so it keeps its own
                // accounting (unread_file_bytes + block padding) in sync. We
                // must NOT read the tar reader directly here, or the next
                // header lands mid-stream and parsing fails (TarHeader).
                var wbuf: [64 * 1024]u8 = undefined;
                var fw = f.writerStreaming(io, &wbuf);
                try it.streamRemaining(entry, &fw.interface);
                try fw.interface.flush();
            },
        }
    }
}

fn clearDir(io: std.Io, parent: std.Io.Dir, sub: []const u8) void {
    var dir = if (sub.len == 0)
        parent
    else
        parent.openDir(io, sub, .{ .iterate = true }) catch return;
    defer if (sub.len != 0) dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        dir.deleteTree(io, entry.name) catch {};
    }
}

// ---------------------------------------------------------------------------
// Registry pull (network)
// ---------------------------------------------------------------------------

const media_manifest_list = "application/vnd.docker.distribution.manifest.list.v2+json";
const media_oci_index = "application/vnd.oci.image.index.v1+json";
const media_manifest_v2 = "application/vnd.docker.distribution.manifest.v2+json";
const media_oci_manifest = "application/vnd.oci.image.manifest.v1+json";

const accept_manifests = media_manifest_list ++ ", " ++
    media_oci_index ++ ", " ++
    media_manifest_v2 ++ ", " ++
    media_oci_manifest;

// Minimal manifest shapes we parse out of registry JSON.
const Descriptor = struct {
    mediaType: ?[]const u8 = null,
    digest: []const u8,
    size: ?u64 = null,
    platform: ?struct {
        architecture: ?[]const u8 = null,
        os: ?[]const u8 = null,
    } = null,
};

const IndexDoc = struct {
    manifests: []const Descriptor = &.{},
};

const ManifestDoc = struct {
    config: Descriptor,
    layers: []const Descriptor = &.{},
};

// ---------------------------------------------------------------------------
// Shared rootfs assembly (used by both the offline layout path and the live
// registry pull). Given a config blob and an ordered list of layer blobs, this
// parses the process config and unpacks the layers into <work_dir>/rootfs.
// ---------------------------------------------------------------------------

/// Open (creating if needed) the rootfs directory under `work_dir` and return
/// the absolute-ish path plus the open iterable dir. Caller closes the dir and
/// owns the returned path string.
fn openRootfs(allocator: std.mem.Allocator, io: std.Io, work_dir: []const u8) !struct { path: []u8, dir: std.Io.Dir } {
    const rootfs_dir = try std.fmt.allocPrint(allocator, "{s}/rootfs", .{work_dir});
    errdefer allocator.free(rootfs_dir);
    std.Io.Dir.cwd().createDirPath(io, rootfs_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    const dir = try std.Io.Dir.cwd().openDir(io, rootfs_dir, .{ .iterate = true });
    return .{ .path = rootfs_dir, .dir = dir };
}

/// Detect whether `blob` is a gzip stream (magic 0x1f 0x8b) vs a plain tar.
/// docker.io ships gzip'd tar; OCI also permits uncompressed tar layers.
fn isGzip(blob: []const u8) bool {
    return blob.len >= 2 and blob[0] == 0x1f and blob[1] == 0x8b;
}

/// Detect a zstd frame by its magic number (0x28 0xB5 0x2F 0xFD, little-endian).
/// OCI permits application/vnd.oci.image.layer.v1.tar+zstd layers.
fn isZstd(blob: []const u8) bool {
    return blob.len >= 4 and blob[0] == 0x28 and blob[1] == 0xb5 and
        blob[2] == 0x2f and blob[3] == 0xfd;
}

/// Extract one zstd'd tar layer into `dest`. Uses std.compress.zstd, which
/// exists in Zig 0.16. A heap window buffer keeps the (up to 8 MiB) sliding
/// window off the stack.
pub fn extractLayerZstd(
    allocator: std.mem.Allocator,
    io: std.Io,
    dest: std.Io.Dir,
    zstd_bytes: []const u8,
) !void {
    var in: std.Io.Reader = .fixed(zstd_bytes);
    const window_len = std.compress.zstd.default_window_len;
    const buf = try allocator.alloc(u8, window_len + std.compress.zstd.block_size_max);
    defer allocator.free(buf);
    var dec: std.compress.zstd.Decompress = .init(&in, buf, .{ .window_len = window_len });
    try extractLayerTar(allocator, io, dest, &dec.reader);
}

/// Extract one layer blob into `dest`, dispatching on gzip / zstd / plain tar
/// by magic bytes (so both the offline layout path and the registry pull share
/// one code path regardless of declared mediaType).
fn extractLayerBlob(allocator: std.mem.Allocator, io: std.Io, dest: std.Io.Dir, blob: []const u8) !void {
    if (isGzip(blob)) {
        try extractLayerGzip(allocator, io, dest, blob);
    } else if (isZstd(blob)) {
        try extractLayerZstd(allocator, io, dest, blob);
    } else {
        var reader: std.Io.Reader = .fixed(blob);
        try extractLayerTar(allocator, io, dest, &reader);
    }
}

// --- offline OCI image layout (on-disk) ---

const IndexManifestRef = struct {
    mediaType: ?[]const u8 = null,
    digest: []const u8,
    size: ?u64 = null,
    platform: ?struct {
        architecture: ?[]const u8 = null,
        os: ?[]const u8 = null,
    } = null,
};

const LayoutIndexDoc = struct {
    manifests: []const IndexManifestRef = &.{},
};

/// Map a "sha256:<hex>" digest to its blob path under an OCI layout's
/// blobs/<algo>/<hex>. Caller frees the returned path.
fn blobPath(allocator: std.mem.Allocator, layout_dir: []const u8, digest: []const u8) ![]u8 {
    const colon = std.mem.indexOfScalar(u8, digest, ':') orelse return Error.ManifestError;
    const algo = digest[0..colon];
    const hex = digest[colon + 1 ..];
    return std.fmt.allocPrint(allocator, "{s}/blobs/{s}/{s}", .{ layout_dir, algo, hex });
}

/// Read a blob by digest from an on-disk OCI layout. Caller frees the bytes.
fn readBlob(allocator: std.mem.Allocator, io: std.Io, layout_dir: []const u8, digest: []const u8) ![]u8 {
    const path = try blobPath(allocator, layout_dir, digest);
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
}

/// Unpack a local OCI image layout (the directory produced by e.g. `skopeo copy
/// docker://... oci:DIR` or `podman save --format oci-dir`). Reads index.json
/// -> picks the linux/arm64 image manifest (or the sole manifest) -> reads its
/// config + layer blobs from blobs/<algo>/ -> unpacks into <out_rootfs_dir>'s
/// parent as <out_rootfs_dir>/rootfs, returning the process defaults.
///
/// This is the offline, network-free image->rootfs path. The returned Image's
/// slices are allocated with `allocator`; rootfs_dir is owned by the caller.
pub fn unpackLayout(
    allocator: std.mem.Allocator,
    io: std.Io,
    oci_layout_dir: []const u8,
    out_rootfs_dir: []const u8,
) !Image {
    // 1. index.json -> choose an image manifest.
    const index_path = try std.fmt.allocPrint(allocator, "{s}/index.json", .{oci_layout_dir});
    defer allocator.free(index_path);
    const index_body = std.Io.Dir.cwd().readFileAlloc(io, index_path, allocator, .unlimited) catch |e| switch (e) {
        error.FileNotFound => return Error.ManifestError,
        else => return e,
    };
    defer allocator.free(index_body);

    const index = try std.json.parseFromSlice(LayoutIndexDoc, allocator, index_body, .{ .ignore_unknown_fields = true });
    defer index.deinit();
    if (index.value.manifests.len == 0) return Error.ManifestError;

    const chosen_digest = pickLayoutManifest(index.value.manifests, "arm64", "linux") orelse
        return Error.NoMatchingPlatform;

    // 2. image manifest -> config + layers.
    const manifest_body = try readBlob(allocator, io, oci_layout_dir, chosen_digest);
    defer allocator.free(manifest_body);
    const manifest = try std.json.parseFromSlice(ManifestDoc, allocator, manifest_body, .{ .ignore_unknown_fields = true });
    defer manifest.deinit();

    // 3. config blob -> process defaults.
    const config_body = try readBlob(allocator, io, oci_layout_dir, manifest.value.config.digest);
    defer allocator.free(config_body);
    const pcfg = try parseConfig(allocator, config_body);

    // 4. unpack layers in order into out_rootfs_dir/rootfs.
    var rf = try openRootfs(allocator, io, out_rootfs_dir);
    defer rf.dir.close(io);

    for (manifest.value.layers) |layer| {
        const blob = try readBlob(allocator, io, oci_layout_dir, layer.digest);
        defer allocator.free(blob);
        try extractLayerBlob(allocator, io, rf.dir, blob);
    }

    return .{
        .rootfs_dir = rf.path,
        .argv = pcfg.argv,
        .env = pcfg.env,
        .cwd = pcfg.cwd,
    };
}

/// Choose an image manifest from an index. Prefer the entry matching
/// arch/os; if no entry carries platform info (single-manifest layouts often
/// omit it), fall back to the first manifest.
fn pickLayoutManifest(manifests: []const IndexManifestRef, arch: []const u8, os: []const u8) ?[]const u8 {
    var any_platform = false;
    for (manifests) |m| {
        const p = m.platform orelse continue;
        any_platform = true;
        const a = p.architecture orelse continue;
        const o = p.os orelse continue;
        if (std.mem.eql(u8, a, arch) and std.mem.eql(u8, o, os)) return m.digest;
    }
    if (!any_platform) return manifests[0].digest;
    return null;
}

/// Resolve and unpack `reference` into a rootfs under `work_dir`.
///
/// Returns an `Image` whose `rootfs_dir` is `work_dir/rootfs` and whose
/// argv/env/cwd come from the OCI config. The returned slices are allocated
/// with `allocator` and leak by design here (the caller owns `work_dir` and the
/// process config for the lifetime of the run); a future cleanup pass can hand
/// back an owned struct with a deinit.
///
/// This is the LIVE network path. All registry HTTP(S) goes through `curl`
/// (curlGet / curlGetToFile) so the request uses the OS TLS stack and the
/// system CA bundle; Zig 0.16's std TLS does not load system CAs and fails
/// (TlsInitializationFailed) against docker.io's CDN. The flow is the standard
/// Docker Registry v2 bearer-token dance: GET a pull token from auth.docker.io,
/// then GET the manifest with Authorization: Bearer; if that manifest is an
/// index/manifest-list, pick linux/arm64 and re-GET; then GET the config blob
/// and each layer blob. Layers stream to a temp file (curlGetToFile) so we do
/// not hold a whole layer in memory before extraction. Shares rootfs assembly
/// (openRootfs, extractLayerBlob, parseConfig) with the offline `unpackLayout`.
pub fn resolve(
    allocator: std.mem.Allocator,
    io: std.Io,
    work_dir: []const u8,
    reference: []const u8,
) !Image {
    const ref = try parseReference(allocator, reference);
    defer ref.deinit(allocator);

    // Bearer token for this repo (docker.io requires one even for public pulls).
    const token = try fetchToken(allocator, io, ref.registry, ref.repo);
    defer if (token) |t| allocator.free(t);

    var auth_buf: [4096]u8 = undefined;
    const auth_header: ?[]const u8 = if (token) |t|
        std.fmt.bufPrint(&auth_buf, "Authorization: Bearer {s}", .{t}) catch return Error.AuthFailed
    else
        null;

    const accept_header = "Accept: " ++ accept_manifests;

    // 1. Manifest (may be an index/list -> pick linux/arm64).
    const manifest_url = try std.fmt.allocPrint(allocator, "https://{s}/v2/{s}/manifests/{s}", .{
        ref.registry, ref.repo, ref.reference,
    });
    defer allocator.free(manifest_url);

    const manifest_body = try curlGet(allocator, io, manifest_url, headerSlice(&.{ accept_header, auth_header }));
    defer allocator.free(manifest_body);

    var image_manifest_body = manifest_body;
    var image_manifest_owned = false;
    defer if (image_manifest_owned) allocator.free(image_manifest_body);

    // If it is an index/list, select the linux/arm64 image manifest and re-GET.
    if (looksLikeIndex(manifest_body)) {
        const idx = try std.json.parseFromSlice(IndexDoc, allocator, manifest_body, .{ .ignore_unknown_fields = true });
        defer idx.deinit();
        const chosen = pickPlatform(idx.value.manifests, "arm64", "linux") orelse
            return Error.NoMatchingPlatform;
        const url = try std.fmt.allocPrint(allocator, "https://{s}/v2/{s}/manifests/{s}", .{
            ref.registry, ref.repo, chosen.digest,
        });
        defer allocator.free(url);
        image_manifest_body = try curlGet(allocator, io, url, headerSlice(&.{ accept_header, auth_header }));
        image_manifest_owned = true;
    }

    const manifest = try std.json.parseFromSlice(ManifestDoc, allocator, image_manifest_body, .{ .ignore_unknown_fields = true });
    defer manifest.deinit();

    // 2. Config blob -> process defaults.
    const config_url = try std.fmt.allocPrint(allocator, "https://{s}/v2/{s}/blobs/{s}", .{
        ref.registry, ref.repo, manifest.value.config.digest,
    });
    defer allocator.free(config_url);
    const config_body = try curlGet(allocator, io, config_url, headerSlice(&.{ "Accept: */*", auth_header }));
    defer allocator.free(config_body);

    const pcfg = try parseConfig(allocator, config_body);
    // On the success path, ownership of argv/env/cwd transfers to the returned
    // Image. On any error below (e.g. a mid-pull curl failure) free them here so
    // a failed resolve does not leak.
    errdefer pcfg.deinit(allocator);

    // 3. Layers -> unpack into work_dir/rootfs in order. Same rootfs assembly
    // as the offline layout path (openRootfs + extractLayerBlob). Each blob is
    // streamed to a temp file by curl, then read back and extracted (dispatch
    // on gzip/zstd/plain tar by magic, covering tar+gzip and tar+zstd layers).
    var rf = try openRootfs(allocator, io, work_dir);
    defer rf.dir.close(io);
    errdefer allocator.free(rf.path);

    const blob_path = try std.fmt.allocPrint(allocator, "{s}/.layer.blob", .{work_dir});
    defer allocator.free(blob_path);
    defer std.Io.Dir.cwd().deleteFile(io, blob_path) catch {};

    for (manifest.value.layers) |layer| {
        const url = try std.fmt.allocPrint(allocator, "https://{s}/v2/{s}/blobs/{s}", .{
            ref.registry, ref.repo, layer.digest,
        });
        defer allocator.free(url);
        try curlGetToFile(allocator, io, url, headerSlice(&.{ "Accept: */*", auth_header }), blob_path);
        const blob = try std.Io.Dir.cwd().readFileAlloc(io, blob_path, allocator, .unlimited);
        defer allocator.free(blob);
        try extractLayerBlob(allocator, io, rf.dir, blob);
    }

    return .{
        .rootfs_dir = rf.path,
        .argv = pcfg.argv,
        .env = pcfg.env,
        .cwd = pcfg.cwd,
    };
}

fn looksLikeIndex(body: []const u8) bool {
    // Cheap discriminator: index/list docs carry a "manifests" array. Image
    // manifests carry a top-level "layers" array instead.
    return std.mem.indexOf(u8, body, "\"manifests\"") != null and
        std.mem.indexOf(u8, body, "\"layers\"") == null;
}

fn pickPlatform(manifests: []const Descriptor, arch: []const u8, os: []const u8) ?Descriptor {
    for (manifests) |m| {
        const p = m.platform orelse continue;
        const a = p.architecture orelse continue;
        const o = p.os orelse continue;
        if (std.mem.eql(u8, a, arch) and std.mem.eql(u8, o, os)) return m;
    }
    return null;
}

// --- curl transport ---

/// Collapse a small fixed array of optional headers into the non-null ones.
/// Lets call sites write `headerSlice(&.{ accept, maybe_auth })` where the auth
/// header is `null` when there is no token.
fn headerSlice(headers: []const ?[]const u8) []const ?[]const u8 {
    return headers;
}

/// GET `url` via `curl -sSL --fail-with-body`, adding one `-H` per non-null
/// header. Returns the response body (caller frees). On a non-zero curl exit
/// (network error or HTTP >= 400), returns Error.CurlFailed.
///
/// `curl` uses the OS TLS stack and the system trust store, sidestepping Zig
/// 0.16's std TLS (which never loads system CAs and fails against docker.io).
fn curlGet(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    headers: []const ?[]const u8,
) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "curl");
    try argv.append(allocator, "-sSL");
    try argv.append(allocator, "--fail-with-body");
    for (headers) |h| {
        if (h) |hv| {
            try argv.append(allocator, "-H");
            try argv.append(allocator, hv);
        }
    }
    try argv.append(allocator, url);

    const result = try std.process.run(allocator, io, .{ .argv = argv.items });
    defer allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.log.err("curl GET {s} failed (exit {d}): {s}", .{ url, code, result.stderr });
            return Error.CurlFailed;
        },
        else => {
            std.log.err("curl GET {s} terminated abnormally", .{url});
            return Error.CurlFailed;
        },
    }
    return result.stdout;
}

/// GET `url` via `curl -sSL --fail -o <out_path>`, streaming the body straight
/// to disk so large layer blobs never sit in memory. Adds one `-H` per non-null
/// header. On a non-zero curl exit, returns Error.CurlFailed.
fn curlGetToFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    headers: []const ?[]const u8,
    out_path: []const u8,
) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "curl");
    try argv.append(allocator, "-sSL");
    try argv.append(allocator, "--fail");
    try argv.append(allocator, "-o");
    try argv.append(allocator, out_path);
    for (headers) |h| {
        if (h) |hv| {
            try argv.append(allocator, "-H");
            try argv.append(allocator, hv);
        }
    }
    try argv.append(allocator, url);

    const result = try std.process.run(allocator, io, .{ .argv = argv.items });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.log.err("curl GET {s} -> {s} failed (exit {d}): {s}", .{ url, out_path, code, result.stderr });
            return Error.CurlFailed;
        },
        else => {
            std.log.err("curl GET {s} terminated abnormally", .{url});
            return Error.CurlFailed;
        },
    }
}

// --- bearer-token auth ---

/// Fetch a pull token for `repo` from the registry's auth service.
///
/// docker.io advertises its realm/service via a 401 WWW-Authenticate challenge,
/// but in practice the realm and service are fixed (auth.docker.io /
/// registry.docker.io), so we hit the token endpoint directly via curl. For a
/// non-docker.io registry that needs no token we return null and the caller
/// makes anonymous requests. Returns an owned token string (or null).
fn fetchToken(allocator: std.mem.Allocator, io: std.Io, registry: []const u8, repo: []const u8) !?[]u8 {
    // Only the docker.io flow is wired here; other registries pull anonymously.
    if (!std.mem.eql(u8, registry, "registry-1.docker.io")) return null;

    const token_url = try std.fmt.allocPrint(
        allocator,
        "https://auth.docker.io/token?service=registry.docker.io&scope=repository:{s}:pull",
        .{repo},
    );
    defer allocator.free(token_url);

    const body = try curlGet(allocator, io, token_url, &.{});
    defer allocator.free(body);

    const TokenDoc = struct {
        token: ?[]const u8 = null,
        access_token: ?[]const u8 = null,
    };
    const parsed = try std.json.parseFromSlice(TokenDoc, allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const tok = parsed.value.token orelse parsed.value.access_token orelse return Error.AuthFailed;
    return try allocator.dupe(u8, tok);
}

// ---------------------------------------------------------------------------
// Tests (pure pieces only; these run offline, importing only std).
// ---------------------------------------------------------------------------

test "parseReference: docker.io short form gets library/ + latest" {
    const a = std.testing.allocator;
    const r = try parseReference(a, "alpine");
    defer r.deinit(a);
    try std.testing.expectEqualStrings("registry-1.docker.io", r.registry);
    try std.testing.expectEqualStrings("library/alpine", r.repo);
    try std.testing.expectEqualStrings("latest", r.reference);
    try std.testing.expect(!r.is_digest);
}

test "parseReference: explicit tag and namespace" {
    const a = std.testing.allocator;
    const r = try parseReference(a, "docker.io/library/alpine:3.19");
    defer r.deinit(a);
    try std.testing.expectEqualStrings("registry-1.docker.io", r.registry);
    try std.testing.expectEqualStrings("library/alpine", r.repo);
    try std.testing.expectEqualStrings("3.19", r.reference);
}

test "parseReference: custom registry with port" {
    const a = std.testing.allocator;
    const r = try parseReference(a, "localhost:5000/team/app:v1");
    defer r.deinit(a);
    try std.testing.expectEqualStrings("localhost:5000", r.registry);
    try std.testing.expectEqualStrings("team/app", r.repo);
    try std.testing.expectEqualStrings("v1", r.reference);
}

test "parseReference: digest reference" {
    const a = std.testing.allocator;
    const r = try parseReference(a, "ghcr.io/foo/bar@sha256:deadbeef");
    defer r.deinit(a);
    try std.testing.expectEqualStrings("ghcr.io", r.registry);
    try std.testing.expectEqualStrings("foo/bar", r.repo);
    try std.testing.expectEqualStrings("sha256:deadbeef", r.reference);
    try std.testing.expect(r.is_digest);
}

test "parseConfig: Entrypoint ++ Cmd, Env, WorkingDir" {
    const a = std.testing.allocator;
    const json =
        \\{"architecture":"arm64","os":"linux","config":{
        \\  "Entrypoint":["/bin/sh","-c"],
        \\  "Cmd":["echo hi"],
        \\  "Env":["PATH=/usr/bin","TERM=xterm"],
        \\  "WorkingDir":"/app"
        \\}}
    ;
    const pc = try parseConfig(a, json);
    defer pc.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), pc.argv.len);
    try std.testing.expectEqualStrings("/bin/sh", pc.argv[0]);
    try std.testing.expectEqualStrings("-c", pc.argv[1]);
    try std.testing.expectEqualStrings("echo hi", pc.argv[2]);
    try std.testing.expectEqual(@as(usize, 2), pc.env.len);
    try std.testing.expectEqualStrings("PATH=/usr/bin", pc.env[0]);
    try std.testing.expectEqualStrings("/app", pc.cwd);
}

test "parseConfig: empty config defaults cwd to /" {
    const a = std.testing.allocator;
    const pc = try parseConfig(a, "{}");
    defer pc.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), pc.argv.len);
    try std.testing.expectEqual(@as(usize, 0), pc.env.len);
    try std.testing.expectEqualStrings("/", pc.cwd);
}

// --- tar/gzip extraction round-trip ---

// Build a minimal ustar header+data block for one regular file.
fn tarAppendFile(buf: *std.ArrayList(u8), a: std.mem.Allocator, name: []const u8, content: []const u8) !void {
    var hdr = [_]u8{0} ** 512;
    @memcpy(hdr[0..name.len], name);
    // mode (octal, 8 bytes incl NUL): 0000644
    _ = std.fmt.bufPrint(hdr[100..108], "0000644\x00", .{}) catch unreachable;
    // uid/gid
    _ = std.fmt.bufPrint(hdr[108..116], "0000000\x00", .{}) catch unreachable;
    _ = std.fmt.bufPrint(hdr[116..124], "0000000\x00", .{}) catch unreachable;
    // size (octal, 12 bytes incl NUL)
    var size_buf: [12]u8 = undefined;
    const size_str = std.fmt.bufPrint(&size_buf, "{o:0>11}", .{content.len}) catch unreachable;
    @memcpy(hdr[124 .. 124 + size_str.len], size_str);
    // mtime
    _ = std.fmt.bufPrint(hdr[136..148], "00000000000\x00", .{}) catch unreachable;
    // typeflag '0' = regular file
    hdr[156] = '0';
    // ustar magic
    @memcpy(hdr[257..263], "ustar\x00");
    hdr[263] = '0';
    hdr[264] = '0';
    // checksum: spaces, sum, then octal
    @memset(hdr[148..156], ' ');
    var sum: u32 = 0;
    for (hdr) |b| sum += b;
    _ = std.fmt.bufPrint(hdr[148..156], "{o:0>6}\x00 ", .{sum}) catch unreachable;

    try buf.appendSlice(a, &hdr);
    try buf.appendSlice(a, content);
    // pad data to 512.
    const pad = (512 - (content.len % 512)) % 512;
    try buf.appendNTimes(a, 0, pad);
}

test "extractLayerTar: writes a regular file from a tar stream" {
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Build a tiny tar with one file.
    var tar: std.ArrayList(u8) = .empty;
    defer tar.deinit(a);
    try tarAppendFile(&tar, a, "hello.txt", "world\n");
    // two zero blocks = end of archive
    try tar.appendNTimes(a, 0, 1024);

    // Make a scratch dir.
    const tmp_name = "oci_test_tar_scratch";
    std.Io.Dir.cwd().deleteTree(io, tmp_name) catch {};
    try std.Io.Dir.cwd().createDirPath(io, tmp_name);
    defer std.Io.Dir.cwd().deleteTree(io, tmp_name) catch {};
    var dest = try std.Io.Dir.cwd().openDir(io, tmp_name, .{ .iterate = true });
    defer dest.close(io);

    var reader: std.Io.Reader = .fixed(tar.items);
    try extractLayerTar(a, io, dest, &reader);

    const got = try dest.readFileAlloc(io, "hello.txt", a, .unlimited);
    defer a.free(got);
    try std.testing.expectEqualStrings("world\n", got);
}

test "extractLayerGzip: gzip round-trip of a tar layer" {
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // tar bytes
    var tar: std.ArrayList(u8) = .empty;
    defer tar.deinit(a);
    try tarAppendFile(&tar, a, "etc/motd", "hi from gzip\n");
    try tar.appendNTimes(a, 0, 1024);

    // gzip-compress them with std.compress.flate.Compress.
    var aw: std.Io.Writer.Allocating = try .initCapacity(a, 4096);
    defer aw.deinit();
    var cbuf: [std.compress.flate.max_window_len]u8 = undefined;
    var comp = try std.compress.flate.Compress.init(&aw.writer, &cbuf, .gzip, .default);
    try comp.writer.writeAll(tar.items);
    try comp.finish();
    try aw.writer.flush();
    const gz_bytes = aw.written();

    const tmp_name = "oci_test_gz_scratch";
    std.Io.Dir.cwd().deleteTree(io, tmp_name) catch {};
    try std.Io.Dir.cwd().createDirPath(io, tmp_name);
    defer std.Io.Dir.cwd().deleteTree(io, tmp_name) catch {};
    var dest = try std.Io.Dir.cwd().openDir(io, tmp_name, .{ .iterate = true });
    defer dest.close(io);

    try extractLayerGzip(a, io, dest, gz_bytes);

    const got = try dest.readFileAlloc(io, "etc/motd", a, .unlimited);
    defer a.free(got);
    try std.testing.expectEqualStrings("hi from gzip\n", got);
}

// --- offline OCI image layout round-trip ---

/// gzip-compress `bytes` into a fresh allocation (caller frees).
fn gzipAlloc(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = try .initCapacity(a, bytes.len + 64);
    defer aw.deinit();
    var cbuf: [std.compress.flate.max_window_len]u8 = undefined;
    var comp = try std.compress.flate.Compress.init(&aw.writer, &cbuf, .gzip, .default);
    try comp.writer.writeAll(bytes);
    try comp.finish();
    try aw.writer.flush();
    return a.dupe(u8, aw.written());
}

/// sha256 hex digest of `bytes` (lowercase, no prefix). Caller frees.
fn sha256Hex(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.allocPrint(a, "{x}", .{&digest});
}

/// Write a blob into <layout>/blobs/sha256/<hex> and return its "sha256:<hex>"
/// digest (caller frees).
fn putBlob(a: std.mem.Allocator, io: std.Io, layout: std.Io.Dir, bytes: []const u8) ![]u8 {
    const hex = try sha256Hex(a, bytes);
    defer a.free(hex);
    const path = try std.fmt.allocPrint(a, "blobs/sha256/{s}", .{hex});
    defer a.free(path);
    try layout.writeFile(io, .{ .sub_path = path, .data = bytes });
    return std.fmt.allocPrint(a, "sha256:{s}", .{hex});
}

/// Free an Image returned by unpackLayout in tests (mirrors how the live path
/// would eventually hand back an owned struct).
fn freeImage(a: std.mem.Allocator, img: Image) void {
    a.free(img.rootfs_dir);
    for (img.argv) |s| a.free(s);
    a.free(img.argv);
    for (img.env) |s| a.free(s);
    a.free(img.env);
    a.free(img.cwd);
}

test "unpackLayout: builds a local OCI layout and unpacks it offline" {
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const layout_dir = "oci_test_layout";
    const work_dir = "oci_test_layout_work";
    std.Io.Dir.cwd().deleteTree(io, layout_dir) catch {};
    std.Io.Dir.cwd().deleteTree(io, work_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, layout_dir);
    try std.Io.Dir.cwd().createDirPath(io, work_dir);
    defer std.Io.Dir.cwd().deleteTree(io, layout_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, work_dir) catch {};

    var layout = try std.Io.Dir.cwd().openDir(io, layout_dir, .{ .iterate = true });
    defer layout.close(io);
    try layout.createDirPath(io, "blobs/sha256");

    // Two gzip'd tar layers: layer 2 overlays a file from layer 1.
    var layer1: std.ArrayList(u8) = .empty;
    defer layer1.deinit(a);
    try tarAppendFile(&layer1, a, "etc/hostname", "base\n");
    try tarAppendFile(&layer1, a, "bin/sh", "#!fake-shell\n");
    try layer1.appendNTimes(a, 0, 1024);

    var layer2: std.ArrayList(u8) = .empty;
    defer layer2.deinit(a);
    try tarAppendFile(&layer2, a, "etc/hostname", "override\n");
    try tarAppendFile(&layer2, a, "app/run", "payload\n");
    try layer2.appendNTimes(a, 0, 1024);

    const gz1 = try gzipAlloc(a, layer1.items);
    defer a.free(gz1);
    const gz2 = try gzipAlloc(a, layer2.items);
    defer a.free(gz2);

    const layer1_digest = try putBlob(a, io, layout, gz1);
    defer a.free(layer1_digest);
    const layer2_digest = try putBlob(a, io, layout, gz2);
    defer a.free(layer2_digest);

    // Config blob with process defaults.
    const config_json =
        \\{"architecture":"arm64","os":"linux","config":{
        \\  "Entrypoint":["/bin/sh"],
        \\  "Cmd":["-c","echo hi"],
        \\  "Env":["PATH=/usr/bin:/bin"],
        \\  "WorkingDir":"/app"
        \\}}
    ;
    const config_digest = try putBlob(a, io, layout, config_json);
    defer a.free(config_digest);

    // Image manifest referencing the config + ordered layers.
    const manifest_json = try std.fmt.allocPrint(a,
        \\{{"schemaVersion":2,
        \\"mediaType":"application/vnd.oci.image.manifest.v1+json",
        \\"config":{{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"{s}","size":{d}}},
        \\"layers":[
        \\{{"mediaType":"application/vnd.oci.image.layer.v1.tar+gzip","digest":"{s}","size":{d}}},
        \\{{"mediaType":"application/vnd.oci.image.layer.v1.tar+gzip","digest":"{s}","size":{d}}}
        \\]}}
    , .{ config_digest, config_json.len, layer1_digest, gz1.len, layer2_digest, gz2.len });
    defer a.free(manifest_json);
    const manifest_digest = try putBlob(a, io, layout, manifest_json);
    defer a.free(manifest_digest);

    // index.json points at the manifest, tagged linux/arm64.
    const index_json = try std.fmt.allocPrint(a,
        \\{{"schemaVersion":2,
        \\"manifests":[
        \\{{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"{s}","size":{d},
        \\"platform":{{"architecture":"arm64","os":"linux"}}}}
        \\]}}
    , .{ manifest_digest, manifest_json.len });
    defer a.free(index_json);
    try layout.writeFile(io, .{ .sub_path = "index.json", .data = index_json });

    // Unpack offline.
    const img = try unpackLayout(a, io, layout_dir, work_dir);
    defer freeImage(a, img);

    // Process config came through correctly (Entrypoint ++ Cmd).
    try std.testing.expectEqual(@as(usize, 3), img.argv.len);
    try std.testing.expectEqualStrings("/bin/sh", img.argv[0]);
    try std.testing.expectEqualStrings("-c", img.argv[1]);
    try std.testing.expectEqualStrings("echo hi", img.argv[2]);
    try std.testing.expectEqual(@as(usize, 1), img.env.len);
    try std.testing.expectEqualStrings("PATH=/usr/bin:/bin", img.env[0]);
    try std.testing.expectEqualStrings("/app", img.cwd);

    // Rootfs files: layer 1 base files, layer 2 additions, and the override.
    var rootfs = try std.Io.Dir.cwd().openDir(io, img.rootfs_dir, .{ .iterate = true });
    defer rootfs.close(io);

    const hostname = try rootfs.readFileAlloc(io, "etc/hostname", a, .unlimited);
    defer a.free(hostname);
    try std.testing.expectEqualStrings("override\n", hostname); // layer 2 wins

    const sh = try rootfs.readFileAlloc(io, "bin/sh", a, .unlimited);
    defer a.free(sh);
    try std.testing.expectEqualStrings("#!fake-shell\n", sh);

    const run = try rootfs.readFileAlloc(io, "app/run", a, .unlimited);
    defer a.free(run);
    try std.testing.expectEqualStrings("payload\n", run);
}

test "unpackLayout: single manifest without platform falls back to first" {
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const layout_dir = "oci_test_layout2";
    const work_dir = "oci_test_layout2_work";
    std.Io.Dir.cwd().deleteTree(io, layout_dir) catch {};
    std.Io.Dir.cwd().deleteTree(io, work_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, layout_dir);
    try std.Io.Dir.cwd().createDirPath(io, work_dir);
    defer std.Io.Dir.cwd().deleteTree(io, layout_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, work_dir) catch {};

    var layout = try std.Io.Dir.cwd().openDir(io, layout_dir, .{ .iterate = true });
    defer layout.close(io);
    try layout.createDirPath(io, "blobs/sha256");

    var layer: std.ArrayList(u8) = .empty;
    defer layer.deinit(a);
    try tarAppendFile(&layer, a, "only.txt", "lonely\n");
    try layer.appendNTimes(a, 0, 1024);
    const gz = try gzipAlloc(a, layer.items);
    defer a.free(gz);
    const layer_digest = try putBlob(a, io, layout, gz);
    defer a.free(layer_digest);

    const config_json = "{}";
    const config_digest = try putBlob(a, io, layout, config_json);
    defer a.free(config_digest);

    const manifest_json = try std.fmt.allocPrint(a,
        \\{{"schemaVersion":2,"config":{{"digest":"{s}","size":{d}}},
        \\"layers":[{{"digest":"{s}","size":{d}}}]}}
    , .{ config_digest, config_json.len, layer_digest, gz.len });
    defer a.free(manifest_json);
    const manifest_digest = try putBlob(a, io, layout, manifest_json);
    defer a.free(manifest_digest);

    // No platform on the manifest entry -> fall back to first.
    const index_json = try std.fmt.allocPrint(a,
        \\{{"schemaVersion":2,"manifests":[{{"digest":"{s}","size":{d}}}]}}
    , .{ manifest_digest, manifest_json.len });
    defer a.free(index_json);
    try layout.writeFile(io, .{ .sub_path = "index.json", .data = index_json });

    const img = try unpackLayout(a, io, layout_dir, work_dir);
    defer freeImage(a, img);
    try std.testing.expectEqualStrings("/", img.cwd);

    var rootfs = try std.Io.Dir.cwd().openDir(io, img.rootfs_dir, .{ .iterate = true });
    defer rootfs.close(io);
    const only = try rootfs.readFileAlloc(io, "only.txt", a, .unlimited);
    defer a.free(only);
    try std.testing.expectEqualStrings("lonely\n", only);
}

// --- network integration test (live pull) ---
//
// Pulls docker.io/library/alpine:latest over the network and asserts the
// unpacked rootfs. Network is available in this environment and curl uses the
// OS TLS stack, so this runs by default. If you need to skip it on an offline
// box, set ORCHD_OCI_SKIP_NET=1.

test "resolve: pulls alpine:latest and unpacks a real rootfs" {
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    if (std.c.getenv("ORCHD_OCI_SKIP_NET") != null) return error.SkipZigTest;

    const work_dir = "oci_test_net_work";
    std.Io.Dir.cwd().deleteTree(io, work_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, work_dir);
    defer std.Io.Dir.cwd().deleteTree(io, work_dir) catch {};

    const img = try resolve(a, io, work_dir, "docker.io/library/alpine:latest");
    defer freeImage(a, img);

    // Process defaults parsed from the OCI config. alpine's entrypoint is unset
    // and its Cmd is ["/bin/sh"], env carries PATH, cwd defaults to "/".
    try std.testing.expect(img.argv.len >= 1);
    try std.testing.expectEqualStrings("/bin/sh", img.argv[img.argv.len - 1]);
    try std.testing.expect(img.env.len >= 1);
    var saw_path = false;
    for (img.env) |e| {
        if (std.mem.startsWith(u8, e, "PATH=")) saw_path = true;
    }
    try std.testing.expect(saw_path);
    try std.testing.expect(img.cwd.len >= 1);

    // Rootfs landed on disk. busybox is a real file; /bin/sh is a symlink to it.
    var rootfs = try std.Io.Dir.cwd().openDir(io, img.rootfs_dir, .{ .iterate = true });
    defer rootfs.close(io);

    _ = rootfs.statFile(io, "bin/busybox", .{}) catch |e| {
        std.log.err("expected bin/busybox in unpacked alpine rootfs: {}", .{e});
        return e;
    };
    // /bin/sh exists (as a symlink to busybox); stat without following the link.
    _ = rootfs.statFile(io, "bin/sh", .{ .follow_symlinks = false }) catch |e| {
        std.log.err("expected bin/sh in unpacked alpine rootfs: {}", .{e});
        return e;
    };
}
