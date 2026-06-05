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

    /// Stop a running container by ID/name.
    /// `signal`  — POSIX signal number (15 = SIGTERM)
    /// `timeout` — seconds to wait before SIGKILL
    pub fn containerStop(
        self: Client,
        allocator: std.mem.Allocator,
        id: []const u8,
        signal: u32,
        timeout_secs: u32,
    ) xpc.XpcError!void {
        const id_z = allocator.dupeZ(u8, id) catch return xpc.XpcError.ConnectionFailed;
        defer allocator.free(id_z);

        // Build stopOptions JSON payload that container-apiserver expects.
        // From ContainerAPIService source: { "signal": N, "timeout": N }
        const opts_json = std.fmt.allocPrint(allocator, "{{\"signal\":{d},\"timeout\":{d}}}", .{
            signal, timeout_secs,
        }) catch return xpc.XpcError.ConnectionFailed;
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
};
