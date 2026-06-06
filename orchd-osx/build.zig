const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Host binary: orchd-osx (macOS) ──────────────────────────────────────
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The host VMM is Virtualization.framework, driven via the Objective-C
    // runtime. Foundation/objc and libSystem (vsock) link automatically; the
    // framework is linked up front so building out vz.zig needs no build edits.
    exe_mod.linkFramework("Virtualization", .{});
    exe_mod.linkFramework("Foundation", .{});

    const exe = b.addExecutable(.{
        .name = "orchd-osx",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run orchd-osx");
    run_step.dependOn(&run_cmd.step);

    // ── Guest binary: orchd-osx-init (static aarch64-linux, our PID 1) ───────
    const guest_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .musl,
    });
    // proto.zig is the shared wire contract; the guest imports it as a module
    // (cross-directory @import is not allowed, so it is passed by name).
    const guest = b.addExecutable(.{
        .name = "orchd-osx-init",
        .root_module = guestModule(b, guest_target, optimize),
    });
    b.installArtifact(guest);

    // ── Tests ───────────────────────────────────────────────────────────────
    const test_step = b.step("test", "Run unit tests");

    // Plain host test modules (no framework needed).
    for ([_][]const u8{
        "src/exec_set.zig",
        "src/proto.zig",
        "src/vsock.zig",
        "src/kernel.zig",
        "src/oci.zig",
        "src/ext4.zig",
    }) |root| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(root),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // Modules that touch the ObjC runtime / Virtualization link the frameworks.
    for ([_][]const u8{ "src/objc.zig", "src/vm.zig" }) |root| {
        const m = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
        });
        m.linkFramework("Foundation", .{});
        m.linkFramework("Virtualization", .{});
        const t = b.addTest(.{ .root_module = m });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // The guest compiles for linux; type-check it as part of `zig build test`.
    const guest_check = b.addTest(.{
        .root_module = guestModule(b, guest_target, optimize),
    });
    test_step.dependOn(&guest_check.step); // compile-only (cannot run linux here)
}

/// The guest init module, with the shared proto wire contract imported by name.
fn guestModule(
    b: *std.Build,
    guest_target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const proto_mod = b.createModule(.{
        .root_source_file = b.path("src/proto.zig"),
        .target = guest_target,
        .optimize = optimize,
    });
    return b.createModule(.{
        .root_source_file = b.path("src/guest/init.zig"),
        .target = guest_target,
        .optimize = optimize,
        .imports = &.{.{ .name = "proto", .module = proto_mod }},
    });
}
