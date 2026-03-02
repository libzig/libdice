const std = @import("std");

pub const ConsentState = enum {
    disabled,
    active,
    awaiting_response,
    failed,
};

pub const ConsentConfig = struct {
    enabled: bool = false,
    interval_ms: u64 = 15_000,
    response_timeout_ms: u64 = 5_000,
    max_missed_probes: u8 = 2,
};

pub const ConsentTracker = struct {
    config: ConsentConfig,
    state: ConsentState,
    pair_id: ?u64,
    last_probe_sent_ms: ?u64,
    last_response_ms: ?u64,
    missed_probes: u8,
    next_probe_at_ms: ?u64,

    pub fn init(config: ConsentConfig) ConsentTracker {
        return .{
            .config = config,
            .state = if (config.enabled) .active else .disabled,
            .pair_id = null,
            .last_probe_sent_ms = null,
            .last_response_ms = null,
            .missed_probes = 0,
            .next_probe_at_ms = null,
        };
    }

    pub fn reset(self: *ConsentTracker) void {
        self.state = if (self.config.enabled) .active else .disabled;
        self.pair_id = null;
        self.last_probe_sent_ms = null;
        self.last_response_ms = null;
        self.missed_probes = 0;
        self.next_probe_at_ms = null;
    }

    pub fn arm(self: *ConsentTracker, pair_id: u64, now_ms: u64) void {
        if (!self.config.enabled) {
            self.state = .disabled;
            self.pair_id = null;
            self.next_probe_at_ms = null;
            return;
        }

        self.state = .active;
        self.pair_id = pair_id;
        self.last_response_ms = now_ms;
        self.last_probe_sent_ms = null;
        self.missed_probes = 0;
        self.next_probe_at_ms = now_ms + self.config.interval_ms;
    }

    pub fn due_probe(self: ConsentTracker, now_ms: u64) bool {
        if (self.state == .disabled or self.state == .failed) return false;
        const next = self.next_probe_at_ms orelse return false;
        return now_ms >= next;
    }

    pub fn on_probe_sent(self: *ConsentTracker, now_ms: u64) error{ NotArmed, Failed }!void {
        if (self.state == .failed) return error.Failed;
        if (self.pair_id == null or self.state == .disabled) return error.NotArmed;

        self.state = .awaiting_response;
        self.last_probe_sent_ms = now_ms;
        self.next_probe_at_ms = now_ms + self.config.response_timeout_ms;
    }

    pub fn on_response(self: *ConsentTracker, now_ms: u64) error{NotArmed}!void {
        if (self.pair_id == null or self.state == .disabled) return error.NotArmed;

        self.state = .active;
        self.last_response_ms = now_ms;
        self.missed_probes = 0;
        self.next_probe_at_ms = now_ms + self.config.interval_ms;
    }

    pub fn on_tick(self: *ConsentTracker, now_ms: u64) bool {
        if (self.state != .awaiting_response) return false;

        const deadline = self.next_probe_at_ms orelse return false;
        if (now_ms < deadline) return false;

        self.missed_probes += 1;
        if (self.missed_probes > self.config.max_missed_probes) {
            self.state = .failed;
            self.next_probe_at_ms = null;
            return true;
        }

        self.state = .active;
        self.next_probe_at_ms = now_ms + self.config.interval_ms;
        return false;
    }
};

test "consent tracker happy path" {
    var tracker = ConsentTracker.init(.{ .enabled = true, .interval_ms = 10, .response_timeout_ms = 5, .max_missed_probes = 2 });
    tracker.arm(42, 100);

    try std.testing.expect(tracker.due_probe(110));
    try tracker.on_probe_sent(110);
    try std.testing.expectEqual(ConsentState.awaiting_response, tracker.state);

    try tracker.on_response(112);
    try std.testing.expectEqual(ConsentState.active, tracker.state);
    try std.testing.expectEqual(@as(u8, 0), tracker.missed_probes);
}

test "consent tracker fails after missed probes" {
    var tracker = ConsentTracker.init(.{ .enabled = true, .interval_ms = 10, .response_timeout_ms = 5, .max_missed_probes = 1 });
    tracker.arm(7, 0);

    try tracker.on_probe_sent(10);
    try std.testing.expect(!tracker.on_tick(14));
    try std.testing.expectEqual(ConsentState.awaiting_response, tracker.state);

    // Miss #1 transitions back to active.
    try std.testing.expect(!tracker.on_tick(15));
    try std.testing.expectEqual(ConsentState.active, tracker.state);

    try tracker.on_probe_sent(25);
    // Miss #2 exceeds max and fails.
    try std.testing.expect(tracker.on_tick(30));
    try std.testing.expectEqual(ConsentState.failed, tracker.state);
}

test "consent tracker disabled mode remains inert" {
    var tracker = ConsentTracker.init(.{ .enabled = false });
    tracker.arm(1, 0);

    try std.testing.expectEqual(ConsentState.disabled, tracker.state);
    try std.testing.expect(!tracker.due_probe(100000));
    try std.testing.expectError(error.NotArmed, tracker.on_probe_sent(10));
}

test "libnice parity: test-consent" {
    var tracker = ConsentTracker.init(.{ .enabled = true, .interval_ms = 10, .response_timeout_ms = 5, .max_missed_probes = 0 });
    tracker.arm(1, 0);
    try tracker.on_probe_sent(10);
    try std.testing.expect(tracker.on_tick(15));
    try std.testing.expectEqual(ConsentState.failed, tracker.state);
}
