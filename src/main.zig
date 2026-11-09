const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    _ = init;
    return 0;
}

test {
    _ = @import("types.zig");
    _ = @import("config.zig");
    _ = @import("supervise.zig");
}
