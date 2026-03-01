const std = @import("std");
const connectivity_engine = @import("connectivity_engine.zig");
const checklist = @import("checklist.zig");
const conncheck = @import("conncheck.zig");
const consent = @import("consent.zig");
const component = @import("component.zig");
const nomination = @import("nomination.zig");
const parser = @import("../protocol/stun/parser.zig");
const transaction = @import("../protocol/stun/transaction.zig");

pub const StartedCheck = struct {
    component_id: u16,
    transaction_id: transaction.TransactionId,
};

pub const TimedOutWithComponent = struct {
    component_id: u16,
    timed_out: conncheck.TimedOutCheck,
};

pub const StreamConnectivityStats = struct {
    stream_id: u32,
    component_count: usize,
    pending_transactions: usize,
    waiting_pairs: usize,
    in_progress_pairs: usize,
    succeeded_pairs: usize,
    failed_pairs: usize,
    ready_components: usize,
    failed_components: usize,
};

pub const StreamConnectivityRuntime = struct {
    allocator: std.mem.Allocator,
    stream_id: u32,
    engines: std.ArrayList(connectivity_engine.ComponentConnectivityEngine),

    pub fn init(
        allocator: std.mem.Allocator,
        stream_id: u32,
        component_ids: []const u16,
        retry_policy: transaction.RetryPolicy,
        consent_config: consent.ConsentConfig,
        nomination_mode: nomination.NominationMode,
    ) !StreamConnectivityRuntime {
        var engines = std.ArrayList(connectivity_engine.ComponentConnectivityEngine).empty;
        errdefer {
            for (engines.items) |*engine| engine.deinit();
            engines.deinit(allocator);
        }

        for (component_ids) |component_id| {
            try engines.append(allocator, connectivity_engine.ComponentConnectivityEngine.init(
                allocator,
                stream_id,
                component_id,
                retry_policy,
                consent_config,
                nomination_mode,
            ));
        }

        return .{
            .allocator = allocator,
            .stream_id = stream_id,
            .engines = engines,
        };
    }

    pub fn deinit(self: *StreamConnectivityRuntime) void {
        for (self.engines.items) |*engine| {
            engine.deinit();
        }
        self.engines.deinit(self.allocator);
    }

    pub fn component_count(self: StreamConnectivityRuntime) usize {
        return self.engines.items.len;
    }

    pub fn get_engine(self: *StreamConnectivityRuntime, component_id: u16) ?*connectivity_engine.ComponentConnectivityEngine {
        for (self.engines.items) |*engine| {
            if (engine.component.id == component_id) return engine;
        }
        return null;
    }

    pub fn add_pair(
        self: *StreamConnectivityRuntime,
        component_id: u16,
        pair: checklist.Pair,
        context: connectivity_engine.PairContext,
    ) !void {
        const engine = self.get_engine(component_id) orelse return error.NotFound;
        try engine.add_pair(pair, context);
    }

    pub fn queue_triggered_pair(self: *StreamConnectivityRuntime, component_id: u16, pair_id: u64) !void {
        const engine = self.get_engine(component_id) orelse return error.NotFound;
        try engine.queue_triggered_pair(pair_id);
    }

    pub fn start_connecting_all(self: *StreamConnectivityRuntime) !void {
        for (self.engines.items) |*engine| {
            try engine.start_connecting();
        }
    }

    pub fn reset_for_restart(self: *StreamConnectivityRuntime) !void {
        for (self.engines.items) |*engine| {
            try engine.reset_for_restart();
        }
    }

    pub fn any_consent_due_probe(self: StreamConnectivityRuntime, now_ms: u64) bool {
        for (self.engines.items) |engine| {
            if (engine.consent_due_probe(now_ms)) return true;
        }
        return false;
    }

    pub fn tick_consent_all(self: *StreamConnectivityRuntime, now_ms: u64) usize {
        var failed_components: usize = 0;
        for (self.engines.items) |*engine| {
            if (engine.tick_consent(now_ms)) failed_components += 1;
        }
        return failed_components;
    }

    pub fn stats(self: *StreamConnectivityRuntime) StreamConnectivityStats {
        var pending_transactions: usize = 0;
        var waiting_pairs: usize = 0;
        var in_progress_pairs: usize = 0;
        var succeeded_pairs: usize = 0;
        var failed_pairs: usize = 0;
        var ready_components: usize = 0;
        var failed_components: usize = 0;

        for (self.engines.items) |*engine| {
            const s = engine.stats();
            pending_transactions += s.pending_transactions;
            waiting_pairs += s.waiting_pairs;
            in_progress_pairs += s.in_progress_pairs;
            succeeded_pairs += s.succeeded_pairs;
            failed_pairs += s.failed_pairs;
            if (s.component_state == .ready) ready_components += 1;
            if (s.component_state == .failed) failed_components += 1;
        }

        return .{
            .stream_id = self.stream_id,
            .component_count = self.component_count(),
            .pending_transactions = pending_transactions,
            .waiting_pairs = waiting_pairs,
            .in_progress_pairs = in_progress_pairs,
            .succeeded_pairs = succeeded_pairs,
            .failed_pairs = failed_pairs,
            .ready_components = ready_components,
            .failed_components = failed_components,
        };
    }

    pub fn start_next_check_for_component(
        self: *StreamConnectivityRuntime,
        component_id: u16,
        random: std.Random,
        now_ms: u64,
    ) !?transaction.TransactionId {
        const engine = self.get_engine(component_id) orelse return error.NotFound;
        return engine.start_next_check(random, now_ms);
    }

    pub fn start_next_check_any(
        self: *StreamConnectivityRuntime,
        random: std.Random,
        now_ms: u64,
    ) !?StartedCheck {
        for (self.engines.items) |*engine| {
            const maybe_tx = try engine.start_next_check(random, now_ms);
            if (maybe_tx) |tx_id| {
                return .{
                    .component_id = engine.component.id,
                    .transaction_id = tx_id,
                };
            }
        }

        return null;
    }

    pub fn on_response(
        self: *StreamConnectivityRuntime,
        component_id: u16,
        view: parser.MessageView,
        now_ms: u64,
    ) !conncheck.CompletedCheck {
        const engine = self.get_engine(component_id) orelse return error.NotFound;
        return engine.on_response(view, now_ms);
    }

    pub fn component_state(self: *StreamConnectivityRuntime, component_id: u16) !component.ComponentState {
        const engine = self.get_engine(component_id) orelse return error.NotFound;
        return engine.component.state;
    }

    pub fn expire_timeouts_all(self: *StreamConnectivityRuntime, now_ms: u64, out: []TimedOutWithComponent) !usize {
        var written: usize = 0;

        for (self.engines.items) |*engine| {
            var local: [16]conncheck.TimedOutCheck = undefined;
            const count = try engine.expire_timeouts(now_ms, &local);

            for (local[0..@min(local.len, count)]) |timed_out| {
                if (written < out.len) {
                    out[written] = .{
                        .component_id = engine.component.id,
                        .timed_out = timed_out,
                    };
                }
                written += 1;
            }
        }

        return written;
    }
};

test "stream connectivity runtime handles per-component checks" {
    const component_ids = [_]u16{ 1, 2 };
    var runtime = try StreamConnectivityRuntime.init(std.testing.allocator, 10, &component_ids, .{}, .{}, .aggressive);
    defer runtime.deinit();

    try runtime.start_connecting_all();

    try runtime.add_pair(1, .{
        .id = 101,
        .local_candidate_id = 1,
        .remote_candidate_id = 2,
        .priority = 100,
        .component_id = 1,
        .state = .waiting,
    }, .{ .local_candidate_id = 1, .remote_candidate_id = 2, .nominated = true });

    try runtime.add_pair(2, .{
        .id = 201,
        .local_candidate_id = 3,
        .remote_candidate_id = 4,
        .priority = 100,
        .component_id = 2,
        .state = .waiting,
    }, .{ .local_candidate_id = 3, .remote_candidate_id = 4, .nominated = false });

    var prng = std.Random.DefaultPrng.init(11);
    const started_1 = (try runtime.start_next_check_for_component(1, prng.random(), 1000)).?;
    const started_2 = (try runtime.start_next_check_for_component(2, prng.random(), 1000)).?;

    var packet_1: [20]u8 = undefined;
    const header_1 = @import("../protocol/stun/message.zig").Header.init(0x0101, 0, started_1);
    _ = try header_1.encode(&packet_1);
    const view_1 = try parser.parse_message(&packet_1);
    _ = try runtime.on_response(1, view_1, 1300);

    var packet_2: [20]u8 = undefined;
    const header_2 = @import("../protocol/stun/message.zig").Header.init(0x0111, 0, started_2);
    _ = try header_2.encode(&packet_2);
    const view_2 = try parser.parse_message(&packet_2);
    _ = try runtime.on_response(2, view_2, 1300);

    try std.testing.expectEqual(component.ComponentState.ready, try runtime.component_state(1));
    try std.testing.expectEqual(component.ComponentState.failed, try runtime.component_state(2));
}

test "stream connectivity runtime start_next_check_any uses first available" {
    const component_ids = [_]u16{ 1, 2 };
    var runtime = try StreamConnectivityRuntime.init(std.testing.allocator, 20, &component_ids, .{}, .{}, .regular);
    defer runtime.deinit();

    try runtime.start_connecting_all();

    try runtime.add_pair(2, .{
        .id = 301,
        .local_candidate_id = 1,
        .remote_candidate_id = 2,
        .priority = 10,
        .component_id = 2,
        .state = .waiting,
    }, .{ .local_candidate_id = 1, .remote_candidate_id = 2, .nominated = false });

    var prng = std.Random.DefaultPrng.init(12);
    const started = (try runtime.start_next_check_any(prng.random(), 0)).?;
    try std.testing.expectEqual(@as(u16, 2), started.component_id);
}

test "stream connectivity runtime timeout aggregation" {
    const component_ids = [_]u16{ 1, 2 };
    var runtime = try StreamConnectivityRuntime.init(std.testing.allocator, 30, &component_ids, .{ .base_rto_ms = 100, .max_retransmits = 1 }, .{}, .regular);
    defer runtime.deinit();

    try runtime.start_connecting_all();

    try runtime.add_pair(1, .{
        .id = 401,
        .local_candidate_id = 1,
        .remote_candidate_id = 2,
        .priority = 10,
        .component_id = 1,
        .state = .waiting,
    }, .{ .local_candidate_id = 1, .remote_candidate_id = 2, .nominated = false });

    try runtime.add_pair(2, .{
        .id = 402,
        .local_candidate_id = 3,
        .remote_candidate_id = 4,
        .priority = 10,
        .component_id = 2,
        .state = .waiting,
    }, .{ .local_candidate_id = 3, .remote_candidate_id = 4, .nominated = false });

    var prng = std.Random.DefaultPrng.init(13);
    _ = try runtime.start_next_check_for_component(1, prng.random(), 0);
    _ = try runtime.start_next_check_for_component(2, prng.random(), 50);

    var out: [8]TimedOutWithComponent = undefined;
    const timed_out_count = try runtime.expire_timeouts_all(349, &out);
    try std.testing.expectEqual(@as(usize, 1), timed_out_count);
    try std.testing.expectEqual(@as(u16, 1), out[0].component_id);
}

test "stream connectivity runtime restart clears engines" {
    const component_ids = [_]u16{1};
    var runtime = try StreamConnectivityRuntime.init(std.testing.allocator, 40, &component_ids, .{}, .{}, .regular);
    defer runtime.deinit();

    try runtime.start_connecting_all();
    try runtime.add_pair(1, .{
        .id = 500,
        .local_candidate_id = 1,
        .remote_candidate_id = 2,
        .priority = 100,
        .component_id = 1,
        .state = .waiting,
    }, .{ .local_candidate_id = 1, .remote_candidate_id = 2, .nominated = false });

    var prng = std.Random.DefaultPrng.init(14);
    _ = try runtime.start_next_check_for_component(1, prng.random(), 0);
    try std.testing.expectEqual(@as(usize, 1), runtime.get_engine(1).?.tracker.pending_count());

    try runtime.reset_for_restart();
    try std.testing.expectEqual(component.ComponentState.connecting, try runtime.component_state(1));
    try std.testing.expectEqual(@as(usize, 0), runtime.get_engine(1).?.tracker.pending_count());
    try std.testing.expectEqual(@as(usize, 0), runtime.get_engine(1).?.checklist.pair_count());
}

test "stream connectivity runtime consent probing and failure tick" {
    const component_ids = [_]u16{1};
    var runtime = try StreamConnectivityRuntime.init(
        std.testing.allocator,
        50,
        &component_ids,
        .{},
        .{ .enabled = true, .interval_ms = 10, .response_timeout_ms = 5, .max_missed_probes = 0 },
        .regular,
    );
    defer runtime.deinit();

    try runtime.start_connecting_all();
    try runtime.add_pair(1, .{
        .id = 700,
        .local_candidate_id = 1,
        .remote_candidate_id = 2,
        .priority = 10,
        .component_id = 1,
        .state = .waiting,
    }, .{ .local_candidate_id = 1, .remote_candidate_id = 2, .nominated = true });

    var prng = std.Random.DefaultPrng.init(18);
    const tx_id = (try runtime.start_next_check_for_component(1, prng.random(), 0)).?;

    var packet: [20]u8 = undefined;
    const header = @import("../protocol/stun/message.zig").Header.init(0x0101, 0, tx_id);
    _ = try header.encode(&packet);
    const view = try parser.parse_message(&packet);
    _ = try runtime.on_response(1, view, 2);

    try std.testing.expect(runtime.any_consent_due_probe(12));
    try runtime.get_engine(1).?.on_consent_probe_sent(12);
    const failed = runtime.tick_consent_all(17);
    try std.testing.expectEqual(@as(usize, 1), failed);
    try std.testing.expectEqual(component.ComponentState.failed, try runtime.component_state(1));
}

test "stream connectivity runtime stats snapshot" {
    const component_ids = [_]u16{ 1, 2 };
    var runtime = try StreamConnectivityRuntime.init(std.testing.allocator, 60, &component_ids, .{}, .{}, .regular);
    defer runtime.deinit();

    try runtime.start_connecting_all();
    try runtime.add_pair(1, .{
        .id = 801,
        .local_candidate_id = 1,
        .remote_candidate_id = 2,
        .priority = 10,
        .component_id = 1,
        .state = .waiting,
    }, .{ .local_candidate_id = 1, .remote_candidate_id = 2, .nominated = false });

    var prng = std.Random.DefaultPrng.init(20);
    _ = try runtime.start_next_check_for_component(1, prng.random(), 0);

    const snapshot = runtime.stats();
    try std.testing.expectEqual(@as(u32, 60), snapshot.stream_id);
    try std.testing.expectEqual(@as(usize, 2), snapshot.component_count);
    try std.testing.expectEqual(@as(usize, 1), snapshot.pending_transactions);
    try std.testing.expectEqual(@as(usize, 1), snapshot.in_progress_pairs);
}
