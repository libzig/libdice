const std = @import("std");

pub const PairState = enum {
    frozen,
    waiting,
    in_progress,
    succeeded,
    failed,
};

pub const Pair = struct {
    id: u64,
    local_candidate_id: u64,
    remote_candidate_id: u64,
    priority: u64,
    component_id: u16,
    state: PairState,
    nominated: bool = false,
};

pub const Checklist = struct {
    allocator: std.mem.Allocator,
    pairs: std.ArrayList(Pair),
    triggered_queue: std.ArrayList(u64),

    pub fn init(allocator: std.mem.Allocator) Checklist {
        return .{
            .allocator = allocator,
            .pairs = .empty,
            .triggered_queue = .empty,
        };
    }

    pub fn deinit(self: *Checklist) void {
        self.pairs.deinit(self.allocator);
        self.triggered_queue.deinit(self.allocator);
    }

    pub fn add_pair(self: *Checklist, pair: Pair) !void {
        try self.pairs.append(self.allocator, pair);
    }

    pub fn has_pair(self: Checklist, component_id: u16, local_candidate_id: u64, remote_candidate_id: u64) bool {
        for (self.pairs.items) |pair| {
            if (pair.component_id != component_id) continue;
            if (pair.local_candidate_id == local_candidate_id and pair.remote_candidate_id == remote_candidate_id) return true;
        }
        return false;
    }

    pub fn add_pair_unique(self: *Checklist, pair: Pair) !bool {
        if (self.has_pair(pair.component_id, pair.local_candidate_id, pair.remote_candidate_id)) return false;
        try self.add_pair(pair);
        return true;
    }

    pub fn pair_count(self: Checklist) usize {
        return self.pairs.items.len;
    }

    pub fn get_pair(self: *Checklist, pair_id: u64) ?*Pair {
        for (self.pairs.items) |*pair| {
            if (pair.id == pair_id) return pair;
        }
        return null;
    }

    pub fn queue_triggered(self: *Checklist, pair_id: u64) !void {
        if (self.get_pair(pair_id) == null) return error.NotFound;

        for (self.triggered_queue.items) |queued| {
            if (queued == pair_id) return;
        }

        try self.triggered_queue.append(self.allocator, pair_id);
    }

    pub fn pop_next_triggered(self: *Checklist) ?*Pair {
        while (self.triggered_queue.items.len > 0) {
            const pair_id = self.triggered_queue.orderedRemove(0);
            const pair = self.get_pair(pair_id) orelse continue;

            switch (pair.state) {
                .waiting, .frozen => {
                    pair.state = .in_progress;
                    return pair;
                },
                else => continue,
            }
        }

        return null;
    }

    pub fn sort_by_priority_desc(self: *Checklist) void {
        std.mem.sort(Pair, self.pairs.items, {}, struct {
            fn less_than(_: void, a: Pair, b: Pair) bool {
                if (a.priority == b.priority) return a.id < b.id;
                return a.priority > b.priority;
            }
        }.less_than);
    }

    pub fn pop_next_ordinary(self: *Checklist) ?*Pair {
        self.sort_by_priority_desc();

        for (self.pairs.items) |*pair| {
            switch (pair.state) {
                .waiting, .frozen => {
                    pair.state = .in_progress;
                    return pair;
                },
                else => continue,
            }
        }

        return null;
    }

    pub fn mark_succeeded(self: *Checklist, pair_id: u64, nominated: bool) error{NotFound}!void {
        const pair = self.get_pair(pair_id) orelse return error.NotFound;
        pair.state = .succeeded;
        pair.nominated = nominated;
    }

    pub fn mark_failed(self: *Checklist, pair_id: u64) error{NotFound}!void {
        const pair = self.get_pair(pair_id) orelse return error.NotFound;
        pair.state = .failed;
    }

    pub fn count_state(self: Checklist, target: PairState) usize {
        var result_count: usize = 0;
        for (self.pairs.items) |pair| {
            if (pair.state == target) result_count += 1;
        }
        return result_count;
    }

    pub fn has_pending_or_in_progress(self: Checklist) bool {
        for (self.pairs.items) |pair| {
            switch (pair.state) {
                .frozen, .waiting, .in_progress => return true,
                else => {},
            }
        }
        return false;
    }
};

pub fn compute_pair_priority(controlling: bool, local_priority: u32, remote_priority: u32) u64 {
    const g = if (controlling) local_priority else remote_priority;
    const d = if (controlling) remote_priority else local_priority;

    const min_prio = @min(g, d);
    const max_prio = @max(g, d);
    const tie_bit: u64 = if (g > d) 1 else 0;

    return (@as(u64, min_prio) << 32) + (@as(u64, max_prio) << 1) + tie_bit;
}

test "pair priority formula follows expected ordering" {
    const a = compute_pair_priority(true, 200, 100);
    const b = compute_pair_priority(true, 150, 100);
    try std.testing.expect(a > b);

    const c = compute_pair_priority(true, 100, 200);
    const d = compute_pair_priority(false, 200, 100);
    try std.testing.expectEqual(c, d);
}

test "triggered checks are consumed before ordinary checks" {
    var checklist = Checklist.init(std.testing.allocator);
    defer checklist.deinit();

    try checklist.add_pair(.{
        .id = 1,
        .local_candidate_id = 10,
        .remote_candidate_id = 20,
        .priority = 100,
        .component_id = 1,
        .state = .waiting,
    });

    try checklist.add_pair(.{
        .id = 2,
        .local_candidate_id = 11,
        .remote_candidate_id = 21,
        .priority = 1000,
        .component_id = 1,
        .state = .waiting,
    });

    try checklist.queue_triggered(1);

    const triggered = checklist.pop_next_triggered().?;
    try std.testing.expectEqual(@as(u64, 1), triggered.id);
    try std.testing.expectEqual(PairState.in_progress, triggered.state);

    const ordinary = checklist.pop_next_ordinary().?;
    try std.testing.expectEqual(@as(u64, 2), ordinary.id);
}

test "ordinary selection uses descending priority" {
    var checklist = Checklist.init(std.testing.allocator);
    defer checklist.deinit();

    try checklist.add_pair(.{
        .id = 100,
        .local_candidate_id = 1,
        .remote_candidate_id = 2,
        .priority = 10,
        .component_id = 1,
        .state = .waiting,
    });

    try checklist.add_pair(.{
        .id = 200,
        .local_candidate_id = 3,
        .remote_candidate_id = 4,
        .priority = 100,
        .component_id = 1,
        .state = .waiting,
    });

    const next = checklist.pop_next_ordinary().?;
    try std.testing.expectEqual(@as(u64, 200), next.id);
}

test "state transitions to succeeded and failed" {
    var checklist = Checklist.init(std.testing.allocator);
    defer checklist.deinit();

    try checklist.add_pair(.{
        .id = 1,
        .local_candidate_id = 10,
        .remote_candidate_id = 20,
        .priority = 123,
        .component_id = 1,
        .state = .in_progress,
    });

    try checklist.mark_succeeded(1, true);
    const pair = checklist.get_pair(1).?;
    try std.testing.expectEqual(PairState.succeeded, pair.state);
    try std.testing.expect(pair.nominated);

    pair.state = .in_progress;
    try checklist.mark_failed(1);
    try std.testing.expectEqual(PairState.failed, pair.state);
}

test "checklist state counters and pending check detection" {
    var checklist = Checklist.init(std.testing.allocator);
    defer checklist.deinit();

    try checklist.add_pair(.{
        .id = 1,
        .local_candidate_id = 1,
        .remote_candidate_id = 2,
        .priority = 10,
        .component_id = 1,
        .state = .waiting,
    });
    try checklist.add_pair(.{
        .id = 2,
        .local_candidate_id = 3,
        .remote_candidate_id = 4,
        .priority = 9,
        .component_id = 1,
        .state = .failed,
    });

    try std.testing.expectEqual(@as(usize, 1), checklist.count_state(.waiting));
    try std.testing.expectEqual(@as(usize, 1), checklist.count_state(.failed));
    try std.testing.expect(checklist.has_pending_or_in_progress());

    try checklist.mark_failed(1);
    try std.testing.expect(!checklist.has_pending_or_in_progress());
}

test "checklist unique pair insertion by candidate ids" {
    var checklist = Checklist.init(std.testing.allocator);
    defer checklist.deinit();

    try std.testing.expect(try checklist.add_pair_unique(.{
        .id = 1,
        .local_candidate_id = 10,
        .remote_candidate_id = 20,
        .priority = 1,
        .component_id = 1,
        .state = .waiting,
    }));

    try std.testing.expect(!(try checklist.add_pair_unique(.{
        .id = 2,
        .local_candidate_id = 10,
        .remote_candidate_id = 20,
        .priority = 2,
        .component_id = 1,
        .state = .waiting,
    })));

    try std.testing.expectEqual(@as(usize, 1), checklist.pair_count());
}
