const std = @import("std");

const nghttp2_sources = [_][]const u8{
    "nghttp2_alpn.c",            "nghttp2_buf.c",    "nghttp2_callbacks.c",     "nghttp2_debug.c",
    "nghttp2_extpri.c",          "nghttp2_frame.c",  "nghttp2_hd.c",            "nghttp2_hd_huffman.c",
    "nghttp2_hd_huffman_data.c", "nghttp2_helper.c", "nghttp2_http.c",          "nghttp2_map.c",
    "nghttp2_mem.c",             "nghttp2_option.c", "nghttp2_outbound_item.c", "nghttp2_pq.c",
    "nghttp2_priority_spec.c",   "nghttp2_queue.c",  "nghttp2_ratelim.c",       "nghttp2_rcbuf.c",
    "nghttp2_session.c",         "nghttp2_stream.c", "nghttp2_submit.c",        "nghttp2_time.c",
    "nghttp2_version.c",         "sfparse.c",
};

const nghttp2_flags = [_][]const u8{
    "-DHAVE_ARPA_INET_H=1",
    "-DHAVE_NETINET_IN_H=1",
    "-DHAVE_CLOCK_GETTIME=1",
    "-DHAVE_DECL_CLOCK_MONOTONIC=1",
    "-DNGHTTP2_STATICLIB",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const upstream = b.dependency("nghttp2", .{});

    const nghttp2 = b.addLibrary(.{
        .name = "nghttp2",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    nghttp2.root_module.addIncludePath(upstream.path("lib/includes"));
    nghttp2.root_module.addIncludePath(upstream.path("lib"));
    nghttp2.root_module.addCSourceFiles(.{ .root = upstream.path("lib"), .files = &nghttp2_sources, .flags = &nghttp2_flags });

    const c = b.addTranslateC(.{
        .root_source_file = upstream.path("lib/includes/nghttp2/nghttp2.h"),
        .target = target,
        .optimize = optimize,
    });
    c.addIncludePath(upstream.path("lib/includes"));
    c.defineCMacro("NGHTTP2_STATICLIB", null);

    const mod = b.addModule("orchd_rootstock_containerd", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "nghttp2", .module = c.createModule() }},
    });
    mod.linkLibrary(nghttp2);

    const exe = b.addExecutable(.{
        .name = "orchd-rootstock-containerd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "orchd_rootstock_containerd", .module = mod }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run orchd-rootstock-containerd");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module })).step);
}
