//! guest/init.zig — our PID 1 inside the container VM (static aarch64-linux).
//!
//! The guest counterpart of vsock.zig. Replaces Apple's vminitd entirely.
//! Responsibilities (in order):
//!   1. mount essentials (/proc, /sys, /dev) and the ext4 rootfs is already /.
//!   2. open a vsock listener on the agreed port.
//!   3. read one Exec frame (proto.ExecSpec) from the host.
//!   4. fork/exec the container process with that argv/env/cwd.
//!   5. stream child stdout/stderr back as Stdout/Stderr frames.
//!   6. reap the child and send an Exit frame with its code.
//!
//! Shares the wire contract with the host by compiling ../proto.zig.
//!
//! STATUS: stub. Built for aarch64-linux (musl, static) by build.zig.

const std = @import("std");
const proto = @import("proto");

pub fn main() !void {
    // TODO(step #10): mount, vsock-listen, exec per proto.ExecSpec, stream, reap.
    _ = proto.MsgType.exec;
}
