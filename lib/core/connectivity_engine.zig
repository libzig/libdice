const std = @import("std");
const checklist_mod = @import("checklist.zig");
const conncheck = @import("conncheck.zig");
const component_mod = @import("component.zig");
const consent_mod = @import("consent.zig");
const nomination = @import("nomination.zig");
const parser = @import("../protocol/stun/parser.zig");
const message = @import("../protocol/stun/message.zig");
const transaction = @import("../protocol/stun/transaction.zig");

pub const PairContext = struct {
    local_candidate_id: u64,
    remote_candidate_id: u64,
    nominated: bool,
};

pub const Event = union(enum) {
    state_changed: struct {
        from: component_mod.ComponentState,
        to: component_mod.ComponentState,
    },
    check_started: struct {
        pair_id: u64,
        transaction_id: transaction.TransactionId,
        at_ms: u64,
    },
    check_succeeded: struct {
        pair_id: u64,
        transaction_id: transaction.TransactionId,
        rtt_ms: u64,
        nominated: bool,
    },
    check_failed: struct {
        pair_id: u64,
        transaction_id: transaction.TransactionId,
        is_error_response: bool,
    },
    check_timed_out: struct {
        pair_id: u64,
    },
    consent_failed: struct {
        pair_id: ?u64,
    },
    restarted: void,
};

pub const ConnectivityEngineStats = struct {
    component_id: u16,
    component_state: component_mod.ComponentState,
    pair_count: usize,
    waiting_pairs: usize,
    in_progress_pairs: usize,
    succeeded_pairs: usize,
    failed_pairs: usize,
    pending_transactions: usize,
    consent_state: consent_mod.ConsentState,
    consent_missed_probes: u8,
};

pub const ComponentConnectivityEngine = struct {
    allocator: std.mem.Allocator,
    stream_id: u32,
    component: component_mod.Component,
    checklist: checklist_mod.Checklist,
    tracker: conncheck.ConnectivityCheckTracker,
    pair_contexts: std.AutoHashMap(u64, PairContext),
    consent: consent_mod.ConsentTracker,
    nomination_mode: nomination.NominationMode,
    requested_nomination_pair_id: ?u64,
    events: std.ArrayList(Event),

    pub fn init(
        allocator: std.mem.Allocator,
        stream_id: u32,
        component_id: u16,
        retry_policy: transaction.RetryPolicy,
        consent_config: consent_mod.ConsentConfig,
        nomination_mode: nomination.NominationMode,
    ) ComponentConnectivityEngine {
        return .{
            .allocator = allocator,
            .stream_id = stream_id,
            .component = component_mod.Component.init(component_id),
            .checklist = checklist_mod.Checklist.init(allocator),
            .tracker = conncheck.ConnectivityCheckTracker.init(allocator, retry_policy),
            .pair_contexts = std.AutoHashMap(u64, PairContext).init(allocator),
            .consent = consent_mod.ConsentTracker.init(consent_config),
            .nomination_mode = nomination_mode,
            .requested_nomination_pair_id = null,
            .events = .empty,
        };
    }

    pub fn deinit(self: *ComponentConnectivityEngine) void {
        self.events.deinit(self.allocator);
        self.pair_contexts.deinit();
        self.tracker.deinit();
        self.checklist.deinit();
    }

    fn emit(self: *ComponentConnectivityEngine, event: Event) !void {
        try self.events.append(self.allocator, event);
    }

    fn emit_state_if_changed(
        self: *ComponentConnectivityEngine,
        before: component_mod.ComponentState,
    ) !void {
        if (before != self.component.state) {
            try self.emit(.{ .state_changed = .{ .from = before, .to = self.component.state } });
        }
    }

    pub fn pop_event(self: *ComponentConnectivityEngine) ?Event {
        if (self.events.items.len == 0) return null;
        return self.events.orderedRemove(0);
    }

    pub fn add_pair(self: *ComponentConnectivityEngine, pair: checklist_mod.Pair, context: PairContext) !void {
        try self.checklist.add_pair(pair);
        try self.pair_contexts.put(pair.id, context);
    }

    pub fn add_pair_unique(self: *ComponentConnectivityEngine, pair: checklist_mod.Pair, context: PairContext) !bool {
        const added = try self.checklist.add_pair_unique(pair);
        if (!added) return false;
        try self.pair_contexts.put(pair.id, context);
        return true;
    }

    pub fn start_connecting(self: *ComponentConnectivityEngine) !void {
        const before = self.component.state;
        if (self.component.state == .disconnected) {
            try self.component.start_connecting();
            try self.emit_state_if_changed(before);
            return;
        }
        if (self.component.state == .gathering) {
            try self.component.start_connecting();
            try self.emit_state_if_changed(before);
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

        try self.emit(.{ .check_started = .{
            .pair_id = pair.?.id,
            .transaction_id = tx_id,
            .at_ms = now_ms,
        } });

        return tx_id;
    }

    pub fn collect_due_retransmits(self: *ComponentConnectivityEngine, now_ms: u64, out: []transaction.TransactionId) usize {
        return self.tracker.collect_due_retransmits(now_ms, out);
    }

    pub fn mark_retransmitted(self: *ComponentConnectivityEngine, transaction_id: transaction.TransactionId, now_ms: u64) !void {
        try self.tracker.mark_retransmitted(transaction_id, now_ms);
    }

    pub fn on_response(self: *ComponentConnectivityEngine, view: parser.MessageView, now_ms: u64) !conncheck.CompletedCheck {
        const before_state = self.component.state;
        const completed = try self.tracker.on_response(view, now_ms);

        if (completed.is_error_response) {
            try self.checklist.mark_failed(completed.meta.candidate_pair_id);
            self.evaluate_failure_state();
            try self.emit(.{ .check_failed = .{
                .pair_id = completed.meta.candidate_pair_id,
                .transaction_id = completed.transaction_id,
                .is_error_response = true,
            } });
            try self.emit_state_if_changed(before_state);
            return completed;
        }

        const ctx = self.pair_contexts.get(completed.meta.candidate_pair_id) orelse return error.UnknownPairContext;
        const requested = completed.meta.is_nominated or (self.requested_nomination_pair_id != null and self.requested_nomination_pair_id.? == completed.meta.candidate_pair_id);
        const nominated = nomination.should_nominate_on_success(self.nomination_mode, requested);

        try self.checklist.mark_succeeded(completed.meta.candidate_pair_id, nominated);
        try self.component.on_check_succeeded(
            completed.meta.candidate_pair_id,
            ctx.local_candidate_id,
            ctx.remote_candidate_id,
            nominated,
        );

        if (nominated) self.requested_nomination_pair_id = null;

        if (self.component.state == .ready or self.component.state == .connected) {
            self.consent.arm(completed.meta.candidate_pair_id, now_ms);
        }

        try self.emit(.{ .check_succeeded = .{
            .pair_id = completed.meta.candidate_pair_id,
            .transaction_id = completed.transaction_id,
            .rtt_ms = completed.rtt_ms,
            .nominated = nominated,
        } });
        try self.emit_state_if_changed(before_state);

        return completed;
    }

    pub fn expire_timeouts(self: *ComponentConnectivityEngine, now_ms: u64, out: []conncheck.TimedOutCheck) !usize {
        const before_state = self.component.state;
        const removed = try self.tracker.expire_checks(now_ms, out);
        for (out[0..@min(out.len, removed)]) |timed_out| {
            _ = self.checklist.mark_failed(timed_out.meta.candidate_pair_id) catch {};
            try self.emit(.{ .check_timed_out = .{ .pair_id = timed_out.meta.candidate_pair_id } });
        }

        if (removed > 0) self.evaluate_failure_state();
        try self.emit_state_if_changed(before_state);
        return removed;
    }

    pub fn evaluate_failure_state(self: *ComponentConnectivityEngine) void {
        if (self.component.state == .ready) return;

        if (!self.checklist.has_pending_or_in_progress() and self.checklist.count_state(.succeeded) == 0) {
            self.component.mark_failed();
        }
    }

    pub fn stats(self: ComponentConnectivityEngine) ConnectivityEngineStats {
        return .{
            .component_id = self.component.id,
            .component_state = self.component.state,
            .pair_count = self.checklist.pair_count(),
            .waiting_pairs = self.checklist.count_state(.waiting),
            .in_progress_pairs = self.checklist.count_state(.in_progress),
            .succeeded_pairs = self.checklist.count_state(.succeeded),
            .failed_pairs = self.checklist.count_state(.failed),
            .pending_transactions = self.tracker.pending_count(),
            .consent_state = self.consent.state,
            .consent_missed_probes = self.consent.missed_probes,
        };
    }

    pub fn consent_due_probe(self: ComponentConnectivityEngine, now_ms: u64) bool {
        return self.consent.due_probe(now_ms);
    }

    pub fn on_consent_probe_sent(self: *ComponentConnectivityEngine, now_ms: u64) !void {
        try self.consent.on_probe_sent(now_ms);
    }

    pub fn on_consent_response(self: *ComponentConnectivityEngine, now_ms: u64) !void {
        try self.consent.on_response(now_ms);
    }

    pub fn tick_consent(self: *ComponentConnectivityEngine, now_ms: u64) bool {
        const before_state = self.component.state;
        const failed = self.consent.on_tick(now_ms);
        if (failed) {
            self.component.mark_failed();
            const pair_id = self.consent.pair_id;
            self.emit(.{ .consent_failed = .{ .pair_id = pair_id } }) catch {};
            self.emit_state_if_changed(before_state) catch {};
        }
        return failed;
    }

    pub fn request_nomination(self: *ComponentConnectivityEngine, pair_id: u64) error{NotFound}!void {
        if (self.checklist.get_pair(pair_id) == null) return error.NotFound;
        self.requested_nomination_pair_id = pair_id;
    }

    pub fn nominate_pair(self: *ComponentConnectivityEngine, pair_id: u64) !void {
        const ctx = self.pair_contexts.get(pair_id) orelse return error.UnknownPairContext;
        try self.checklist.mark_succeeded(pair_id, true);
        try self.component.set_selected_pair(.{
            .pair_id = pair_id,
            .local_candidate_id = ctx.local_candidate_id,
            .remote_candidate_id = ctx.remote_candidate_id,
            .nominated = true,
        });
        self.requested_nomination_pair_id = null;
    }

    pub fn reset_for_restart(self: *ComponentConnectivityEngine) !void {
        const before_state = self.component.state;
        self.checklist.clear();
        self.tracker.clear();
        self.pair_contexts.clearRetainingCapacity();
        self.consent.reset();
        self.requested_nomination_pair_id = null;
        self.component.reset();
        try self.start_connecting();
        try self.emit(.{ .restarted = {} });
        try self.emit_state_if_changed(before_state);
    }
};

test "connectivity engine success path selects pair" {
    var engine = ComponentConnectivityEngine.init(std.testing.allocator, 1, 1, .{}, .{}, .aggressive);
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
    var engine = ComponentConnectivityEngine.init(std.testing.allocator, 2, 1, .{}, .{}, .regular);
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
    var engine = ComponentConnectivityEngine.init(std.testing.allocator, 3, 1, .{ .base_rto_ms = 100, .max_retransmits = 1 }, .{}, .regular);
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
    var engine = ComponentConnectivityEngine.init(std.testing.allocator, 4, 1, .{}, .{}, .regular);
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

test "connectivity engine restart clears state and re-enters connecting" {
    var engine = ComponentConnectivityEngine.init(std.testing.allocator, 5, 1, .{}, .{}, .regular);
    defer engine.deinit();

    try engine.start_connecting();
    try engine.add_pair(.{
        .id = 500,
        .local_candidate_id = 1,
        .remote_candidate_id = 2,
        .priority = 10,
        .component_id = 1,
        .state = .waiting,
    }, .{ .local_candidate_id = 1, .remote_candidate_id = 2, .nominated = true });

    var prng = std.Random.DefaultPrng.init(9);
    _ = try engine.start_next_check(prng.random(), 0);
    try std.testing.expectEqual(@as(usize, 1), engine.checklist.pair_count());
    try std.testing.expectEqual(@as(usize, 1), engine.tracker.pending_count());

    try engine.reset_for_restart();
    try std.testing.expectEqual(component_mod.ComponentState.connecting, engine.component.state);
    try std.testing.expectEqual(@as(usize, 0), engine.checklist.pair_count());
    try std.testing.expectEqual(@as(usize, 0), engine.tracker.pending_count());
}

test "connectivity engine consent freshness lifecycle" {
    var engine = ComponentConnectivityEngine.init(
        std.testing.allocator,
        6,
        1,
        .{},
        .{ .enabled = true, .interval_ms = 10, .response_timeout_ms = 5, .max_missed_probes = 1 },
        .regular,
    );
    defer engine.deinit();

    try engine.start_connecting();
    try engine.add_pair(.{
        .id = 600,
        .local_candidate_id = 1,
        .remote_candidate_id = 2,
        .priority = 10,
        .component_id = 1,
        .state = .waiting,
    }, .{ .local_candidate_id = 1, .remote_candidate_id = 2, .nominated = true });

    var prng = std.Random.DefaultPrng.init(16);
    const tx_id = (try engine.start_next_check(prng.random(), 0)).?;

    var packet: [message.header_size]u8 = undefined;
    const header = message.Header.init(0x0101, 0, tx_id);
    _ = try header.encode(&packet);
    const view = try parser.parse_message(&packet);
    _ = try engine.on_response(view, 2);
    try std.testing.expectEqual(component_mod.ComponentState.ready, engine.component.state);

    try std.testing.expect(engine.consent_due_probe(12));
    try engine.on_consent_probe_sent(12);
    try std.testing.expectEqual(consent_mod.ConsentState.awaiting_response, engine.consent.state);
    try std.testing.expect(!engine.tick_consent(16));
    try std.testing.expectEqual(consent_mod.ConsentState.awaiting_response, engine.consent.state);
    try std.testing.expect(!engine.tick_consent(17));
    try std.testing.expectEqual(consent_mod.ConsentState.active, engine.consent.state);

    try engine.on_consent_probe_sent(27);
    try std.testing.expect(engine.tick_consent(32));
    try std.testing.expectEqual(component_mod.ComponentState.failed, engine.component.state);
}

test "connectivity engine regular nomination upgrade" {
    var engine = ComponentConnectivityEngine.init(std.testing.allocator, 7, 1, .{}, .{}, .regular);
    defer engine.deinit();

    try engine.start_connecting();
    try engine.add_pair(.{
        .id = 700,
        .local_candidate_id = 1,
        .remote_candidate_id = 2,
        .priority = 10,
        .component_id = 1,
        .state = .waiting,
    }, .{ .local_candidate_id = 1, .remote_candidate_id = 2, .nominated = false });

    var prng = std.Random.DefaultPrng.init(17);
    const tx_id = (try engine.start_next_check(prng.random(), 0)).?;

    var packet: [message.header_size]u8 = undefined;
    const header = message.Header.init(0x0101, 0, tx_id);
    _ = try header.encode(&packet);
    const view = try parser.parse_message(&packet);
    _ = try engine.on_response(view, 5);

    try std.testing.expectEqual(component_mod.ComponentState.connected, engine.component.state);
    try engine.nominate_pair(700);
    try std.testing.expectEqual(component_mod.ComponentState.ready, engine.component.state);
}

test "connectivity engine stats snapshot" {
    var engine = ComponentConnectivityEngine.init(std.testing.allocator, 8, 1, .{}, .{}, .regular);
    defer engine.deinit();

    try engine.start_connecting();
    try engine.add_pair(.{
        .id = 800,
        .local_candidate_id = 1,
        .remote_candidate_id = 2,
        .priority = 10,
        .component_id = 1,
        .state = .waiting,
    }, .{ .local_candidate_id = 1, .remote_candidate_id = 2, .nominated = false });

    var prng = std.Random.DefaultPrng.init(19);
    _ = try engine.start_next_check(prng.random(), 0);

    const snapshot = engine.stats();
    try std.testing.expectEqual(@as(u16, 1), snapshot.component_id);
    try std.testing.expectEqual(@as(usize, 1), snapshot.pair_count);
    try std.testing.expectEqual(@as(usize, 1), snapshot.in_progress_pairs);
    try std.testing.expectEqual(@as(usize, 1), snapshot.pending_transactions);
}

test "connectivity engine emits events" {
    var engine = ComponentConnectivityEngine.init(std.testing.allocator, 9, 1, .{}, .{}, .aggressive);
    defer engine.deinit();

    try engine.start_connecting();
    try engine.add_pair(.{
        .id = 900,
        .local_candidate_id = 1,
        .remote_candidate_id = 2,
        .priority = 10,
        .component_id = 1,
        .state = .waiting,
    }, .{ .local_candidate_id = 1, .remote_candidate_id = 2, .nominated = false });

    var prng = std.Random.DefaultPrng.init(26);
    const tx_id = (try engine.start_next_check(prng.random(), 0)).?;

    var packet: [message.header_size]u8 = undefined;
    const header = message.Header.init(0x0101, 0, tx_id);
    _ = try header.encode(&packet);
    const view = try parser.parse_message(&packet);
    _ = try engine.on_response(view, 10);

    var saw_started = false;
    var saw_succeeded = false;
    while (engine.pop_event()) |event| {
        switch (event) {
            .check_started => saw_started = true,
            .check_succeeded => saw_succeeded = true,
            else => {},
        }
    }
    try std.testing.expect(saw_started);
    try std.testing.expect(saw_succeeded);
}
