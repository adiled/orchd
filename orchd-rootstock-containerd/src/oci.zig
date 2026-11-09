const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const Resources = struct {
    memory_bytes: ?u64 = null,
    cpu_quota_us: ?u64 = null,
    cpu_period_us: ?u64 = null,
    pids_max: ?u64 = null,
    nofile: ?u64 = null,
    nproc: ?u64 = null,
    io_weight: ?u32 = null,
};

pub const BindMount = struct {
    source: []const u8,
    destination: []const u8,
};

pub const Process = struct {
    args: []const []const u8,
    env: []const []const u8,
    cwd: []const u8,
    uid: u32 = 0,
    gid: u32 = 0,
};

const caps = [_][]const u8{ "CAP_NET_RAW", "CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_SETUID", "CAP_SETGID", "CAP_NET_BIND_SERVICE" };

const Mount = struct {
    destination: []const u8,
    type: []const u8,
    source: []const u8,
    options: []const []const u8 = &.{},
};

const base_mounts = [_]Mount{
    .{ .destination = "/proc", .type = "proc", .source = "proc" },
    .{ .destination = "/dev", .type = "tmpfs", .source = "tmpfs", .options = &.{ "nosuid", "strictatime", "mode=755", "size=65536k" } },
    .{ .destination = "/dev/pts", .type = "devpts", .source = "devpts", .options = &.{ "nosuid", "noexec", "newinstance", "ptmxmode=0666", "mode=0620", "gid=5" } },
    .{ .destination = "/dev/shm", .type = "tmpfs", .source = "shm", .options = &.{ "nosuid", "noexec", "nodev", "mode=1777", "size=65536k" } },
    .{ .destination = "/dev/mqueue", .type = "mqueue", .source = "mqueue", .options = &.{ "nosuid", "noexec", "nodev" } },
    .{ .destination = "/sys", .type = "sysfs", .source = "sysfs", .options = &.{ "nosuid", "noexec", "nodev", "ro" } },
    .{ .destination = "/etc/resolv.conf", .type = "bind", .source = "/etc/resolv.conf", .options = &.{ "rbind", "ro" } },
};

const Rlimit = struct { type: []const u8, hard: u64, soft: u64 };

const Spec = struct {
    ociVersion: []const u8 = "1.1.0",
    process: struct {
        terminal: bool = false,
        user: struct { uid: u32, gid: u32 },
        args: []const []const u8,
        env: []const []const u8,
        cwd: []const u8,
        capabilities: struct { bounding: []const []const u8, effective: []const []const u8, permitted: []const []const u8 },
        rlimits: []const Rlimit,
        noNewPrivileges: bool = true,
    },
    root: struct { path: []const u8 = "rootfs", readonly: bool = false } = .{},
    hostname: []const u8,
    mounts: []const Mount,
    linux: struct {
        namespaces: []const struct { type: []const u8 },
        maskedPaths: []const []const u8,
        readonlyPaths: []const []const u8,
        resources: ?struct {
            memory: ?struct { limit: u64 } = null,
            cpu: ?struct { quota: u64, period: u64 } = null,
            pids: ?struct { limit: u64 } = null,
            blockIO: ?struct { weight: u32 } = null,
        } = null,
    },
};

pub fn json(arena: Allocator, id: []const u8, process: Process, mounts: []const BindMount, res: Resources) ![]const u8 {
    var rlimits: std.ArrayList(Rlimit) = .empty;
    const nofile = res.nofile orelse 1024;
    try rlimits.append(arena, .{ .type = "RLIMIT_NOFILE", .hard = nofile, .soft = nofile });
    if (res.nproc) |n| try rlimits.append(arena, .{ .type = "RLIMIT_NPROC", .hard = n, .soft = n });

    var all_mounts: std.ArrayList(Mount) = .empty;
    try all_mounts.appendSlice(arena, &base_mounts);
    for (mounts) |m| try all_mounts.append(arena, .{ .destination = m.destination, .type = "bind", .source = m.source, .options = &.{ "rbind", "rw" } });

    var spec: Spec = .{
        .process = .{
            .user = .{ .uid = process.uid, .gid = process.gid },
            .args = process.args,
            .env = process.env,
            .cwd = if (process.cwd.len > 0) process.cwd else "/",
            .capabilities = .{ .bounding = &caps, .effective = &caps, .permitted = &caps },
            .rlimits = rlimits.items,
        },
        .hostname = id,
        .mounts = all_mounts.items,
        .linux = .{
            .namespaces = &.{ .{ .type = "pid" }, .{ .type = "ipc" }, .{ .type = "uts" }, .{ .type = "mount" } },
            .maskedPaths = &.{ "/proc/kcore", "/proc/latency_stats", "/proc/timer_list", "/proc/timer_stats", "/proc/sched_debug", "/sys/firmware" },
            .readonlyPaths = &.{ "/proc/asound", "/proc/bus", "/proc/fs", "/proc/irq", "/proc/sys", "/proc/sysrq-trigger" },
        },
    };
    if (res.memory_bytes != null or res.cpu_quota_us != null or res.pids_max != null or res.io_weight != null) {
        spec.linux.resources = .{
            .memory = if (res.memory_bytes) |m| .{ .limit = m } else null,
            .cpu = if (res.cpu_quota_us) |q| .{ .quota = q, .period = res.cpu_period_us orelse 100_000 } else null,
            .pids = if (res.pids_max) |p| .{ .limit = p } else null,
            .blockIO = if (res.io_weight) |w| .{ .weight = w } else null,
        };
    }
    return std.json.Stringify.valueAlloc(arena, spec, .{ .emit_null_optional_fields = false });
}

test "the spec runs the process in the host network, with its mounts and limits" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try json(a, "hum-web", .{ .args = &.{ "nginx", "-g", "daemon off;" }, .env = &.{"A=1"}, .cwd = "", .uid = 101, .gid = 101 }, &.{.{ .source = "/data/web", .destination = "/srv" }}, .{ .memory_bytes = 1 << 30, .cpu_quota_us = 150_000, .nproc = 64 });
    const doc = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
    const process = doc.object.get("process").?.object;
    try testing.expectEqualStrings("daemon off;", process.get("args").?.array.items[2].string);
    try testing.expectEqualStrings("/", process.get("cwd").?.string);
    try testing.expectEqual(101, process.get("user").?.object.get("uid").?.integer);
    try testing.expectEqual(2, process.get("rlimits").?.array.items.len);
    try testing.expectEqualStrings("hum-web", doc.object.get("hostname").?.string);
    const linux = doc.object.get("linux").?.object;
    for (linux.get("namespaces").?.array.items) |ns| try testing.expect(!std.mem.eql(u8, ns.object.get("type").?.string, "network"));
    const resources = linux.get("resources").?.object;
    try testing.expectEqual(1 << 30, resources.get("memory").?.object.get("limit").?.integer);
    try testing.expectEqual(100_000, resources.get("cpu").?.object.get("period").?.integer);
    try testing.expect(resources.get("pids") == null);
    const mounts = doc.object.get("mounts").?.array.items;
    try testing.expectEqualStrings("/srv", mounts[mounts.len - 1].object.get("destination").?.string);
}

test "with no limits there is no resources block" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const text = try json(arena.allocator(), "x", .{ .args = &.{"true"}, .env = &.{}, .cwd = "/app" }, &.{}, .{});
    try testing.expect(std.mem.indexOf(u8, text, "\"resources\"") == null);
    try testing.expect(std.mem.indexOf(u8, text, "\"cwd\":\"/app\"") != null);
}
