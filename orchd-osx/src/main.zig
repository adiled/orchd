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
//!   pull   <image>        -- fetch an image
//!   run    <name> <image> -- boot a VM and run the container (blocks until exit)
//!   wait   <name>         -- no-op (run is the foreground process)
//!   stop   <name>         -- stop the container VM
//!   delete <name>         -- remove the container's state

const std = @import("std");

const types = @import("types.zig");
const exec_set_mod = @import("exec_set.zig");
const vz = @import("vz.zig");
const vm = @import("vm.zig");
const kernel = @import("kernel.zig");
const proto = @import("proto.zig");

extern "c" fn chmod(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

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
        cmdPull(allocator, io, slot);
    } else if (std.mem.eql(u8, command, "run")) {
        const image = it.next() orelse {
            std.debug.print("error: run requires <name> <image>\n", .{});
            std.process.exit(2);
        };
        cmdRun(allocator, io, slot, image, &it);
    } else if (std.mem.eql(u8, command, "wait")) {
        cmdWait(allocator, slot);
    } else if (std.mem.eql(u8, command, "stop")) {
        cmdStop(allocator, slot);
    } else if (std.mem.eql(u8, command, "delete")) {
        cmdDelete(allocator, slot);
    } else if (std.mem.eql(u8, command, "vz-selftest")) {
        try cmdSelftest(allocator);
    } else if (std.mem.eql(u8, command, "vz-run-test")) {
        try cmdRunTest(allocator, io);
    } else {
        std.debug.print("error: unknown command '{s}'\n", .{command});
        std.process.exit(2);
    }
}

fn cmdCheck() void {
    if (vz.available()) {
        std.debug.print("orchd-osx ok: Virtualization.framework backend ready\n", .{});
        return;
    }
    std.debug.print("error: Virtualization.framework backend unavailable on this host\n", .{});
    std.process.exit(1);
}

/// pull: pre-fetch + cache the image so a later run starts fast (pre_start).
fn cmdPull(allocator: std.mem.Allocator, io: std.Io, image: []const u8) void {
    vz.pullImage(allocator, io, image) catch |err| {
        std.debug.print("orchd-osx pull {s}: {s}\n", .{ image, @errorName(err) });
        std.process.exit(1);
    };
    std.debug.print("orchd-osx pull: {s} cached\n", .{image});
}

/// vz-selftest: boot our pinned kernel with NO rootfs and confirm VZ's start
/// completion fires without error. The kernel will panic ("unable to mount
/// root") inside the guest, but that happens AFTER a successful start, so a
/// clean start proves the entitlement + kernel + our VZ config all work. The
/// serial console is wired to stderr, so guest boot logs print here.
fn cmdSelftest(allocator: std.mem.Allocator) !void {
    const kpath = kernel.kernelPath(allocator) catch |err| {
        std.debug.print("vz-selftest: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer allocator.free(kpath);
    const kpath_z = try allocator.dupeZ(u8, kpath);
    defer allocator.free(kpath_z);

    std.debug.print("vz-selftest: booting {s} (no rootfs)\n", .{kpath_z});

    const spec = vm.BootSpec{
        .kernel_path = kpath_z,
        .cmdline = "console=hvc0",
        .rootfs_path = "/nonexistent-rootfs",
        .cpu_count = 1,
        .memory_bytes = 512 * 1024 * 1024,
        .vsock_port = 1024,
    };

    var machine = vm.boot(spec) catch |err| {
        std.debug.print("vz-selftest: BOOT FAILED ({s})\n", .{@errorName(err)});
        std.process.exit(1);
    };
    std.debug.print("vz-selftest: VZ start SUCCEEDED (entitlement + kernel + config OK)\n", .{});
    _ = csleep(3); // let the kernel print to the console
    machine.shutdown();
    std.debug.print("vz-selftest: shut down. ok.\n", .{});
}

/// vz-run-test: the full pipeline against a controlled rootfs (no network).
/// Builds an ext4 with a tiny static payload, boots it, and runs the payload
/// over vsock. Proves ext4 mount + guest init as PID 1 + vsock exec + exit code.
fn cmdRunTest(allocator: std.mem.Allocator, io: std.Io) !void {
    const rootfs = "/tmp/orchd-osx-runtest/rootfs";
    std.Io.Dir.cwd().createDirPath(io, rootfs) catch {};

    const payload = readPayload(allocator, io) catch |e| {
        std.debug.print("vz-run-test: cannot read payload binary ({s})\n", .{@errorName(e)});
        std.process.exit(1);
    };
    defer allocator.free(payload);

    const ppath = rootfs ++ "/payload";
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ppath, .data = payload }) catch |e| {
        std.debug.print("vz-run-test: cannot write payload ({s})\n", .{@errorName(e)});
        std.process.exit(1);
    };
    _ = chmod(ppath, 0o755);

    const spec = proto.ExecSpec{ .argv = &.{"/payload"}, .env = &.{}, .cwd = "/" };
    std.debug.print("vz-run-test: booting container, exec /payload ...\n", .{});

    const code = vz.runRootfs(allocator, io, "runtest", rootfs, spec, .{}) catch |e| {
        std.debug.print("vz-run-test: FAILED ({s})\n", .{@errorName(e)});
        std.process.exit(1);
    };
    std.debug.print("vz-run-test: container exited with code {d}\n", .{code});
    std.process.exit(@intCast(code));
}

/// Read the test payload binary: $ORCHD_OSX_PAYLOAD, else next to this exe.
fn readPayload(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    if (getenv("ORCHD_OSX_PAYLOAD")) |p| {
        return std.Io.Dir.cwd().readFileAlloc(io, std.mem.span(p), allocator, .unlimited);
    }
    const dir = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(dir);
    const path = try std.fmt.allocPrint(allocator, "{s}/orchd-osx-payload", .{dir});
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
}

extern "c" fn sleep(seconds: c_uint) c_uint;
fn csleep(seconds: c_uint) c_uint {
    return sleep(seconds);
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

fn cmdRun(allocator: std.mem.Allocator, io: std.Io, id: []const u8, image: []const u8, it: *std.process.Args.Iterator) void {
    // Optional `--spec <base64>` carries the Service config (env/cmd/etc).
    var spec_b64: ?[]const u8 = null;
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--spec")) spec_b64 = it.next();
    }

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ov: vz.Overrides = if (spec_b64) |b64|
        buildOverrides(arena, io, b64) catch .{}
    else
        .{};

    const code = vz.run(allocator, io, id, image, ov) catch |err| backendStub("run", id, err);
    std.process.exit(@intCast(code));
}

/// Decode the base64 Service spec and turn it into run Overrides (env from the
/// env map + env_files, plus entrypoint/cmd/workdir). All slices are arena-owned.
fn buildOverrides(arena: std.mem.Allocator, io: std.Io, b64: []const u8) !vz.Overrides {
    const dec = std.base64.standard.Decoder;
    const json = try arena.alloc(u8, try dec.calcSizeForSlice(b64));
    try dec.decode(json, b64);
    const svc = try std.json.parseFromSliceLeaky(types.Service, arena, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });

    var env: std.ArrayList([]const u8) = .empty;
    if (svc.env == .object) {
        var eit = svc.env.object.iterator();
        while (eit.next()) |e| {
            const v = switch (e.value_ptr.*) {
                .string => |s| s,
                else => continue,
            };
            try env.append(arena, try std.fmt.allocPrint(arena, "{s}={s}", .{ e.key_ptr.*, v }));
        }
    }
    for (svc.env_files) |ef| {
        const data = std.Io.Dir.cwd().readFileAlloc(io, ef, arena, .unlimited) catch continue;
        var lit = std.mem.splitScalar(u8, data, '\n');
        while (lit.next()) |line| {
            const t = std.mem.trim(u8, line, " \r\t");
            if (t.len == 0 or t[0] == '#') continue;
            if (std.mem.indexOfScalar(u8, t, '=') == null) continue;
            try env.append(arena, try arena.dupe(u8, t));
        }
    }

    var limits = proto.Limits{};
    const r = svc.resources;
    if (r.limit_nofile) |n| limits.nofile = n;
    if (r.limit_nproc) |n| limits.nproc = n;
    if (r.tasks_max) |n| limits.pids_max = n;
    if (r.io_weight) |w| limits.io_weight = w;
    if (r.cpu_quota) |q| {
        if (parseCpuQuota(q)) |cq| {
            limits.cpu_quota_us = cq.quota_us;
            limits.cpu_period_us = cq.period_us;
        }
    }

    return .{
        .env = try env.toOwnedSlice(arena),
        .entrypoint = svc.entrypoint,
        .cmd = svc.cmd,
        .workdir = svc.workdir,
        .memory_mb = if (svc.resources.memory) |m| parseMemoryMb(m) else null,
        .cpus = if (svc.resources.cpus) |c| cpusToCount(c) else null,
        .user = svc.user,
        .limits = limits,
        .volumes = svc.volumes,
    };
}

/// Parse a CPU quota string into a cgroup v2 cpu.max (quota,period) pair in
/// microseconds. Accepts "50%" (systemd style) or a bare number treated as a
/// percentage. period is fixed at 100000us. Returns null if unparseable.
fn parseCpuQuota(s: []const u8) ?struct { quota_us: u64, period_us: u64 } {
    const t = std.mem.trim(u8, s, " \t%");
    const pct = std.fmt.parseInt(u64, t, 10) catch return null;
    if (pct == 0) return null;
    const period: u64 = 100000;
    return .{ .quota_us = pct * period / 100, .period_us = period };
}

/// Parse a memory size string into megabytes for the VM RAM. Accepts k/m/g (and
/// the Ki/Mi/Gi variants) suffixes, case-insensitive; a bare number is bytes.
/// Returns null if unparseable (caller falls back to the default).
fn parseMemoryMb(s: []const u8) ?u64 {
    const t = std.mem.trim(u8, s, " \t");
    var end: usize = 0;
    while (end < t.len and t[end] >= '0' and t[end] <= '9') end += 1;
    if (end == 0) return null;
    const num = std.fmt.parseInt(u64, t[0..end], 10) catch return null;
    const suffix = std.mem.trim(u8, t[end..], " \t");
    var bytes: u64 = num;
    if (suffix.len > 0) {
        bytes = switch (std.ascii.toLower(suffix[0])) {
            'k' => num * 1024,
            'm' => num * 1024 * 1024,
            'g' => num * 1024 * 1024 * 1024,
            else => num,
        };
    }
    const mb = bytes / (1024 * 1024);
    return if (mb == 0) 1 else mb;
}

/// Round a fractional CPU request up to whole vCPUs (min 1).
fn cpusToCount(c: f64) usize {
    if (c <= 1.0) return 1;
    return @intFromFloat(@ceil(c));
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
