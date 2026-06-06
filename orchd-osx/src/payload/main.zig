//! payload — a tiny static aarch64-linux test binary the guest init execs to
//! prove the full pipeline end to end (ext4 -> boot -> vsock -> init -> exec).
//! Prints a line to stdout and exits 7. No libc: raw linux syscalls.

const std = @import("std");

pub fn main() void {
    const msg = "hello from inside the orchd-osx container\n";
    _ = std.os.linux.write(1, msg.ptr, msg.len);
    std.os.linux.exit(7);
}
