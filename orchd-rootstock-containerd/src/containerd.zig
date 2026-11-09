const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const pb = @import("pb.zig");

pub const method = struct {
    pub const version = "/containerd.services.version.v1.Version/Version";
    pub const transfer = "/containerd.services.transfer.v1.Transfer/Transfer";
    pub const get_image = "/containerd.services.images.v1.Images/Get";
    pub const read_content = "/containerd.services.content.v1.Content/Read";
    pub const prepare_snapshot = "/containerd.services.snapshots.v1.Snapshots/Prepare";
    pub const remove_snapshot = "/containerd.services.snapshots.v1.Snapshots/Remove";
    pub const create_container = "/containerd.services.containers.v1.Containers/Create";
    pub const delete_container = "/containerd.services.containers.v1.Containers/Delete";
    pub const create_task = "/containerd.services.tasks.v1.Tasks/Create";
    pub const start_task = "/containerd.services.tasks.v1.Tasks/Start";
    pub const wait_task = "/containerd.services.tasks.v1.Tasks/Wait";
    pub const kill_task = "/containerd.services.tasks.v1.Tasks/Kill";
    pub const delete_task = "/containerd.services.tasks.v1.Tasks/Delete";
};

pub const runc_runtime = "io.containerd.runc.v2";
pub const runc_options_url = "containerd.runc.v1.Options";
pub const oci_spec_url = "types.containerd.io/opencontainers/runtime-spec/1/Spec";
const registry_url = "containerd.types.transfer.OCIRegistry";
const image_store_url = "containerd.types.transfer.ImageStore";

pub const Mount = struct {
    type: []const u8,
    source: []const u8,
    target: []const u8 = "",
    options: []const []const u8 = &.{},
};

pub const Descriptor = struct {
    media_type: []const u8 = "",
    digest: []const u8 = "",
    size: i64 = 0,
};

pub const Version = struct {
    version: []const u8 = "",
    revision: []const u8 = "",
};

fn any(arena: Allocator, type_url: []const u8, value: []const u8) ![]const u8 {
    var w: pb.Writer = .init(arena);
    try w.string(1, type_url);
    try w.message(2, value);
    return w.bytes();
}

fn platform(arena: Allocator, arch: []const u8) ![]const u8 {
    var w: pb.Writer = .init(arena);
    try w.string(1, "linux");
    try w.string(2, arch);
    return w.bytes();
}

fn idOnly(arena: Allocator, id: []const u8) ![]const u8 {
    var w: pb.Writer = .init(arena);
    try w.string(1, id);
    return w.bytes();
}

pub fn transferRequest(arena: Allocator, image: []const u8, arch: []const u8, snapshotter: []const u8) ![]const u8 {
    var registry: pb.Writer = .init(arena);
    try registry.string(1, image);
    try registry.message(2, "");

    var unpack: pb.Writer = .init(arena);
    try unpack.message(1, try platform(arena, arch));
    try unpack.string(2, snapshotter);

    var store: pb.Writer = .init(arena);
    try store.string(1, image);
    try store.message(3, try platform(arena, arch));
    try store.message(10, unpack.bytes());

    var w: pb.Writer = .init(arena);
    try w.message(1, try any(arena, registry_url, registry.bytes()));
    try w.message(2, try any(arena, image_store_url, store.bytes()));
    try w.message(3, "");
    return w.bytes();
}

pub fn getImageRequest(arena: Allocator, name: []const u8) ![]const u8 {
    return idOnly(arena, name);
}

pub fn parseDescriptor(data: []const u8) !Descriptor {
    var d: Descriptor = .{};
    var r: pb.Reader = .init(data);
    while (try r.next()) |f| switch (f.number) {
        1 => d.media_type = f.asBytes(),
        2 => d.digest = f.asBytes(),
        3 => d.size = @bitCast(f.asUint()),
        else => {},
    };
    return d;
}

pub fn parseGetImageResponse(data: []const u8) !Descriptor {
    var r: pb.Reader = .init(data);
    while (try r.next()) |f| if (f.number == 1) {
        var image: pb.Reader = .init(f.asBytes());
        while (try image.next()) |g| if (g.number == 3) return parseDescriptor(g.asBytes());
    };
    return error.ImageHasNoTarget;
}

pub fn readContentRequest(arena: Allocator, digest: []const u8) ![]const u8 {
    return idOnly(arena, digest);
}

pub fn readContentData(data: []const u8) ![]const u8 {
    var r: pb.Reader = .init(data);
    while (try r.next()) |f| if (f.number == 2) return f.asBytes();
    return "";
}

pub fn prepareSnapshotRequest(arena: Allocator, snapshotter: []const u8, key: []const u8, parent: []const u8) ![]const u8 {
    var w: pb.Writer = .init(arena);
    try w.string(1, snapshotter);
    try w.string(2, key);
    try w.string(3, parent);
    return w.bytes();
}

pub fn parseMount(arena: Allocator, data: []const u8) !Mount {
    var m: Mount = .{ .type = "", .source = "" };
    var options: std.ArrayList([]const u8) = .empty;
    var r: pb.Reader = .init(data);
    while (try r.next()) |f| switch (f.number) {
        1 => m.type = f.asBytes(),
        2 => m.source = f.asBytes(),
        3 => m.target = f.asBytes(),
        4 => try options.append(arena, f.asBytes()),
        else => {},
    };
    m.options = options.items;
    return m;
}

pub fn parsePrepareSnapshotResponse(arena: Allocator, data: []const u8) ![]const Mount {
    var mounts: std.ArrayList(Mount) = .empty;
    var r: pb.Reader = .init(data);
    while (try r.next()) |f| if (f.number == 1) try mounts.append(arena, try parseMount(arena, f.asBytes()));
    return mounts.items;
}

pub fn removeSnapshotRequest(arena: Allocator, snapshotter: []const u8, key: []const u8) ![]const u8 {
    var w: pb.Writer = .init(arena);
    try w.string(1, snapshotter);
    try w.string(2, key);
    return w.bytes();
}

pub fn createContainerRequest(arena: Allocator, id: []const u8, image: []const u8, spec_json: []const u8, snapshotter: []const u8, no_pivot_root: bool) ![]const u8 {
    var runtime: pb.Writer = .init(arena);
    try runtime.string(1, runc_runtime);
    if (no_pivot_root) {
        var runc_options: pb.Writer = .init(arena);
        try runc_options.boolean(1, true);
        try runtime.message(2, try any(arena, runc_options_url, runc_options.bytes()));
    }

    var container: pb.Writer = .init(arena);
    try container.string(1, id);
    try container.string(3, image);
    try container.message(4, runtime.bytes());
    try container.message(5, try any(arena, oci_spec_url, spec_json));
    try container.string(6, snapshotter);
    try container.string(7, id);

    var w: pb.Writer = .init(arena);
    try w.message(1, container.bytes());
    return w.bytes();
}

pub fn deleteContainerRequest(arena: Allocator, id: []const u8) ![]const u8 {
    return idOnly(arena, id);
}

fn mountMessage(arena: Allocator, m: Mount) ![]const u8 {
    var w: pb.Writer = .init(arena);
    try w.string(1, m.type);
    try w.string(2, m.source);
    try w.string(3, m.target);
    for (m.options) |o| try w.message(4, o);
    return w.bytes();
}

pub fn createTaskRequest(arena: Allocator, id: []const u8, rootfs: []const Mount, stdout: []const u8, stderr: []const u8) ![]const u8 {
    var w: pb.Writer = .init(arena);
    try w.string(1, id);
    for (rootfs) |m| try w.message(3, try mountMessage(arena, m));
    try w.string(5, stdout);
    try w.string(6, stderr);
    return w.bytes();
}

pub fn startRequest(arena: Allocator, id: []const u8) ![]const u8 {
    return idOnly(arena, id);
}

pub fn waitRequest(arena: Allocator, id: []const u8) ![]const u8 {
    return idOnly(arena, id);
}

pub fn parseWaitResponse(data: []const u8) !u32 {
    var r: pb.Reader = .init(data);
    while (try r.next()) |f| if (f.number == 1) return @truncate(f.asUint());
    return 0;
}

pub fn killRequest(arena: Allocator, id: []const u8, signal: u32) ![]const u8 {
    var w: pb.Writer = .init(arena);
    try w.string(1, id);
    try w.uint(3, signal);
    try w.boolean(4, true);
    return w.bytes();
}

pub fn deleteTaskRequest(arena: Allocator, id: []const u8) ![]const u8 {
    return idOnly(arena, id);
}

pub fn parseVersionResponse(data: []const u8) !Version {
    var v: Version = .{};
    var r: pb.Reader = .init(data);
    while (try r.next()) |f| switch (f.number) {
        1 => v.version = f.asBytes(),
        2 => v.revision = f.asBytes(),
        else => {},
    };
    return v;
}

test "a container can ask runc for no_pivot_root, as an initramfs root needs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const req = try createContainerRequest(a, "hum-db", "docker.io/library/alpine:3.20", "{}", "overlayfs", true);

    var outer: pb.Reader = .init(req);
    const container = (try outer.next()).?;
    var c: pb.Reader = .init(container.asBytes());
    var seen: [8]bool = @splat(false);
    while (try c.next()) |f| {
        seen[f.number] = true;
        switch (f.number) {
            1, 7 => try testing.expectEqualStrings("hum-db", f.asBytes()),
            4 => {
                var rt: pb.Reader = .init(f.asBytes());
                try testing.expectEqualStrings(runc_runtime, (try rt.next()).?.asBytes());
                var opts: pb.Reader = .init((try rt.next()).?.asBytes());
                try testing.expectEqualStrings(runc_options_url, (try opts.next()).?.asBytes());
                try testing.expectEqualSlices(u8, &.{ 0x08, 0x01 }, (try opts.next()).?.asBytes());
            },
            5 => {
                var spec: pb.Reader = .init(f.asBytes());
                try testing.expectEqualStrings(oci_spec_url, (try spec.next()).?.asBytes());
                try testing.expectEqualStrings("{}", (try spec.next()).?.asBytes());
            },
            6 => try testing.expectEqualStrings("overlayfs", f.asBytes()),
            else => {},
        }
    }
    for ([_]usize{ 1, 3, 4, 5, 6, 7 }) |n| try testing.expect(seen[n]);

    var plain: pb.Reader = .init(try createContainerRequest(a, "hum-db", "x", "{}", "overlayfs", false));
    var pc: pb.Reader = .init((try plain.next()).?.asBytes());
    while (try pc.next()) |f| if (f.number == 4) {
        var rt: pb.Reader = .init(f.asBytes());
        try testing.expectEqualStrings(runc_runtime, (try rt.next()).?.asBytes());
        try testing.expectEqual(null, try rt.next());
    };
}

test "a pull asks the registry for the image and unpacks it for this platform" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const req = try transferRequest(arena.allocator(), "docker.io/library/alpine:3.20", "arm64", "overlayfs");
    var r: pb.Reader = .init(req);
    var source: pb.Reader = .init((try r.next()).?.asBytes());
    try testing.expectEqualStrings(registry_url, (try source.next()).?.asBytes());
    var registry: pb.Reader = .init((try source.next()).?.asBytes());
    try testing.expectEqualStrings("docker.io/library/alpine:3.20", (try registry.next()).?.asBytes());
    var dest: pb.Reader = .init((try r.next()).?.asBytes());
    try testing.expectEqualStrings(image_store_url, (try dest.next()).?.asBytes());
    const options = (try r.next()).?;
    try testing.expectEqual(3, options.number);
}

test "responses yield the image target, the snapshot mounts and the exit status" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var desc: pb.Writer = .init(a);
    try desc.string(1, "application/vnd.oci.image.index.v1+json");
    try desc.string(2, "sha256:abc");
    try desc.uint(3, 1234);
    var image: pb.Writer = .init(a);
    try image.string(1, "alpine");
    try image.message(3, desc.bytes());
    var resp: pb.Writer = .init(a);
    try resp.message(1, image.bytes());
    const target = try parseGetImageResponse(resp.bytes());
    try testing.expectEqualStrings("sha256:abc", target.digest);
    try testing.expectEqual(1234, target.size);

    const mount: Mount = .{ .type = "overlay", .source = "overlay", .options = &.{ "lowerdir=/a", "upperdir=/b" } };
    var prep: pb.Writer = .init(a);
    try prep.message(1, try mountMessage(a, mount));
    const mounts = try parsePrepareSnapshotResponse(a, prep.bytes());
    try testing.expectEqualStrings("overlay", mounts[0].type);
    try testing.expectEqualStrings("upperdir=/b", mounts[0].options[1]);

    var wait: pb.Writer = .init(a);
    try wait.uint(1, 137);
    try testing.expectEqual(137, try parseWaitResponse(wait.bytes()));
    try testing.expectEqual(0, try parseWaitResponse(""));
}
