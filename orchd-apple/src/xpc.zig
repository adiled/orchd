//! Typed Zig wrapper over the raw XPC C API (xpc_extern.zig).
//!
//! Design goals:
//!   - Every allocation is explicit (allocator passed in)
//!   - No hidden release/retain — caller owns everything
//!   - Synchronous only (Zig async not yet stable as of 0.15/0.16)
//!
//! Wire protocol keys come from apple/container source:
//!   Sources/ContainerXPC/XPCMessage.swift  → ROUTE_KEY / ERROR_KEY
//!   Sources/Services/ContainerAPIService/Client/XPC+.swift → XPCRoute / XPCKeys

const std = @import("std");
const c = @import("xpc_extern.zig");

// Keys defined by apple/container's XPC protocol.
pub const ROUTE_KEY = "com.apple.container.xpc.route";
pub const ERROR_KEY = "com.apple.container.xpc.error";
pub const SERVICE_NAME = "com.apple.container.apiserver";

// Routes (XPCRoute enum rawValues from apple/container).
pub const Route = struct {
    pub const ping = "ping";
    pub const container_stop = "containerStop";
    pub const container_delete = "containerDelete";
    pub const container_list = "containerList";
    pub const container_state = "containerState";
};

// Field keys (XPCKeys enum rawValues from apple/container).
pub const Key = struct {
    pub const id = "id";
    pub const stop_options = "stopOptions";
    pub const force_delete = "forceDelete";
    pub const containers = "containers";
    pub const list_filters = "listFilters";
    pub const api_server_version = "apiServerVersion";
};

// ─── Connection ────────────────────────────────────────────────────────────

pub const Connection = struct {
    handle: c.xpc_connection_t,

    /// Open a connection to com.apple.container.apiserver.
    /// Does not block — activation is lazy; first send() establishes contact.
    pub fn initApiServer() Connection {
        const conn = c.xpc_connection_create_mach_service(SERVICE_NAME, null, 0);
        // libxpc requires a valid event-handler block before activate(); we pass
        // a statically-built no-op global block (see noop_block below).
        c.xpc_connection_set_event_handler(conn, @ptrCast(&noop_block));
        c.xpc_connection_activate(conn);
        return .{ .handle = conn };
    }

    pub fn close(self: Connection) void {
        c.xpc_connection_cancel(self.handle);
    }

    /// Send a message and block for a reply.
    /// Returns an owned Message — caller must call msg.deinit().
    pub fn send(self: Connection, msg: Message) XpcError!Message {
        const raw_reply = c.xpc_connection_send_message_with_reply_sync(
            self.handle,
            msg.handle,
        );
        const reply = Message{ .handle = raw_reply, .owned = true };

        if (c.xpc_get_type(raw_reply) == c.XPC_TYPE_ERROR) {
            defer reply.deinit();
            return XpcError.ConnectionFailed;
        }

        return reply;
    }
};

// The no-op event handler block. The invoke signature for a no-capture block is
// `fn (block_ptr, args...)` — here just the block pointer and the xpc_object_t.
fn noopInvoke(_: *const anyopaque, _: c.xpc_object_t) callconv(.c) void {}

var noop_descriptor = c.BlockDescriptor{ .size = @sizeOf(c.BlockLiteral) };

var noop_block = c.BlockLiteral{
    .isa = &c._NSConcreteGlobalBlock,
    .flags = c.BLOCK_IS_GLOBAL,
    .invoke = @ptrCast(&noopInvoke),
    .descriptor = &noop_descriptor,
};

// ─── Message ───────────────────────────────────────────────────────────────

pub const Message = struct {
    handle: c.xpc_object_t,
    owned: bool = true,

    pub fn init(route: [:0]const u8) Message {
        const dict = c.xpc_dictionary_create_empty();
        c.xpc_dictionary_set_string(dict, ROUTE_KEY, route.ptr);
        return .{ .handle = dict };
    }

    pub fn deinit(self: Message) void {
        if (self.owned) c.xpc_release(self.handle);
    }

    pub fn setString(self: Message, key: [:0]const u8, value: [:0]const u8) void {
        c.xpc_dictionary_set_string(self.handle, key.ptr, value.ptr);
    }

    /// Returns a slice pointing into the XPC object — valid only while self is alive.
    pub fn getString(self: Message, key: [:0]const u8) ?[:0]const u8 {
        const ptr = c.xpc_dictionary_get_string(self.handle, key.ptr) orelse return null;
        return std.mem.span(ptr);
    }

    /// Returns a slice pointing into the XPC object — valid only while self is alive.
    pub fn getData(self: Message, key: [:0]const u8) ?[]const u8 {
        var length: usize = 0;
        const ptr = c.xpc_dictionary_get_data(self.handle, key.ptr, &length) orelse return null;
        return ptr[0..length];
    }

    pub fn setData(self: Message, key: [:0]const u8, data: []const u8) void {
        c.xpc_dictionary_set_data(self.handle, key.ptr, data.ptr, data.len);
    }

    pub fn setBool(self: Message, key: [:0]const u8, value: bool) void {
        c.xpc_dictionary_set_bool(self.handle, key.ptr, value);
    }

    /// Check the error key. Returns XpcError.ApiError if the server sent an error payload.
    pub fn checkError(self: Message) XpcError!void {
        if (self.getData(ERROR_KEY)) |err_data| {
            std.debug.print("xpc apiserver error: {s}\n", .{err_data});
            return XpcError.ApiError;
        }
    }
};

// ─── Errors ────────────────────────────────────────────────────────────────

pub const XpcError = error{
    /// The XPC connection itself failed (daemon not running, interrupted, etc.)
    ConnectionFailed,
    /// The server returned an application-level error in the error key.
    ApiError,
};
