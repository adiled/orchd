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
//!     symlinks) and honours whiteouts (.wh. entries)
//! resolve() wires these together over a Docker Registry v2 / OCI pull with
//! the docker.io bearer-token auth flow. The network pull is implemented but
//! lightly exercised (no integration test here, since these tests import only
//! std and must run offline). See TODOs for the rough edges.

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
    var it: std.tar.Iterator = .init(tar_reader, .{
        .file_name_buffer = &name_buf,
        .link_name_buffer = &link_buf,
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
                // Stream exactly entry.size bytes from the tar reader.
                var remaining = entry.size;
                var buf: [64 * 1024]u8 = undefined;
                while (remaining > 0) {
                    const want: usize = @intCast(@min(remaining, buf.len));
                    const got = try tar_reader.readSliceShort(buf[0..want]);
                    if (got == 0) return error.UnexpectedEndOfTar;
                    try f.writeStreamingAll(io, buf[0..got]);
                    remaining -= got;
                }
                _ = allocator;
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

/// Resolve and unpack `reference` into a rootfs under `work_dir`.
///
/// Returns an `Image` whose `rootfs_dir` is `work_dir/rootfs` and whose
/// argv/env/cwd come from the OCI config. The returned slices are allocated
/// with `allocator` and leak by design here (the caller owns `work_dir` and the
/// process config for the lifetime of the run); a future cleanup pass can hand
/// back an owned struct with a deinit.
pub fn resolve(
    allocator: std.mem.Allocator,
    io: std.Io,
    work_dir: []const u8,
    reference: []const u8,
) !Image {
    const ref = try parseReference(allocator, reference);
    defer ref.deinit(allocator);

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var auth: Auth = .{};
    defer auth.deinit(allocator);

    // 1. Manifest (may be an index/list -> pick linux/arm64).
    const manifest_url = try std.fmt.allocPrint(allocator, "https://{s}/v2/{s}/manifests/{s}", .{
        ref.registry, ref.repo, ref.reference,
    });
    defer allocator.free(manifest_url);

    const manifest_body = try getWithAuth(allocator, &client, &auth, ref.repo, manifest_url, accept_manifests);
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
        image_manifest_body = try getWithAuth(allocator, &client, &auth, ref.repo, url, accept_manifests);
        image_manifest_owned = true;
    }

    const manifest = try std.json.parseFromSlice(ManifestDoc, allocator, image_manifest_body, .{ .ignore_unknown_fields = true });
    defer manifest.deinit();

    // 2. Config blob -> process defaults.
    const config_url = try std.fmt.allocPrint(allocator, "https://{s}/v2/{s}/blobs/{s}", .{
        ref.registry, ref.repo, manifest.value.config.digest,
    });
    defer allocator.free(config_url);
    const config_body = try getWithAuth(allocator, &client, &auth, ref.repo, config_url, "*/*");
    defer allocator.free(config_body);

    const pcfg = try parseConfig(allocator, config_body);

    // 3. Layers -> unpack into work_dir/rootfs in order.
    const rootfs_dir = try std.fmt.allocPrint(allocator, "{s}/rootfs", .{work_dir});
    std.Io.Dir.cwd().createDirPath(io, rootfs_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    var dest = try std.Io.Dir.cwd().openDir(io, rootfs_dir, .{ .iterate = true });
    defer dest.close(io);

    for (manifest.value.layers) |layer| {
        const url = try std.fmt.allocPrint(allocator, "https://{s}/v2/{s}/blobs/{s}", .{
            ref.registry, ref.repo, layer.digest,
        });
        defer allocator.free(url);
        const blob = try getWithAuth(allocator, &client, &auth, ref.repo, url, "*/*");
        defer allocator.free(blob);
        // TODO: dispatch on layer.mediaType for uncompressed (+tar) and zstd
        // layers. Today we assume gzip'd tar, which is the docker.io default.
        try extractLayerGzip(allocator, io, dest, blob);
    }

    return .{
        .rootfs_dir = rootfs_dir,
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

// --- bearer-token auth ---

const Auth = struct {
    token: ?[]u8 = null,

    fn deinit(self: *Auth, allocator: std.mem.Allocator) void {
        if (self.token) |t| allocator.free(t);
    }
};

/// GET `url`, transparently handling a 401 + WWW-Authenticate bearer challenge
/// (docker.io flow): fetch a token from the realm, cache it, and retry once.
fn getWithAuth(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    auth: *Auth,
    repo: []const u8,
    url: []const u8,
    accept: []const u8,
) ![]u8 {
    if (try getOnce(allocator, client, auth.*, url, accept)) |body| return body;

    // 401: parse the challenge from a fresh request's headers and get a token.
    const challenge = try fetchChallenge(allocator, client, url, accept);
    defer challenge.deinit(allocator);

    const token = try fetchToken(allocator, client, challenge, repo);
    if (auth.token) |t| allocator.free(t);
    auth.token = token;

    return (try getOnce(allocator, client, auth.*, url, accept)) orelse Error.AuthFailed;
}

/// Perform one GET. Returns the body on 2xx, null on 401 (so the caller can do
/// the token dance), and errors on any other status.
fn getOnce(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    auth: Auth,
    url: []const u8,
    accept: []const u8,
) !?[]u8 {
    const uri = try std.Uri.parse(url);

    var auth_buf: [4096]u8 = undefined;
    var extra: [2]std.http.Header = undefined;
    var n: usize = 0;
    extra[n] = .{ .name = "accept", .value = accept };
    n += 1;
    if (auth.token) |t| {
        const v = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{t}) catch return error.TokenTooLong;
        extra[n] = .{ .name = "authorization", .value = v };
        n += 1;
    }

    var req = try client.request(.GET, uri, .{ .extra_headers = extra[0..n] });
    defer req.deinit();
    try req.sendBodiless();

    var redirect_buf: [8192]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    const status = response.head.status;
    if (status == .unauthorized) return null;
    if (@intFromEnum(status) < 200 or @intFromEnum(status) >= 300) return Error.HttpStatus;

    var transfer_buf: [64 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    return try reader.allocRemaining(allocator, .unlimited);
}

const Challenge = struct {
    realm: []u8,
    service: ?[]u8,

    fn deinit(self: Challenge, allocator: std.mem.Allocator) void {
        allocator.free(self.realm);
        if (self.service) |s| allocator.free(s);
    }
};

/// Re-issue the GET, read the WWW-Authenticate header on the 401, and parse the
/// bearer realm + service out of it.
fn fetchChallenge(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
    accept: []const u8,
) !Challenge {
    const uri = try std.Uri.parse(url);
    const extra = [_]std.http.Header{.{ .name = "accept", .value = accept }};
    var req = try client.request(.GET, uri, .{ .extra_headers = &extra });
    defer req.deinit();
    try req.sendBodiless();

    var redirect_buf: [8192]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    var it = response.head.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "www-authenticate")) {
            return parseBearerChallenge(allocator, h.value);
        }
    }
    return Error.AuthFailed;
}

/// Parse: Bearer realm="https://auth...",service="registry...",scope="..."
fn parseBearerChallenge(allocator: std.mem.Allocator, value: []const u8) !Challenge {
    const realm = (try kvFromChallenge(allocator, value, "realm")) orelse return Error.AuthFailed;
    errdefer allocator.free(realm);
    const service = try kvFromChallenge(allocator, value, "service");
    return .{ .realm = realm, .service = service };
}

fn kvFromChallenge(allocator: std.mem.Allocator, value: []const u8, key: []const u8) !?[]u8 {
    var needle_buf: [32]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "{s}=\"", .{key}) catch return null;
    const start = std.mem.indexOf(u8, value, needle) orelse return null;
    const vstart = start + needle.len;
    const vend = std.mem.indexOfScalarPos(u8, value, vstart, '"') orelse return null;
    return try allocator.dupe(u8, value[vstart..vend]);
}

/// GET realm?service=...&scope=repository:<repo>:pull and pull the "token".
fn fetchToken(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    challenge: Challenge,
    repo: []const u8,
) ![]u8 {
    const token_url = if (challenge.service) |svc|
        try std.fmt.allocPrint(allocator, "{s}?service={s}&scope=repository:{s}:pull", .{ challenge.realm, svc, repo })
    else
        try std.fmt.allocPrint(allocator, "{s}?scope=repository:{s}:pull", .{ challenge.realm, repo });
    defer allocator.free(token_url);

    const uri = try std.Uri.parse(token_url);
    var req = try client.request(.GET, uri, .{});
    defer req.deinit();
    try req.sendBodiless();

    var redirect_buf: [8192]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);
    if (@intFromEnum(response.head.status) != 200) return Error.AuthFailed;

    var transfer_buf: [64 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    const body = try reader.allocRemaining(allocator, .unlimited);
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
