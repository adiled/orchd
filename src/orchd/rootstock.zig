const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const testing = std.testing;
const types = @import("types.zig");
const Config = @import("config.zig").Config;
const exe = @import("exe.zig");
const contract = @import("contract");
const Service = types.Service;
const ExecSet = types.ExecSet;
const Diagnostic = types.Diagnostic;

pub fn create(arena: Allocator, io: Io, environ: *const Environ.Map, config: Config, diag: *Diagnostic) !Rootstock {
    const file = try pluginName(arena, config.rootstock);
    const bin = try exe.find(arena, io, file, exe.selfDir(arena, io), environ.get("PATH") orelse "") orelse {
        diag.set(arena, "binary not found: {s} beside orchd or on PATH", .{file});
        return error.RootstockNotFound;
    };
    return .{ .name = config.rootstock, .bin = bin, .config = config };
}

pub fn pluginName(arena: Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "orchd-rootstock-{s}", .{name});
}

pub const Rootstock = struct {
    name: []const u8,
    bin: []const u8,
    config: Config,
    removes: bool = false,

    fn call(e: Rootstock, arena: Allocator, io: Io, verb: []const u8, service: ?Service, diag: *Diagnostic) ![]const u8 {
        const plugin = try pluginName(arena, e.name);
        const input = if (service) |s| try std.json.Stringify.valueAlloc(arena, contract.Envelope{
            .contract = contract.base,
            .grove = e.config.grove,
            .project_dir = e.config.project_dir,
            .data_dir = e.config.data_dir,
            .state_dir = e.config.state_dir,
            .service = s,
        }, .{ .emit_null_optional_fields = false }) else "";
        const out = exe.communicate(arena, io, &.{ e.bin, verb }, input) catch |err| {
            diag.set(arena, "{s} {s}: {t}", .{ plugin, verb, err });
            return error.RootstockFailed;
        };
        if (!out.ok()) {
            diag.set(arena, "{s} {s} failed: {s}", .{ plugin, verb, out.reason() });
            return error.RootstockFailed;
        }
        return out.stdout;
    }

    pub fn check(e: *Rootstock, arena: Allocator, io: Io, diag: *Diagnostic) !void {
        const spoken = try e.call(arena, io, "contract", null, diag);
        var speaks_base = false;
        var versions = std.mem.tokenizeAny(u8, spoken, " \t\r\n");
        while (versions.next()) |v| {
            const version = std.fmt.parseInt(u32, v, 10) catch continue;
            if (version == contract.base) speaks_base = true;
            if (version == contract.removal) e.removes = true;
        }
        if (!speaks_base) {
            diag.set(arena, "{s} speaks contract {s}, orchd needs {d}", .{
                try pluginName(arena, e.name),
                std.mem.trim(u8, spoken, " \t\r\n"),
                contract.base,
            });
            return error.ContractMismatch;
        }
        _ = try e.call(arena, io, "check", null, diag);
    }

    pub fn prepare(e: Rootstock, arena: Allocator, io: Io, service: Service, diag: *Diagnostic) !void {
        _ = try e.call(arena, io, "prepare", service, diag);
    }

    pub fn remove(e: Rootstock, arena: Allocator, io: Io, service: Service, diag: *Diagnostic) !void {
        if (!e.removes) return;
        _ = try e.call(arena, io, "remove", service, diag);
    }

    pub fn execSet(e: Rootstock, arena: Allocator, io: Io, service: Service, diag: *Diagnostic) !ExecSet {
        const out = try e.call(arena, io, "exec-set", service, diag);
        return std.json.parseFromSliceLeaky(ExecSet, arena, out, .{ .ignore_unknown_fields = true }) catch |err| {
            diag.set(arena, "{s} exec-set: not an ExecSet: {t}", .{ try pluginName(arena, e.name), err });
            return error.RootstockFailed;
        };
    }
};

fn fakePlugin(arena: Allocator, dir: Io.Dir, root: []const u8, body: []const u8) ![]const u8 {
    try dir.writeFile(testing.io, .{ .sub_path = "draft", .data = try std.fmt.allocPrint(arena, "#!/bin/sh\n{s}\n", .{body}) });
    const path = try std.fs.path.join(arena, &.{ root, "orchd-rootstock-fake" });
    const draft = try std.fs.path.join(arena, &.{ root, "draft" });
    const out = try exe.communicate(arena, testing.io, &.{ "/bin/sh", "-c", "cp \"$0\" \"$1\" && chmod 755 \"$1\"", draft, path }, null);
    try testing.expect(out.ok());
    return path;
}

fn fakeRootstock(bin: []const u8, root: []const u8) Rootstock {
    var config = @import("config.zig").forTest(root);
    config.grove = "g";
    config.project_dir = "/proj";
    config.data_dir = "/data";
    return .{ .name = "fake", .bin = bin, .config = config };
}

test "a plugin gets the envelope on stdin and answers with an exec set" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const seen = try std.fs.path.join(a, &.{ root, "envelope.json" });
    const bin = try fakePlugin(a, tmp.dir, root, try std.fmt.allocPrint(a,
        \\case "$1" in
        \\  contract) echo 1 ;;
        \\  check) exit 0 ;;
        \\  exec-set) cat > {s}; echo '{{"start":"fake run web","stop":null}}' ;;
        \\esac
    , .{seen}));
    var plugin = fakeRootstock(bin, root);
    var diag: Diagnostic = .{};
    try plugin.check(a, testing.io, &diag);
    const set = try plugin.execSet(a, testing.io, .{ .name = "web", .mode = .host, .run_command = "sleep 1" }, &diag);
    try testing.expectEqualStrings("fake run web", set.start);
    try testing.expectEqual(null, set.stop);

    const envelope = try std.json.parseFromSliceLeaky(std.json.Value, a, try tmp.dir.readFileAlloc(testing.io, "envelope.json", a, .limited(1 << 16)), .{});
    try testing.expectEqual(1, envelope.object.get("contract").?.integer);
    try testing.expectEqualStrings("g", envelope.object.get("grove").?.string);
    try testing.expectEqualStrings("/proj", envelope.object.get("project_dir").?.string);
    const service = envelope.object.get("service").?.object;
    try testing.expectEqualStrings("web", service.get("name").?.string);
    try testing.expectEqualStrings("host", service.get("mode").?.string);
    try testing.expectEqual(null, service.get("image"));
}

test "a plugin that speaks another contract is refused by name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    var plugin = fakeRootstock(try fakePlugin(a, tmp.dir, root, "echo 2"), root);
    var diag: Diagnostic = .{};
    try testing.expectError(error.ContractMismatch, plugin.check(a, testing.io, &diag));
    try testing.expectEqualStrings("orchd-rootstock-fake speaks contract 2, orchd needs 1", diag.message);
}

test "a failing verb carries the plugin's own reason, even unread" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const plugin = fakeRootstock(try fakePlugin(a, tmp.dir, root, "echo 'no image for web' >&2; exit 3"), root);
    var diag: Diagnostic = .{};
    try testing.expectError(error.RootstockFailed, plugin.prepare(a, testing.io, .{ .name = "web", .mode = .host }, &diag));
    try testing.expectEqualStrings("orchd-rootstock-fake prepare failed: no image for web", diag.message);
}

test "a plugin that speaks contract 2 is asked to remove what it keeps; one that speaks only 1 is not" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const seen = try std.fs.path.join(a, &.{ root, "removed.json" });
    const body = try std.fmt.allocPrint(a,
        \\case "$1" in
        \\  contract) echo "$VERSIONS" ;;
        \\  check) exit 0 ;;
        \\  remove) cat > {s} ;;
        \\esac
    , .{seen});
    const keeps = try fakePlugin(a, tmp.dir, root, try std.mem.replaceOwned(u8, a, body, "$VERSIONS", "1 2"));
    var two = fakeRootstock(keeps, root);
    var diag: Diagnostic = .{};
    try two.check(a, testing.io, &diag);
    try testing.expect(two.removes);
    try two.remove(a, testing.io, .{ .name = "db", .mode = .container, .image = "postgres:16" }, &diag);
    const envelope = try std.json.parseFromSliceLeaky(std.json.Value, a, try tmp.dir.readFileAlloc(testing.io, "removed.json", a, .limited(1 << 16)), .{});
    try testing.expectEqualStrings("db", envelope.object.get("service").?.object.get("name").?.string);

    try tmp.dir.deleteFile(testing.io, "removed.json");
    var one = fakeRootstock(try fakePlugin(a, tmp.dir, root, try std.mem.replaceOwned(u8, a, body, "$VERSIONS", "1")), root);
    try one.check(a, testing.io, &diag);
    try testing.expect(!one.removes);
    try one.remove(a, testing.io, .{ .name = "db", .mode = .container, .image = "postgres:16" }, &diag);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "removed.json", .{}));
}
