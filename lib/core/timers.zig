const std = @import("std");

pub const TimerId = u64;

pub const Timer = struct {
    id: TimerId,
    due_tick: u64,
    callback: *const fn (ctx: *anyopaque) void,
    ctx: *anyopaque,
};

pub const TimerWheel = struct {
    allocator: std.mem.Allocator,
    now_tick: u64,
    next_id: TimerId,
    timers: std.ArrayList(Timer),

    pub fn init(allocator: std.mem.Allocator) TimerWheel {
        return .{
            .allocator = allocator,
            .now_tick = 0,
            .next_id = 1,
            .timers = .empty,
        };
    }

    pub fn deinit(self: *TimerWheel) void {
        self.timers.deinit(self.allocator);
    }

    pub fn now(self: TimerWheel) u64 {
        return self.now_tick;
    }

    pub fn schedule_after(self: *TimerWheel, delay_ticks: u64, callback: *const fn (ctx: *anyopaque) void, ctx: *anyopaque) !TimerId {
        const id = self.next_id;
        self.next_id += 1;

        try self.timers.append(self.allocator, .{
            .id = id,
            .due_tick = self.now_tick + delay_ticks,
            .callback = callback,
            .ctx = ctx,
        });

        return id;
    }

    pub fn cancel(self: *TimerWheel, id: TimerId) bool {
        for (self.timers.items, 0..) |timer, idx| {
            if (timer.id == id) {
                _ = self.timers.orderedRemove(idx);
                return true;
            }
        }
        return false;
    }

    pub fn advance(self: *TimerWheel, delta_ticks: u64) usize {
        self.now_tick += delta_ticks;

        var fired: usize = 0;
        var idx: usize = 0;
        while (idx < self.timers.items.len) {
            const timer = self.timers.items[idx];
            if (timer.due_tick <= self.now_tick) {
                _ = self.timers.orderedRemove(idx);
                timer.callback(timer.ctx);
                fired += 1;
                continue;
            }
            idx += 1;
        }

        return fired;
    }

    pub fn pending_count(self: TimerWheel) usize {
        return self.timers.items.len;
    }
};

test "timer fires after advance reaches due tick" {
    var wheel = TimerWheel.init(std.testing.allocator);
    defer wheel.deinit();

    const Counter = struct {
        value: usize = 0,
    };

    var counter = Counter{};

    const incr = struct {
        fn run(ctx: *anyopaque) void {
            const counter_ptr: *Counter = @ptrCast(@alignCast(ctx));
            counter_ptr.value += 1;
        }
    }.run;

    _ = try wheel.schedule_after(5, incr, @ptrCast(&counter));

    try std.testing.expectEqual(@as(usize, 0), wheel.advance(4));
    try std.testing.expectEqual(@as(usize, 0), counter.value);

    try std.testing.expectEqual(@as(usize, 1), wheel.advance(1));
    try std.testing.expectEqual(@as(usize, 1), counter.value);
}

test "timer cancel prevents callback execution" {
    var wheel = TimerWheel.init(std.testing.allocator);
    defer wheel.deinit();

    const Counter = struct {
        value: usize = 0,
    };

    var counter = Counter{};

    const incr = struct {
        fn run(ctx: *anyopaque) void {
            const counter_ptr: *Counter = @ptrCast(@alignCast(ctx));
            counter_ptr.value += 1;
        }
    }.run;

    const id = try wheel.schedule_after(3, incr, @ptrCast(&counter));
    try std.testing.expect(wheel.cancel(id));

    try std.testing.expectEqual(@as(usize, 0), wheel.advance(10));
    try std.testing.expectEqual(@as(usize, 0), counter.value);
}
