const std = @import("std");
const checklist_mod = @import("checklist.zig");
const conncheck = @import("conncheck.zig");
const component_mod = @import("component.zig");
const parser = @import("../protocol/stun/parser.zig");
const message = @import("../protocol/stun/message.zig");
const transaction = @import("../protocol/stun/transaction.zig");

pub const PairContext = struct {
    local_candidate_id: u64,
    remote_candidate_id: u64,
    nominated: bool,
};

pub const ComponentConnectivityEngine = struct {
    allocator: std.mem.Allocator,
    stream_id: u32,
    component: component_mod.Component,
    checklist: checklist_mod.Checklist,
    tracker: conncheck.ConnectivityCheckTracker,
    pair_contexts: std.AutoHashMap(u64, PairContext),

    pub fn init(
        allocator: std.mem.Allocator,
        stream_id: u32,
        component_id: u16,
        retry_policy: transaction.RetryPolicy,
    ) ComponentConnectivityEngine {
        return .{
            .allocator = allocator,
            .stream_id = stream_id,
            .component = component_mod.Component.init(component_id),
            .checklist = checklist_mod.Checklist.init(allocator),
            .tracker = conncheck.ConnectivityCheckTracker.init(allocator, retry_policy),
            .pair_contexts = std.AutoHashMap(u64, PairContext).init(allocator),
        };
    }

    pub fn deinit(self: *ComponentConnectivityEngine) void {
        self.pair_contexts.deinit();
        self.tracker.deinit();
        self.checklist.deinit();
    }

    pub fn add_pair(self: *ComponentConnectivityEngine, pair: checklist_mod.Pair, context: PairContext) !void {
        try self.checklist.add_pair(pair);
        try self.pair_contexts.put(pair.id, context);
    }

    pub fn start_connecting(self: *ComponentConnectivityEngine) !void {
        if (self.component.state == .disconnected) {
            try self.component.start_connecting();
            return;
        }
        if (self.component.state == .gathering) {
            try self.component.start_connecting();
            return;
        }
    }

    pub fn queue_triggered_pair(self: *ComponentConnectivityEngine, pair_id: u64) !void {
        try self.checklist.queue_triggered(pair_id);
    }

    pub fn start_next_check(self: *ComponentConnectivityEngine, random: std.Random, now_ms: u64) !?transaction.TransactionId {
        var pair = self.checklist.pop_next_triggered();
        if (pair == null) pair = self.checklist.pop_next_ordinary();
        if (pair == null) return null;

        const tx_id = transaction.from_rng(random);
        const ctx = self.pair_contexts.get(pair.?.id) orelse return error.UnknownPairContext;

        try self.tracker.start_check(tx_id, now_ms, pair.?.id, .{
            .stream_id = self.stream_id,
            .component_id = self.component.id,
            .candidate_pair_id = pair.?.id,
            .is_nominated = ctx.nominated,
        });

        return tx_id;
    }

    pub fn collect_due_retransmits(self: *ComponentConnectivityEngine, now_ms: u64, out: []transaction.TransactionId) usize {
        return self.tracker.collect_due_retransmits(now_ms, out);
    }

    pub fn mark_retransmitted(self: *ComponentConnectivityEngine, transaction_id: transaction.TransactionId, now_ms: u64) !void {
        try self.tracker.mark_retransmitted(transaction_id, now_ms);
    }

    pub fn on_response(self: *ComponentConnectivityEngine, view: parser.MessageView, now_ms: u64) !conncheck.CompletedCheck {
        const completed = try self.tracker.on_response(view, now_ms);

        if (completed.is_error_response) {
            try self.checklist.mark_failed(completed.meta.candidate_pair_id);
            self.evaluate_failure_state();
            return completed;
        }

        const ctx = self.pair_contexts.get(completed.meta.candidate_pair_id) orelse return error.UnknownPairContext;
        try self.checklist.mark_succeeded(completed.meta.candidate_pair_id, completed.meta.is_nominated);
        try self.component.on_check_succeeded(
            completed.meta.candidate_pair_id,
            ctx.local_candidate_id,
            ctx.remote_candidate_id,
            completed.meta.is_nominated,
        );

        return completed;
    }

    pub fn expire_timeouts(self: *ComponentConnectivityEngine, now_ms: u64, out: []conncheck.TimedOutCheck) !usize {
        const removed = try self.tracker.expire_checks(now_ms, out);
        for (out[0..@min(out.len, removed)]) |timed_out| {
            _ = self.checklist.mark_failed(timed_out.meta.candidate_pair_id) catch {};
        }

        if (removed > 0) self.evaluate_failure_state();
        return removed;
    }

    pub fn evaluate_failure_state(self: *ComponentConnectivityEngine) void {
        if (self.component.state == .ready) return;

        if (!self.checklist.has_pending_or_in_progress() and self.checklist.count_state(.succeeded) == 0) {
            self.component.mark_failed();
        }
    }
};

test "connectivity engine success path selects pair" {
    var engine = ComponentConnectivityEngine.init(std.testing.allocator, 1, 1, .{});
    defer engine.deinit();

    try engine.start_connecting();
    try engine.add_pair(.{
        .id = 100,
        .local_candidate_id = 10,
        .remote_candidate_id = 20,
        .priority = 1000,
        .component_id = 1,
        .state = .waiting,
    }, .{
        .local_candidate_id = 10,
        .remote_candidate_id = 20,
        .nominated = true,
    });

    var prng = std.Random.DefaultPrng.init(1);
    const tx_id = (try engine.start_next_check(prng.random(), 1000)).?;

    var response_packet: [message.header_size]u8 = undefined;
    const response_header = message.Header.init(0x0101, 0, tx_id);
    _ = try response_header.encode(&response_packet);
    const view = try parser.parse_message(&response_packet);

    const completed = try engine.on_response(view, 1500);
    try std.testing.expectEqual(@as(u64, 100), completed.meta.candidate_pair_id);
    try std.testing.expectEqual(component_mod.ComponentState.ready, engine.component.state);
    try std.testing.expect(engine.component.can_send_data());
}

test "connectivity engine error response drives pair failure" {
    var engine = ComponentConnectivityEngine.init(std.testing.allocator, 2, 1, .{});
    defer engine.deinit();

    try engine.start_connecting();
    try engine.add_pair(.{
        .id = 200,
        .local_candidate_id = 11,
        .remote_candidate_id = 21,
        .priority = 1,
        .component_id = 1,
        .state = .waiting,
    }, .{
        .local_candidate_id = 11,
        .remote_candidate_id = 21,
        .nominated = false,
    });

    var prng = std.Random.DefaultPrng.init(2);
    const tx_id = (try engine.start_next_check(prng.random(), 0)).?;

    var packet: [message.header_size]u8 = undefined;
    const header = message.Header.init(0x0111, 0, tx_id);
    _ = try header.encode(&packet);
    const view = try parser.parse_message(&packet);

    const completed = try engine.on_response(view, 100);
    try std.testing.expect(completed.is_error_response);
    const pair = engine.checklist.get_pair(200).?;
    try std.testing.expectEqual(checklist_mod.PairState.failed, pair.state);
    try std.testing.expectEqual(component_mod.ComponentState.failed, engine.component.state);
}

test "connectivity engine timeout failure transition" {
    var engine = ComponentConnectivityEngine.init(std.testing.allocator, 3, 1, .{ .base_rto_ms = 100, .max_retransmits = 1 });
    defer engine.deinit();

    try engine.start_connecting();
    try engine.add_pair(.{
        .id = 300,
        .local_candidate_id = 1,
        .remote_candidate_id = 2,
        .priority = 5,
        .component_id = 1,
        .state = .waiting,
    }, .{
        .local_candidate_id = 1,
        .remote_candidate_id = 2,
        .nominated = false,
    });

    var prng = std.Random.DefaultPrng.init(3);
    _ = try engine.start_next_check(prng.random(), 0);

    var timed_out: [2]conncheck.TimedOutCheck = undefined;
    const expired = try engine.expire_timeouts(350, &timed_out);
    try std.testing.expectEqual(@as(usize, 1), expired);
    try std.testing.expectEqual(@as(u64, 300), timed_out[0].meta.candidate_pair_id);
    try std.testing.expectEqual(component_mod.ComponentState.failed, engine.component.state);
}

test "connectivity engine uses triggered queue first" {
    var engine = ComponentConnectivityEngine.init(std.testing.allocator, 4, 1, .{});
    defer engine.deinit();

    try engine.start_connecting();
    try engine.add_pair(.{
        .id = 400,
        .local_candidate_id = 1,
        .remote_candidate_id = 2,
        .priority = 100,
        .component_id = 1,
        .state = .waiting,
    }, .{ .local_candidate_id = 1, .remote_candidate_id = 2, .nominated = false });
    try engine.add_pair(.{
        .id = 401,
        .local_candidate_id = 3,
        .remote_candidate_id = 4,
        .priority = 1000,
        .component_id = 1,
        .state = .waiting,
    }, .{ .local_candidate_id = 3, .remote_candidate_id = 4, .nominated = false });

    try engine.queue_triggered_pair(400);

    var prng = std.Random.DefaultPrng.init(4);
    const tx_id = (try engine.start_next_check(prng.random(), 0)).?;

    var packet: [message.header_size]u8 = undefined;
    const header = message.Header.init(0x0101, 0, tx_id);
    _ = try header.encode(&packet);
    const view = try parser.parse_message(&packet);
    const completed = try engine.on_response(view, 10);
    try std.testing.expectEqual(@as(u64, 400), completed.meta.candidate_pair_id);
}
