const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const types = @import("types.zig");
const Service = types.Service;
const VolumeMount = types.VolumeMount;
const Diagnostic = types.Diagnostic;

pub const Homes = struct {
    runtime: []const u8,
    of: *const fn (Allocator, []const u8) ?[]const u8 = ofUser,
};

pub fn here(arena: Allocator, fallback: []const u8) Homes {
    const entry = std.c.getpwuid(std.c.geteuid()) orelse return .{ .runtime = fallback };
    return .{ .runtime = dirOf(arena, entry) orelse fallback };
}

pub fn ofUser(arena: Allocator, name: []const u8) ?[]const u8 {
    const entry = std.c.getpwnam(arena.dupeSentinel(u8, name, 0) catch return null) orelse
        std.c.getpwuid(std.fmt.parseInt(std.c.uid_t, name, 10) catch return null) orelse
        return null;
    return dirOf(arena, entry);
}

fn dirOf(arena: Allocator, entry: *std.c.passwd) ?[]const u8 {
    return arena.dupe(u8, std.mem.span(entry.dir orelse return null)) catch null;
}

pub fn expand(arena: Allocator, services: []const Service, homes: Homes, diag: *Diagnostic) ![]const Service {
    const out = try arena.dupe(Service, services);
    for (out) |*s| {
        const owner: Owner = switch (s.mode) {
            .host => if (s.user) |user| .{ .home = homes.of(arena, user), .user = user } else .{ .home = homes.runtime },
            .container => .{ .home = homes.runtime },
        };
        const paths: Paths = .{ .arena = arena, .service = s.name, .owner = owner, .diag = diag };
        const env_files = try arena.dupe([]const u8, s.env_files);
        for (env_files) |*file| file.* = try paths.host(file.*);
        s.env_files = env_files;
        s.logging = .{ .stdout = try paths.hostOrNull(s.logging.stdout), .stderr = try paths.hostOrNull(s.logging.stderr) };
        switch (s.mode) {
            .host => s.workdir = try paths.hostOrNull(s.workdir),
            .container => {
                if (s.workdir) |workdir| try paths.inContainer("WORKDIR", workdir);
                const volumes = try arena.dupe(VolumeMount, s.volumes);
                for (volumes) |*volume| {
                    if (!volume.is_named) volume.source = try paths.host(volume.source);
                    try paths.inContainer("VOLUME", volume.destination);
                }
                s.volumes = volumes;
            },
        }
    }
    return out;
}

const Owner = struct {
    home: ?[]const u8,
    user: ?[]const u8 = null,
};

const Paths = struct {
    arena: Allocator,
    service: []const u8,
    owner: Owner,
    diag: *Diagnostic,

    fn host(p: Paths, path: []const u8) ![]const u8 {
        if (!underHome(path)) return path;
        const home = p.owner.home orelse {
            p.diag.set(p.arena, "service '{s}' runs as '{s}', who has no home directory here for {s}", .{ p.service, p.owner.user.?, path });
            return error.NoHome;
        };
        return std.fs.path.join(p.arena, &.{ home, path[1..] });
    }

    fn hostOrNull(p: Paths, path: ?[]const u8) !?[]const u8 {
        return if (path) |given| try p.host(given) else null;
    }

    fn inContainer(p: Paths, directive: []const u8, path: []const u8) !void {
        if (!underHome(path)) return;
        p.diag.set(p.arena, "service '{s}': {s} {s} is inside the container, whose home directory orchd cannot know; write it as an absolute path", .{ p.service, directive, path });
        return error.HomeInContainer;
    }
};

fn underHome(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "~");
}

fn knownHomes(_: Allocator, name: []const u8) ?[]const u8 {
    return if (std.mem.eql(u8, name, "svc")) "/home/svc" else null;
}

const homes_for_test: Homes = .{ .runtime = "/home/orchd", .of = knownHomes };

test "a host service's ~ is the home of its USER, or of the runtime's user without one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const services = try expand(arena.allocator(), &.{
        .{ .name = "api", .mode = .host, .user = "svc", .workdir = "~", .env_files = &.{ "~/.env", "/etc/api.env" }, .logging = .{ .stdout = "~/logs/api.log" } },
        .{ .name = "worker", .mode = .host, .workdir = "~/work" },
    }, homes_for_test, &diag);
    try testing.expectEqualStrings("/home/svc", services[0].workdir.?);
    try testing.expectEqualStrings("/home/svc/.env", services[0].env_files[0]);
    try testing.expectEqualStrings("/etc/api.env", services[0].env_files[1]);
    try testing.expectEqualStrings("/home/svc/logs/api.log", services[0].logging.stdout.?);
    try testing.expectEqual(null, services[0].logging.stderr);
    try testing.expectEqualStrings("/home/orchd/work", services[1].workdir.?);
}

test "a container service's host paths take the runtime's home, and named volumes stay names" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const services = try expand(arena.allocator(), &.{.{
        .name = "db",
        .mode = .container,
        .workdir = "/var/lib/postgresql",
        .env_files = &.{"~/.env.db"},
        .volumes = &.{
            .{ .source = "~/data/pg", .destination = "/var/lib/postgresql/data" },
            .{ .source = "pgconf", .destination = "/etc/postgresql", .is_named = true },
        },
        .logging = .{ .stderr = "~/db.err" },
    }}, homes_for_test, &diag);
    try testing.expectEqualStrings("/home/orchd/.env.db", services[0].env_files[0]);
    try testing.expectEqualStrings("/home/orchd/data/pg", services[0].volumes[0].source);
    try testing.expectEqualStrings("pgconf", services[0].volumes[1].source);
    try testing.expectEqualStrings("/home/orchd/db.err", services[0].logging.stderr.?);
    try testing.expectEqualStrings("/var/lib/postgresql", services[0].workdir.?);
}

test "a ~ inside a container is refused, since orchd cannot know the image's home" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    try testing.expectError(error.HomeInContainer, expand(arena.allocator(), &.{
        .{ .name = "web", .mode = .container, .workdir = "~/app" },
    }, homes_for_test, &diag));
    try testing.expectEqualStrings("service 'web': WORKDIR ~/app is inside the container, whose home directory orchd cannot know; write it as an absolute path", diag.message);
    try testing.expectError(error.HomeInContainer, expand(arena.allocator(), &.{
        .{ .name = "web", .mode = .container, .volumes = &.{.{ .source = "/srv", .destination = "~/srv" }} },
    }, homes_for_test, &diag));
}

test "a user without a home is a problem only for paths that start with ~" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const fine = try expand(arena.allocator(), &.{
        .{ .name = "job", .mode = .host, .user = "ghost", .workdir = "/srv/job" },
    }, homes_for_test, &diag);
    try testing.expectEqualStrings("/srv/job", fine[0].workdir.?);
    try testing.expectError(error.NoHome, expand(arena.allocator(), &.{
        .{ .name = "job", .mode = .host, .user = "ghost", .env_files = &.{"~/.env"} },
    }, homes_for_test, &diag));
    try testing.expectEqualStrings("service 'job' runs as 'ghost', who has no home directory here for ~/.env", diag.message);
}

test "every host knows root's home by name and by uid, and no one's for a stranger" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = ofUser(a, "root").?;
    try testing.expect(std.fs.path.isAbsolute(root));
    try testing.expectEqualStrings(root, ofUser(a, "0").?);
    try testing.expectEqual(null, ofUser(a, "no-such-user-for-orchd"));
    try testing.expect(std.fs.path.isAbsolute(here(a, "/fallback").runtime));
}
