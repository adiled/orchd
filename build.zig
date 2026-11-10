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

const Rootstock = struct {
    name: []const u8,
    installs: bool,
    tests: bool = true,
    grpc: bool = false,
    libc: bool = false,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const filters = b.option([]const []const u8, "test-filter", "Run only the tests whose names contain this") orelse &.{};
    const os = target.result.os.tag;

    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);

    const contract = b.addModule("contract", .{
        .root_source_file = b.path("src/contract/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const grpc = grpcModule(b, target, optimize);

    const test_step = b.step("test", "Run every test this host can run");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = contract, .filters = filters })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = grpc, .filters = filters })).step);

    const orchd = b.addExecutable(.{
        .name = "orchd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/orchd/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "contract", .module = contract },
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });
    b.installArtifact(orchd);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = orchd.root_module, .filters = filters })).step);

    const run_orchd = b.addRunArtifact(orchd);
    run_orchd.step.dependOn(b.getInstallStep());
    run_orchd.addPassthruArgs();
    b.step("run", "Run orchd").dependOn(&run_orchd.step);

    const rootstocks = [_]Rootstock{
        .{ .name = "bare", .installs = true },
        .{ .name = "containerd", .installs = os == .linux, .grpc = true, .libc = true },
        .{ .name = "apple", .installs = os == .macos, .tests = os == .macos },
        .{ .name = "applz", .installs = os == .macos },
    };
    for (rootstocks) |rootstock| {
        if (!rootstock.installs and !rootstock.tests) continue;
        const module = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/rootstock/{s}/main.zig", .{rootstock.name})),
            .target = target,
            .optimize = optimize,
            .link_libc = if (rootstock.libc) true else null,
        });
        module.addImport("contract", contract);
        if (rootstock.grpc) module.addImport("grpc", grpc);

        if (rootstock.installs) b.installArtifact(b.addExecutable(.{
            .name = b.fmt("orchd-rootstock-{s}", .{rootstock.name}),
            .root_module = module,
        }));
        if (rootstock.tests) test_step.dependOn(&b.addRunArtifact(b.addTest(.{
            .name = b.fmt("orchd-rootstock-{s}", .{rootstock.name}),
            .root_module = module,
            .filters = filters,
        })).step);
    }
}

fn grpcModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const upstream = b.dependency("nghttp2", .{});

    const nghttp2 = b.addLibrary(.{
        .name = "nghttp2",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    nghttp2.root_module.addIncludePath(upstream.path("lib/includes"));
    nghttp2.root_module.addIncludePath(upstream.path("lib"));
    nghttp2.root_module.addCSourceFiles(.{ .root = upstream.path("lib"), .files = &nghttp2_sources, .flags = &nghttp2_flags });

    const header = b.addTranslateC(.{
        .root_source_file = upstream.path("lib/includes/nghttp2/nghttp2.h"),
        .target = target,
        .optimize = optimize,
    });
    header.addIncludePath(upstream.path("lib/includes"));
    header.defineCMacro("NGHTTP2_STATICLIB", null);

    const grpc = b.addModule("grpc", .{
        .root_source_file = b.path("src/grpc/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "nghttp2", .module = header.createModule() }},
    });
    grpc.linkLibrary(nghttp2);
    return grpc;
}
