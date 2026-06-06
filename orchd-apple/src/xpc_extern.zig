//! Raw extern declarations for the macOS XPC C API.
//!
//! We declare only the subset we need rather than translating the full xpc.h —
//! this avoids any SDK path issues and works identically on Zig 0.15 and 0.16.
//! XPC symbols are in libSystem.dylib which Zig links automatically on macOS.
//!
//! Sources:
//!   /usr/include/xpc/xpc.h
//!   https://github.com/apple/container  (wire protocol)

const std = @import("std");

// --- Opaque handle types ---

pub const xpc_object_t = *anyopaque;
pub const xpc_connection_t = *anyopaque;

/// Returned by xpc_get_type(). Compare with XPC_TYPE_* constants below.
pub const xpc_type_t = *const anyopaque;

/// xpc_handler_t is `void (^)(xpc_object_t)` — an Objective-C *block*, not a
/// plain function pointer. We pass a hand-built global block literal (see
/// xpc.zig) as an opaque pointer.
pub const xpc_handler_t = *const anyopaque;

// --- Block runtime (libSystem) ---
//
// Block-based C APIs expect a pointer to a Block literal whose first word is an
// "isa" class pointer. For a block with no captured variables we can use the
// global-block class `_NSConcreteGlobalBlock` and a statically-allocated
// literal. This lets us satisfy block APIs from pure Zig with no ObjC runtime.

pub extern const _NSConcreteGlobalBlock: anyopaque;

/// Block flags. BLOCK_IS_GLOBAL = 1<<28 marks a statically-allocated block so
/// the runtime never tries to copy/free it.
pub const BLOCK_IS_GLOBAL: c_int = 1 << 28;

pub const BlockDescriptor = extern struct {
    reserved: c_ulong = 0,
    size: c_ulong,
};

/// Layout matches the Clang Block ABI for a non-capturing global block.
pub const BlockLiteral = extern struct {
    isa: *const anyopaque,
    flags: c_int,
    reserved: c_int = 0,
    invoke: *const anyopaque,
    descriptor: *const BlockDescriptor,
};

// --- Type identity constants (defined in xpc.h as pointers to statics) ---

extern const _xpc_type_error: anyopaque;
extern const _xpc_type_dictionary: anyopaque;

pub const XPC_TYPE_ERROR: xpc_type_t = @ptrCast(&_xpc_type_error);
pub const XPC_TYPE_DICTIONARY: xpc_type_t = @ptrCast(&_xpc_type_dictionary);

// Known XPC error objects (connection interrupted / invalid).
pub extern const _xpc_error_connection_interrupted: anyopaque;
pub extern const _xpc_error_connection_invalid: anyopaque;

// --- Connection ---

pub extern fn xpc_connection_create_mach_service(
    name: [*:0]const u8,
    targetq: ?*anyopaque, // dispatch_queue_t — null = default queue
    flags: u64,
) xpc_connection_t;

pub extern fn xpc_connection_set_event_handler(
    connection: xpc_connection_t,
    handler: xpc_handler_t,
) void;

pub extern fn xpc_connection_activate(connection: xpc_connection_t) void;

pub extern fn xpc_connection_cancel(connection: xpc_connection_t) void;

/// Synchronous send: blocks until a reply arrives or the connection fails.
/// Returns an xpc_object_t whose type is XPC_TYPE_DICTIONARY on success
/// or XPC_TYPE_ERROR on failure. Caller must xpc_release the result.
pub extern fn xpc_connection_send_message_with_reply_sync(
    connection: xpc_connection_t,
    message: xpc_object_t,
) xpc_object_t;

// --- Dictionary ---

pub extern fn xpc_dictionary_create_empty() xpc_object_t;

pub extern fn xpc_dictionary_set_string(
    xdict: xpc_object_t,
    key: [*:0]const u8,
    string: [*:0]const u8,
) void;

pub extern fn xpc_dictionary_get_string(
    xdict: xpc_object_t,
    key: [*:0]const u8,
) ?[*:0]const u8;

pub extern fn xpc_dictionary_set_data(
    xdict: xpc_object_t,
    key: [*:0]const u8,
    bytes: [*]const u8,
    length: usize,
) void;

pub extern fn xpc_dictionary_get_data(
    xdict: xpc_object_t,
    key: [*:0]const u8,
    length: *usize,
) ?[*]const u8;

pub extern fn xpc_dictionary_set_bool(
    xdict: xpc_object_t,
    key: [*:0]const u8,
    value: bool,
) void;

/// Wrap a file descriptor as an XPC object (dups the fd). Used to pass stdio
/// over XPC in containerBootstrap.
pub extern fn xpc_fd_create(fd: c_int) ?xpc_object_t;

/// Set an arbitrary xpc_object_t value (e.g. an fd) into a dictionary.
pub extern fn xpc_dictionary_set_value(
    xdict: xpc_object_t,
    key: [*:0]const u8,
    value: xpc_object_t,
) void;

pub extern fn xpc_dictionary_get_int64(
    xdict: xpc_object_t,
    key: [*:0]const u8,
) i64;

// --- Object lifecycle ---

pub extern fn xpc_get_type(object: xpc_object_t) xpc_type_t;
pub extern fn xpc_release(object: xpc_object_t) void;
pub extern fn xpc_retain(object: xpc_object_t) xpc_object_t;
