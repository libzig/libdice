const std = @import("std");

pub const BytestreamMode = enum {
    disabled,
    opportunistic,
    required,
};

pub const BytestreamHooks = struct {
    on_ready: ?*const fn (ctx: *anyopaque, stream_id: u32, component_id: u16) void = null,
    on_data: ?*const fn (ctx: *anyopaque, stream_id: u32, component_id: u16, data: []const u8) void = null,
    on_closed: ?*const fn (ctx: *anyopaque, stream_id: u32, component_id: u16) void = null,
};

pub const BytestreamDispatcher = struct {
    mode: BytestreamMode,
    hooks: BytestreamHooks,
    ctx: ?*anyopaque,

    pub fn init(mode: BytestreamMode) BytestreamDispatcher {
        return .{
            .mode = mode,
            .hooks = .{},
            .ctx = null,
        };
    }

    pub fn set_hooks(self: *BytestreamDispatcher, ctx: *anyopaque, hooks: BytestreamHooks) void {
        self.ctx = ctx;
        self.hooks = hooks;
    }

    pub fn clear_hooks(self: *BytestreamDispatcher) void {
        self.ctx = null;
        self.hooks = .{};
    }

    pub fn emit_ready(self: *const BytestreamDispatcher, stream_id: u32, component_id: u16) void {
        if (self.ctx == null) return;
        if (self.hooks.on_ready) |cb| cb(self.ctx.?, stream_id, component_id);
    }

    pub fn emit_data(self: *const BytestreamDispatcher, stream_id: u32, component_id: u16, data: []const u8) void {
        if (self.ctx == null) return;
        if (self.hooks.on_data) |cb| cb(self.ctx.?, stream_id, component_id, data);
    }

    pub fn emit_closed(self: *const BytestreamDispatcher, stream_id: u32, component_id: u16) void {
        if (self.ctx == null) return;
        if (self.hooks.on_closed) |cb| cb(self.ctx.?, stream_id, component_id);
    }
};

test "bytestream dispatcher invokes hooks when configured" {
    const State = struct {
        ready: usize = 0,
        data: usize = 0,
        closed: usize = 0,
    };

    const handlers = struct {
        fn ready(ctx: *anyopaque, _: u32, _: u16) void {
            const state: *State = @ptrCast(@alignCast(ctx));
            state.ready += 1;
        }

        fn data(ctx: *anyopaque, _: u32, _: u16, payload: []const u8) void {
            const state: *State = @ptrCast(@alignCast(ctx));
            state.data += payload.len;
        }

        fn closed(ctx: *anyopaque, _: u32, _: u16) void {
            const state: *State = @ptrCast(@alignCast(ctx));
            state.closed += 1;
        }
    };

    var state = State{};
    var dispatcher = BytestreamDispatcher.init(.opportunistic);
    dispatcher.set_hooks(&state, .{
        .on_ready = handlers.ready,
        .on_data = handlers.data,
        .on_closed = handlers.closed,
    });

    dispatcher.emit_ready(1, 1);
    dispatcher.emit_data(1, 1, "abc");
    dispatcher.emit_closed(1, 1);

    try std.testing.expectEqual(@as(usize, 1), state.ready);
    try std.testing.expectEqual(@as(usize, 3), state.data);
    try std.testing.expectEqual(@as(usize, 1), state.closed);
}

test "bytestream dispatcher no-ops without hooks" {
    var dispatcher = BytestreamDispatcher.init(.disabled);
    dispatcher.emit_ready(1, 1);
    dispatcher.emit_data(1, 1, "x");
    dispatcher.emit_closed(1, 1);
    try std.testing.expect(true);
}
