//! Image -> OCI config resolution, walked entirely over XPC contentGet.
//!
//!   imageList            -> find the image's index digest
//!   contentGet(index)    -> pick the linux/arm64 manifest digest
//!   contentGet(manifest) -> the config blob digest
//!   contentGet(config)   -> OCI config: Entrypoint / Cmd / Env / WorkingDir / User
//!
//! The result feeds ContainerConfiguration.initProcess for create.

const std = @import("std");
const client = @import("client.zig");

pub const Resolved = struct {
    /// Image descriptor digest (for ContainerConfiguration.image).
    image_digest: []const u8,
    image_size: i64,
    image_media_type: []const u8,
    /// initProcess fields, from the OCI config.
    executable: []const u8,
    arguments: []const []const u8,
    environment: []const []const u8,
    working_directory: []const u8,
};

fn find(v: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn str(v: ?std.json.Value) []const u8 {
    return if (v) |x| switch (x) {
        .string => |s| s,
        else => "",
    } else "";
}

/// Resolve `reference` to its descriptor + initProcess fields. Allocations come
/// from `arena` (caller owns; free the whole arena).
pub fn resolve(arena: std.mem.Allocator, io: std.Io, reference: []const u8) !Resolved {
    // 1. imageList -> descriptor for `reference`
    const images_json = try client.imageList(arena);
    const images = try std.json.parseFromSliceLeaky(std.json.Value, arena, images_json, .{});
    var index_digest: []const u8 = "";
    var img_size: i64 = 0;
    var img_media: []const u8 = "";
    for (images.array.items) |img| {
        if (std.mem.eql(u8, str(find(img, "reference")), reference)) {
            const desc = find(img, "descriptor").?;
            index_digest = str(find(desc, "digest"));
            img_media = str(find(desc, "mediaType"));
            img_size = switch (find(desc, "size").?) {
                .integer => |n| n,
                else => 0,
            };
        }
    }
    if (index_digest.len == 0) return error.ImageNotFound;

    // 2. contentGet(index) -> linux/arm64 manifest digest
    const index_blob = try client.contentGet(arena, io, index_digest);
    const index = try std.json.parseFromSliceLeaky(std.json.Value, arena, index_blob, .{});
    var manifest_digest: []const u8 = "";
    for (find(index, "manifests").?.array.items) |m| {
        const plat = find(m, "platform") orelse continue;
        if (std.mem.eql(u8, str(find(plat, "os")), "linux") and
            std.mem.eql(u8, str(find(plat, "architecture")), "arm64"))
        {
            manifest_digest = str(find(m, "digest"));
        }
    }
    if (manifest_digest.len == 0) return error.NoArm64Manifest;

    // 3. contentGet(manifest) -> config blob digest
    const manifest_blob = try client.contentGet(arena, io, manifest_digest);
    const manifest = try std.json.parseFromSliceLeaky(std.json.Value, arena, manifest_blob, .{});
    const config_digest = str(find(find(manifest, "config") orelse return error.NoConfig, "digest"));

    // 4. contentGet(config) -> OCI config (Entrypoint/Cmd/Env/WorkingDir)
    const config_blob = try client.contentGet(arena, io, config_digest);
    const oci = try std.json.parseFromSliceLeaky(std.json.Value, arena, config_blob, .{});
    const cfg = find(oci, "config") orelse return error.NoOciConfig;

    var argv = std.ArrayList([]const u8).empty;
    if (find(cfg, "Entrypoint")) |ep| if (ep == .array) for (ep.array.items) |a| try argv.append(arena, str(a));
    if (find(cfg, "Cmd")) |cmd| if (cmd == .array) for (cmd.array.items) |a| try argv.append(arena, str(a));
    if (argv.items.len == 0) return error.NoEntrypoint;

    var env = std.ArrayList([]const u8).empty;
    if (find(cfg, "Env")) |e| if (e == .array) for (e.array.items) |a| try env.append(arena, str(a));

    const wd = str(find(cfg, "WorkingDir"));

    return .{
        .image_digest = index_digest,
        .image_size = img_size,
        .image_media_type = img_media,
        .executable = argv.items[0],
        .arguments = argv.items[1..],
        .environment = env.items,
        .working_directory = if (wd.len == 0) "/" else wd,
    };
}
