//! orchd-osx — from-scratch Apple container runtime co-process for orchd.
//!
//! Same stdio protocol as orchd-apple, different backend: instead of XPC to the
//! container daemon, orchd-osx drives Virtualization.framework directly (the
//! host VMM) and speaks to vminitd over vsock (the guest agent). No daemon, no
//! Swift linked. See vz.zig and ORCHD_OSX.md for the build-out plan.
//!
//! Commands (mirror orchd-apple's contract so the Rust `apple` envelope treats
//! the two co-processes interchangeably):
//!   check                 -- exit 0 if the VZ backend is usable
//!   exec-set <namespace>  -- stdin: Service JSON -> stdout: ExecSet JSON
//!   prepare  <namespace>  -- stdin: Service JSON, fetch/prepare image rootfs
//!   cleanup  <namespace>  -- stdin: Service JSON, tear down
//!   pull   <image>        -- fetch an image                       [TODO: backend]
//!   run    <name> <image> -- create+boot a VM, start the container [TODO: backend]
//!   wait   <name>         -- block until the container exits       [TODO: backend]
//!   stop   <name>         -- graceful stop                         [TODO: backend]
//!   delete <name>         -- remove                                [TODO: backend]

const std = @import("std");

const types = @import("types.zig");
const exec_set_mod = @import("exec_set.zig");
const vz = @import("vz.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var it = std.process.Args.Iterator.init(init.minimal.args);
    defer it.deinit();
    _ = it.skip(); // argv[0]

    const command = it.next() orelse {
        std.debug.print(
            "error: command required (check | exec-set | prepare | cleanup | pull | run | wait | stop | delete)\n",
            .{},
        );
        std.process.exit(2);
    };
    // Second positional: namespace for exec-set/prepare/cleanup, otherwise the
    // container id / image, matching orchd-apple's slot convention.
    const slot = it.next() orelse "orch";

    if (std.mem.eql(u8, command, "check")) {
        cmdCheck();
    } else if (std.mem.eql(u8, command, "exec-set")) {
        try cmdExecSet(allocator, io, slot);
    } else if (std.mem.eql(u8, command, "prepare")) {
        try cmdPrepare(allocator, io);
    } else if (std.mem.eql(u8, command, "cleanup")) {
        try cmdCleanup(allocator, io, slot);
    } else if (std.mem.eql(u8, command, "pull")) {
        notImplemented("pull", slot);
    } else if (std.mem.eql(u8, command, "run")) {
        const image = it.next() orelse {
            std.debug.print("error: run requires <name> <image>\n", .{});
            std.process.exit(2);
        };
        cmdRun(allocator, slot, image);
    } else if (std.mem.eql(u8, command, "wait")) {
        cmdWait(allocator, slot);
    } else if (std.mem.eql(u8, command, "stop")) {
        cmdStop(allocator, slot);
    } else if (std.mem.eql(u8, command, "delete")) {
        cmdDelete(allocator, slot);
    } else {
        std.debug.print("error: unknown command '{s}'\n", .{command});
        std.process.exit(2);
    }
}

fn cmdCheck() void {
    if (vz.available()) {
        std.debug.print(
            "orchd-osx ok: Virtualization.framework backend (scaffold)\n" ++
                "  control plane wired; container exec pending (see ORCHD_OSX.md)\n",
            .{},
        );
        return;
    }
    std.debug.print("error: Virtualization.framework backend unavailable on this host\n", .{});
    std.process.exit(1);
}

fn cmdExecSet(allocator: std.mem.Allocator, io: std.Io, namespace: []const u8) !void {
    const svc = readService(allocator, io) catch std.process.exit(1);
    defer svc.deinit();
    if (!std.mem.eql(u8, svc.value.mode, "container")) {
        std.debug.print("error: apple runtime only handles container-mode services\n", .{});
        std.process.exit(1);
    }
    const es = exec_set_mod.build(allocator, io, svc.value, namespace) catch |err| {
        std.debug.print("error: exec-set: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer es.deinit(allocator);
    const json = try std.json.Stringify.valueAlloc(allocator, es, .{});
    defer allocator.free(json);

    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    try fw.interface.writeAll(json);
    try fw.interface.flush();
}

fn cmdPrepare(allocator: std.mem.Allocator, io: std.Io) !void {
    const svc = readService(allocator, io) catch std.process.exit(1);
    defer svc.deinit();
    const image = svc.value.image orelse {
        std.debug.print("error: service has no image\n", .{});
        std.process.exit(1);
    };
    // TODO(step 4): fetch the image and build/cache its ext4 rootfs.
    std.debug.print("orchd-osx prepare: image '{s}' (rootfs prep is a scaffold no-op)\n", .{image});
}

fn cmdCleanup(allocator: std.mem.Allocator, io: std.Io, namespace: []const u8) !void {
    const svc = readService(allocator, io) catch std.process.exit(1);
    defer svc.deinit();
    const name = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ namespace, svc.value.name });
    defer allocator.free(name);
    vz.delete(allocator, name) catch {};
}

fn cmdRun(allocator: std.mem.Allocator, id: []const u8, image: []const u8) void {
    vz.run(allocator, id, image) catch |err| backendStub("run", id, err);
}

fn cmdWait(allocator: std.mem.Allocator, id: []const u8) void {
    const code = vz.wait(allocator, id) catch |err| {
        backendStub("wait", id, err);
        return;
    };
    std.process.exit(@intCast(code));
}

fn cmdStop(allocator: std.mem.Allocator, id: []const u8) void {
    vz.stop(allocator, id) catch |err| backendStub("stop", id, err);
}

fn cmdDelete(allocator: std.mem.Allocator, id: []const u8) void {
    vz.delete(allocator, id) catch |err| backendStub("delete", id, err);
}

/// Uniform exit for a not-yet-built backend operation.
fn backendStub(op: []const u8, id: []const u8, err: vz.Error) noreturn {
    std.debug.print(
        "orchd-osx {s} {s}: {s} (Virtualization.framework backend pending)\n",
        .{ op, id, @errorName(err) },
    );
    std.process.exit(1);
}

fn notImplemented(op: []const u8, arg: []const u8) noreturn {
    std.debug.print("orchd-osx {s} {s}: not implemented yet\n", .{ op, arg });
    std.process.exit(1);
}

/// Read all of stdin, then parse as Service JSON.
fn readService(allocator: std.mem.Allocator, io: std.Io) !std.json.Parsed(types.Service) {
    var buf: [4096]u8 = undefined;
    var fr = std.Io.File.stdin().reader(io, &buf);
    const data = fr.interface.allocRemaining(allocator, .unlimited) catch {
        std.debug.print("error: failed to read stdin\n", .{});
        return error.ReadFailed;
    };
    defer allocator.free(data);
    return std.json.parseFromSlice(types.Service, allocator, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        std.debug.print("error: failed to parse service JSON: {s}\n", .{@errorName(err)});
        return error.ParseFailed;
    };
}
