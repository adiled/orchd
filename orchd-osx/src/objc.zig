//! objc.zig — the FFI airlock.
//!
//! THE ONLY module that touches the Objective-C runtime. Unsafe `objc_msgSend`
//! goes in here; typed Zig comes out. Every other module calls these wrappers
//! and never the runtime directly. That containment is the whole point: the VM
//! plumbing in vm.zig stays readable because the dangerous casts live here.
//!
//! Scope: just what driving Virtualization.framework needs:
//!   - class lookup, selector registration, a generic msgSend
//!   - NSString / NSURL bridging from Zig slices
//!   - autorelease pools
//!   - a global (non-capturing) completion block + dispatch primitives, so the
//!     async VZ calls (startWithCompletionHandler:, connectToPort:) can be made
//!     synchronous. orchd-osx drives one VM per process, so completion results
//!     can live in module globals reached by a global block (no capturing-block
//!     ABI needed).

const std = @import("std");

pub const Id = *anyopaque;
pub const Class = *anyopaque;
pub const Sel = *anyopaque;

// --- Runtime externs ---

extern "c" fn objc_getClass(name: [*:0]const u8) ?Class;
extern "c" fn sel_registerName(name: [*:0]const u8) Sel;
// Base symbol; cast per-call to the exact signature via msgSend below.
extern "c" fn objc_msgSend() void;
extern "c" fn objc_autoreleasePoolPush() ?*anyopaque;
extern "c" fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;

/// Look up a class by name. Returns null if the class is not registered
/// (e.g. its framework is not linked).
pub fn class(name: [*:0]const u8) ?Class {
    return objc_getClass(name);
}

/// Register/return a selector.
pub fn sel(name: [*:0]const u8) Sel {
    return sel_registerName(name);
}

/// Generic message send. `Ret` is the return type; `args` is a tuple of the
/// objc method arguments (after self+_cmd). objc_msgSend is cast to the exact
/// C signature for the call's arity. Up to 4 args (all VZ calls need fewer).
///
///   const s = msgSend(Id, NSString, sel("stringWithUTF8String:"), .{ptr});
///   const n = msgSend(usize, s, sel("length"), .{});
pub fn msgSend(comptime Ret: type, receiver: ?Id, selector: Sel, args: anytype) Ret {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    return switch (fields.len) {
        0 => blk: {
            const f: *const fn (?Id, Sel) callconv(.c) Ret = @ptrCast(&objc_msgSend);
            break :blk f(receiver, selector);
        },
        1 => blk: {
            const A0 = fields[0].type;
            const f: *const fn (?Id, Sel, A0) callconv(.c) Ret = @ptrCast(&objc_msgSend);
            break :blk f(receiver, selector, args[0]);
        },
        2 => blk: {
            const A0 = fields[0].type;
            const A1 = fields[1].type;
            const f: *const fn (?Id, Sel, A0, A1) callconv(.c) Ret = @ptrCast(&objc_msgSend);
            break :blk f(receiver, selector, args[0], args[1]);
        },
        3 => blk: {
            const A0 = fields[0].type;
            const A1 = fields[1].type;
            const A2 = fields[2].type;
            const f: *const fn (?Id, Sel, A0, A1, A2) callconv(.c) Ret = @ptrCast(&objc_msgSend);
            break :blk f(receiver, selector, args[0], args[1], args[2]);
        },
        4 => blk: {
            const A0 = fields[0].type;
            const A1 = fields[1].type;
            const A2 = fields[2].type;
            const A3 = fields[3].type;
            const f: *const fn (?Id, Sel, A0, A1, A2, A3) callconv(.c) Ret = @ptrCast(&objc_msgSend);
            break :blk f(receiver, selector, args[0], args[1], args[2], args[3]);
        },
        else => @compileError("msgSend supports up to 4 args"),
    };
}

/// Convenience: `[[Class alloc] init]`.
pub fn allocInit(class_name: [*:0]const u8) ?Id {
    const cls = class(class_name) orelse return null;
    const obj = msgSend(?Id, cls, sel("alloc"), .{}) orelse return null;
    return msgSend(?Id, obj, sel("init"), .{});
}

// --- Foundation bridging ---

/// NSString from a NUL-terminated UTF-8 string. Autoreleased.
pub fn nsString(utf8: [*:0]const u8) Id {
    const NSString = class("NSString").?;
    return msgSend(Id, NSString, sel("stringWithUTF8String:"), .{utf8});
}

/// NSURL for a local file path. Autoreleased.
pub fn fileURL(path: [*:0]const u8) Id {
    const NSURL = class("NSURL").?;
    return msgSend(Id, NSURL, sel("fileURLWithPath:"), .{nsString(path)});
}

/// Run `body` inside an autorelease pool.
pub fn autoreleasePool(comptime body: fn () void) void {
    const pool = objc_autoreleasePoolPush();
    defer objc_autoreleasePoolPop(pool);
    body();
}

// --- Blocks (global, non-capturing) ---
//
// A block is an ObjC object whose first word is an isa class pointer. For a
// block with no captured variables we use the global-block class and a static
// literal, identical to the pattern the XPC client uses. The invoke function
// reaches module-global state (see vm.zig) rather than captured variables.

pub extern const _NSConcreteGlobalBlock: anyopaque;
pub const BLOCK_IS_GLOBAL: c_int = 1 << 28;

pub const BlockDescriptor = extern struct {
    reserved: c_ulong = 0,
    size: c_ulong,
};

pub const BlockLiteral = extern struct {
    isa: *const anyopaque,
    flags: c_int,
    reserved: c_int = 0,
    invoke: *const anyopaque,
    descriptor: *const BlockDescriptor,
};

/// Build a static global block literal wrapping `invoke`. `invoke` must be a
/// C-callconv function whose first parameter is the block pointer, followed by
/// the block's declared arguments. Store the returned literal in a `var` with
/// static lifetime and pass `&literal` where an ObjC block is expected.
pub fn globalBlock(comptime invoke: anytype, descriptor: *const BlockDescriptor) BlockLiteral {
    return .{
        .isa = &_NSConcreteGlobalBlock,
        .flags = BLOCK_IS_GLOBAL,
        .invoke = @ptrCast(&invoke),
        .descriptor = descriptor,
    };
}

// --- Dispatch (for async -> sync) ---

pub const dispatch_queue_t = *anyopaque;
pub const dispatch_semaphore_t = *anyopaque;

pub extern "c" fn dispatch_queue_create(label: ?[*:0]const u8, attr: ?*anyopaque) dispatch_queue_t;
pub extern "c" fn dispatch_semaphore_create(value: isize) dispatch_semaphore_t;
pub extern "c" fn dispatch_semaphore_wait(sema: dispatch_semaphore_t, timeout: u64) isize;
pub extern "c" fn dispatch_semaphore_signal(sema: dispatch_semaphore_t) isize;

/// DISPATCH_TIME_FOREVER
pub const DISPATCH_TIME_FOREVER: u64 = ~@as(u64, 0);

// --- Tests ---

test "class lookup, selector, and msgSend round-trip" {
    // Validates the airlock end to end against Foundation: class("NSString"),
    // a selector with a pointer arg, and a uint return.
    const NSString = class("NSString") orelse return error.NoFoundation;
    const s = msgSend(Id, NSString, sel("stringWithUTF8String:"), .{@as([*:0]const u8, "hello")});
    const len = msgSend(usize, s, sel("length"), .{});
    try std.testing.expectEqual(@as(usize, 5), len);
}

test "nsString and fileURL build without crashing" {
    if (class("NSString") == null) return error.NoFoundation;
    const url = fileURL("/tmp/orchd-osx-test");
    // -[NSURL isFileURL] should be YES (1).
    const is_file = msgSend(u8, url, sel("isFileURL"), .{});
    try std.testing.expect(is_file == 1);
}
