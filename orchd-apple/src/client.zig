//! Client for com.apple.container.apiserver.
//!
//! Covers the operations orchd needs:
//!   ping      — liveness check (used by `orchd-apple check`)
//!   stop      — graceful container stop
//!   delete    — container deletion
//!
//! All calls are synchronous. Zig async is not stable yet; for a daemon
//! liveness check the latency is acceptable.

const std = @import("std");
const xpc = @import("xpc.zig");

pub const Client = struct {
    conn: xpc.Connection,

    pub fn init() Client {
        return .{ .conn = xpc.Connection.initApiServer() };
    }

    pub fn deinit(self: Client) void {
        self.conn.close();
    }

    // ── Liveness ──────────────────────────────────────────────────────────

    /// Sends a ping to the apiserver. Returns error if the daemon is not running.
    /// On success fills `version_buf` with the server version string (up to buf_len bytes).
    pub fn ping(self: Client, version_buf: []u8) xpc.XpcError![]const u8 {
        const req = xpc.Message.init(xpc.Route.ping);
        defer req.deinit();

        const reply = try self.conn.send(req);
        defer reply.deinit();

        try reply.checkError();

        const ver = reply.getString(xpc.Key.api_server_version) orelse "(unknown)";
        const n = @min(ver.len, version_buf.len);
        @memcpy(version_buf[0..n], ver[0..n]);
        return version_buf[0..n];
    }

    // ── Container lifecycle ────────────────────────────────────────────────

    /// Stop a running container by ID/name, waiting `timeout_secs` before SIGKILL.
    /// Signal is left unset so the daemon uses the container's stop signal /
    /// runtime default (matches the CLI's default behavior).
    pub fn containerStop(
        self: Client,
        allocator: std.mem.Allocator,
        id: []const u8,
        timeout_secs: i32,
    ) xpc.XpcError!void {
        const id_z = allocator.dupeZ(u8, id) catch return xpc.XpcError.ConnectionFailed;
        defer allocator.free(id_z);

        // ContainerStopOptions @ 0.12.3 { timeoutInSeconds: Int32, signal: Int32 }
        // signal is a number (15 = SIGTERM). NOTE: this struct differs across
        // container versions; it must match the pinned, installed daemon.
        const opts_json = std.fmt.allocPrint(
            allocator,
            "{{\"timeoutInSeconds\":{d},\"signal\":15}}",
            .{timeout_secs},
        ) catch return xpc.XpcError.ConnectionFailed;
        defer allocator.free(opts_json);

        const req = xpc.Message.init(xpc.Route.container_stop);
        defer req.deinit();
        req.setString(xpc.Key.id, id_z);
        req.setData(xpc.Key.stop_options, opts_json);

        const reply = try self.conn.send(req);
        defer reply.deinit();
        try reply.checkError();
    }

    /// Delete a container. Pass force=true to delete even if running.
    pub fn containerDelete(
        self: Client,
        allocator: std.mem.Allocator,
        id: []const u8,
        force: bool,
    ) xpc.XpcError!void {
        const id_z = allocator.dupeZ(u8, id) catch return xpc.XpcError.ConnectionFailed;
        defer allocator.free(id_z);

        const req = xpc.Message.init(xpc.Route.container_delete);
        defer req.deinit();
        req.setString(xpc.Key.id, id_z);
        req.setBool(xpc.Key.force_delete, force);

        const reply = try self.conn.send(req);
        defer reply.deinit();
        try reply.checkError();
    }

    /// List containers. Returns the apiserver's JSON-encoded [ContainerSnapshot]
    /// array as an owned slice (caller frees). This is the structured observe
    /// plane: typed data straight from the daemon, no CLI text scraping.
    pub fn containerList(self: Client, allocator: std.mem.Allocator) xpc.XpcError![]u8 {
        const req = xpc.Message.init(xpc.Route.container_list);
        defer req.deinit();

        // ContainerListFilters.all encodes with its non-optional fields present.
        // (Swift's synthesized Decodable requires the keys, even at defaults.)
        req.setData(xpc.Key.list_filters, "{\"ids\":[],\"labels\":{}}");

        const reply = try self.conn.send(req);
        defer reply.deinit();
        try reply.checkError();

        const containers = reply.getData(xpc.Key.containers) orelse return allocator.dupe(u8, "[]") catch xpc.XpcError.ConnectionFailed;
        return allocator.dupe(u8, containers) catch xpc.XpcError.ConnectionFailed;
    }

    /// Get the default kernel for the given platform. Returns the apiserver's
    /// JSON-encoded Kernel as an owned slice, which is relayed verbatim into the
    /// `kernel` field of a containerCreate request (no need to parse it).
    pub fn getDefaultKernel(
        self: Client,
        allocator: std.mem.Allocator,
        platform_json: []const u8,
    ) xpc.XpcError![]u8 {
        const req = xpc.Message.init(xpc.Route.get_default_kernel);
        defer req.deinit();
        req.setData(xpc.Key.system_platform, platform_json);

        const reply = try self.conn.send(req);
        defer reply.deinit();
        try reply.checkError();

        const data = reply.getData(xpc.Key.kernel) orelse return xpc.XpcError.ApiError;
        return allocator.dupe(u8, data) catch xpc.XpcError.ConnectionFailed;
    }

    /// containerCreate: register a container from a fully-built configuration.
    /// `config_json`/`kernel_json`/`options_json` are encoded structs; `init_image`
    /// is the init image reference.
    pub fn containerCreate(
        self: Client,
        allocator: std.mem.Allocator,
        config_json: []const u8,
        kernel_json: []const u8,
        options_json: []const u8,
        init_image: []const u8,
    ) xpc.XpcError!void {
        const init_z = allocator.dupeZ(u8, init_image) catch return xpc.XpcError.ConnectionFailed;
        defer allocator.free(init_z);

        const req = xpc.Message.init(xpc.Route.container_create);
        defer req.deinit();
        req.setData(xpc.Key.container_config, config_json);
        req.setData(xpc.Key.kernel, kernel_json);
        req.setData(xpc.Key.container_options, options_json);
        req.setString(xpc.Key.init_image, init_z);

        const reply = try self.conn.send(req);
        defer reply.deinit();
        try reply.checkError();
    }

    /// containerBootstrap: create the container's init process, wiring stdio.
    /// `stdio_fd` is used for stdin/stdout/stderr (e.g. an open /dev/null fd).
    pub fn containerBootstrap(self: Client, allocator: std.mem.Allocator, id: []const u8, stdio_fd: c_int) xpc.XpcError!void {
        const id_z = allocator.dupeZ(u8, id) catch return xpc.XpcError.ConnectionFailed;
        defer allocator.free(id_z);

        const req = xpc.Message.init(xpc.Route.container_bootstrap);
        defer req.deinit();
        req.setFd(xpc.Key.stdin, stdio_fd);
        req.setFd(xpc.Key.stdout, stdio_fd);
        req.setFd(xpc.Key.stderr, stdio_fd);
        req.setData(xpc.Key.dynamic_env, "{}");
        req.setString(xpc.Key.id, id_z);

        const reply = try self.conn.send(req);
        defer reply.deinit();
        try reply.checkError();
    }

    /// containerStartProcess: start the init process (processIdentifier == id).
    pub fn containerStartProcess(self: Client, allocator: std.mem.Allocator, id: []const u8) xpc.XpcError!void {
        const id_z = allocator.dupeZ(u8, id) catch return xpc.XpcError.ConnectionFailed;
        defer allocator.free(id_z);

        const req = xpc.Message.init(xpc.Route.container_start_process);
        defer req.deinit();
        req.setString(xpc.Key.id, id_z);
        req.setString(xpc.Key.process_identifier, id_z);

        const reply = try self.conn.send(req);
        defer reply.deinit();
        try reply.checkError();
    }
};

/// Fetch a content-store blob by digest via the core-images service. The daemon
/// replies with a local file path (`contentPath`); we read and return its bytes.
/// Used to walk image index -> manifest -> OCI config for create.
pub fn contentGet(allocator: std.mem.Allocator, io: std.Io, digest: []const u8) xpc.XpcError![]u8 {
    const conn = xpc.Connection.initService(xpc.IMAGES_SERVICE);
    defer conn.close();

    const dig_z = allocator.dupeZ(u8, digest) catch return xpc.XpcError.ConnectionFailed;
    defer allocator.free(dig_z);

    const req = xpc.Message.init(xpc.Route.content_get);
    defer req.deinit();
    req.setString(xpc.Key.digest, dig_z);

    const reply = try conn.send(req);
    defer reply.deinit();
    try reply.checkError();

    const path = reply.getString(xpc.Key.content_path) orelse return xpc.XpcError.ApiError;
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch xpc.XpcError.ApiError;
}
pub fn imageList(allocator: std.mem.Allocator) xpc.XpcError![]u8 {
    const conn = xpc.Connection.initService(xpc.IMAGES_SERVICE);
    defer conn.close();

    const req = xpc.Message.init(xpc.Route.image_list);
    defer req.deinit();

    const reply = try conn.send(req);
    defer reply.deinit();
    try reply.checkError();

    const data = reply.getData(xpc.Key.image_descriptions) orelse return allocator.dupe(u8, "[]") catch xpc.XpcError.ConnectionFailed;
    return allocator.dupe(u8, data) catch xpc.XpcError.ConnectionFailed;
}
