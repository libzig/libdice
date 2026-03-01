const std = @import("std");

pub const Task = struct {
    callback: *const fn (ctx: *anyopaque) void,
    ctx: *anyopaque,
};

pub const EventLoop = struct {
    allocator: std.mem.Allocator,
    queue: std.ArrayList(Task),

    pub fn init(allocator: std.mem.Allocator) EventLoop {
        return .{
            .allocator = allocator,
            .queue = std.ArrayList(Task).init(allocator),
        };
    }

    pub fn deinit(self: *EventLoop) void {
        self.queue.deinit();
    }

    pub fn post(self: *EventLoop, task: Task) !void {
        try self.queue.append(task);
    }

    pub fn run_once(self: *EventLoop) bool {
        if (self.queue.items.len == 0) return false;

        const task = self.queue.orderedRemove(0);
        task.callback(task.ctx);
        return true;
    }

    pub fn pending_count(self: EventLoop) usize {
        return self.queue.items.len;
    }
};

test "event loop executes posted task" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var loop = EventLoop.init(arena.allocator());
    defer loop.deinit();

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

    try loop.post(.{
        .callback = incr,
        .ctx = @ptrCast(&counter),
    });

    try std.testing.expectEqual(@as(usize, 1), loop.pending_count());
    try std.testing.expect(loop.run_once());
    try std.testing.expectEqual(@as(usize, 1), counter.value);
    try std.testing.expectEqual(@as(usize, 0), loop.pending_count());
}
