//! Shared types — mirrors the JSON schema emitted by the `orch` Rust crate.
//! Fields match Rust's serde snake_case serialization exactly.
//!
//! Identical to orchd-apple/src/types.zig by design: orchd-osx honors the same
//! Service -> ExecSet contract so the Rust `apple` envelope treats both
//! co-processes interchangeably. Kept as a separate copy so orchd-osx builds
//! with zero coupling to orchd-apple's source tree.

const std = @import("std");

// ─── Input: Service (subset of orch types) ─────────────────────────────────

pub const Port = struct {
    address: ?[]const u8 = null,
    host: u16,
    container: u16,
};

pub const Volume = struct {
    source: []const u8,
    destination: []const u8,
    is_named: bool = false,
};

pub const Resources = struct {
    memory: ?[]const u8 = null,
    cpus: ?f64 = null,
    limit_nofile: ?u64 = null,
};

/// A parsed service definition from the orch Orchfile.
/// `env` is left as a raw JSON Value so we can iterate its keys without
/// needing a HashMap type in std.json deserialization.
pub const Service = struct {
    name: []const u8,
    mode: []const u8,
    image: ?[]const u8 = null,
    entrypoint: ?[]const u8 = null,
    cmd: ?[]const u8 = null,
    publish: []const Port = &.{},
    volumes: []const Volume = &.{},
    user: ?[]const u8 = null,
    workdir: ?[]const u8 = null,
    env: std.json.Value = .null,
    env_files: []const []const u8 = &.{},
    resources: Resources = .{},
    recreate: []const u8 = "never",
    oneshot: bool = false,
};

// ─── Output: ExecSet ───────────────────────────────────────────────────────

/// Mirrors orchd's Rust `ExecSet` struct — serialized as JSON to stdout.
pub const ExecSet = struct {
    /// Main process command (ExecStart= / ProgramArguments in launchd).
    /// Runs in the foreground so the supervisor (launchd/systemd) tracks the PID.
    start: []const u8,

    /// Pre-start command (ExecStartPre= / analogous in launchd).
    /// Used for image pull.
    pre_start: ?[]const u8 = null,

    /// Graceful stop command (ExecStop=).
    stop: ?[]const u8 = null,

    /// Post-stop cleanup (ExecStopPost=).
    /// Used to delete the container so the next start gets a fresh one.
    post_stop: ?[]const u8 = null,

    /// Free all owned strings. Call when the ExecSet was produced by exec_set.build().
    pub fn deinit(self: ExecSet, allocator: std.mem.Allocator) void {
        allocator.free(self.start);
        if (self.pre_start) |s| allocator.free(s);
        if (self.stop) |s| allocator.free(s);
        if (self.post_stop) |s| allocator.free(s);
    }
};
