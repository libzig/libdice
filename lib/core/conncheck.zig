const std = @import("std");
const parser = @import("../protocol/stun/parser.zig");
const message = @import("../protocol/stun/message.zig");
const transaction = @import("../protocol/stun/transaction.zig");

pub const CheckMeta = struct {
    stream_id: u32,
    component_id: u16,
    candidate_pair_id: u64,
    is_nominated: bool = false,
};

pub const CompletedCheck = struct {
    transaction_id: transaction.TransactionId,
    user_tag: u64,
    meta: CheckMeta,
    rtt_ms: u64,
    transmissions_sent: u8,
    message_type: u16,
    is_error_response: bool,
};

pub const TimedOutCheck = struct {
    transaction_id: transaction.TransactionId,
    user_tag: u64,
    meta: CheckMeta,
};

pub const ConnCheckError = transaction.MatchError || error{ NotFound, RetryLimitReached } || std.mem.Allocator.Error || error{
    UnknownTransactionContext,
};

const CheckContext = struct {
    user_tag: u64,
    meta: CheckMeta,
};

pub const ConnectivityCheckTracker = struct {
    allocator: std.mem.Allocator,
    tx_store: transaction.TransactionStore,
    contexts: std.AutoHashMap(transaction.TransactionId, CheckContext),

    pub fn init(allocator: std.mem.Allocator, retry_policy: transaction.RetryPolicy) ConnectivityCheckTracker {
        return .{
            .allocator = allocator,
            .tx_store = transaction.TransactionStore.init(allocator, retry_policy),
            .contexts = std.AutoHashMap(transaction.TransactionId, CheckContext).init(allocator),
        };
    }

    pub fn deinit(self: *ConnectivityCheckTracker) void {
        self.contexts.deinit();
        self.tx_store.deinit();
    }

    pub fn pending_count(self: ConnectivityCheckTracker) usize {
        return self.contexts.count();
    }

    pub fn start_check(self: *ConnectivityCheckTracker, transaction_id: transaction.TransactionId, now_ms: u64, user_tag: u64, meta: CheckMeta) !void {
        try self.tx_store.start(transaction_id, now_ms, user_tag);
        try self.contexts.put(transaction_id, .{
            .user_tag = user_tag,
            .meta = meta,
        });
    }

    pub fn cancel_check(self: *ConnectivityCheckTracker, transaction_id: transaction.TransactionId) bool {
        _ = self.contexts.remove(transaction_id);
        return self.tx_store.acknowledge(transaction_id);
    }

    pub fn collect_due_retransmits(self: *ConnectivityCheckTracker, now_ms: u64, out: []transaction.TransactionId) usize {
        return self.tx_store.collect_due_retransmits(now_ms, out);
    }

    pub fn mark_retransmitted(self: *ConnectivityCheckTracker, transaction_id: transaction.TransactionId, now_ms: u64) error{ NotFound, RetryLimitReached }!void {
        try self.tx_store.mark_retransmitted(transaction_id, now_ms);
    }

    pub fn on_response(self: *ConnectivityCheckTracker, view: parser.MessageView, now_ms: u64) ConnCheckError!CompletedCheck {
        const matched = try self.tx_store.match_response(view, now_ms);
        const ctx = self.contexts.fetchRemove(matched.transaction_id) orelse return error.UnknownTransactionContext;

        return .{
            .transaction_id = matched.transaction_id,
            .user_tag = ctx.value.user_tag,
            .meta = ctx.value.meta,
            .rtt_ms = matched.rtt_ms,
            .transmissions_sent = matched.transmissions_sent,
            .message_type = matched.message_type,
            .is_error_response = matched.is_error_response,
        };
    }

    pub fn expire_checks(self: *ConnectivityCheckTracker, now_ms: u64, out: []TimedOutCheck) !usize {
        if (self.contexts.count() == 0) return 0;

        var expired_ids = try self.allocator.alloc(transaction.TransactionId, self.contexts.count());
        defer self.allocator.free(expired_ids);

        const removed = self.tx_store.expire_and_collect(now_ms, expired_ids);

        var written: usize = 0;
        for (expired_ids[0..removed]) |tx_id| {
            const ctx = self.contexts.fetchRemove(tx_id) orelse continue;
            if (written < out.len) {
                out[written] = .{
                    .transaction_id = tx_id,
                    .user_tag = ctx.value.user_tag,
                    .meta = ctx.value.meta,
                };
            }
            written += 1;
        }

        return written;
    }
};

test "connectivity check tracker success response flow" {
    var tracker = ConnectivityCheckTracker.init(std.testing.allocator, .{});
    defer tracker.deinit();

    const tx_id = [_]u8{ 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11 };
    try tracker.start_check(tx_id, 1000, 55, .{
        .stream_id = 1,
        .component_id = 1,
        .candidate_pair_id = 99,
        .is_nominated = true,
    });

    var due: [2]transaction.TransactionId = undefined;
    try std.testing.expectEqual(@as(usize, 1), tracker.collect_due_retransmits(1500, &due));
    try tracker.mark_retransmitted(tx_id, 1500);

    var packet: [message.header_size]u8 = undefined;
    const response = message.Header.init(0x0101, 0, tx_id);
    _ = try response.encode(&packet);

    const view = try parser.parse_message(&packet);
    const completed = try tracker.on_response(view, 1800);
    try std.testing.expectEqual(@as(u64, 55), completed.user_tag);
    try std.testing.expectEqual(@as(u64, 99), completed.meta.candidate_pair_id);
    try std.testing.expectEqual(@as(u64, 800), completed.rtt_ms);
    try std.testing.expectEqual(@as(u8, 2), completed.transmissions_sent);
    try std.testing.expect(!completed.is_error_response);
    try std.testing.expectEqual(@as(usize, 0), tracker.pending_count());
}

test "connectivity check tracker handles error response" {
    var tracker = ConnectivityCheckTracker.init(std.testing.allocator, .{});
    defer tracker.deinit();

    const tx_id = [_]u8{ 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12 };
    try tracker.start_check(tx_id, 100, 7, .{ .stream_id = 2, .component_id = 1, .candidate_pair_id = 45 });

    var packet: [message.header_size]u8 = undefined;
    const response = message.Header.init(0x0111, 0, tx_id);
    _ = try response.encode(&packet);

    const view = try parser.parse_message(&packet);
    const completed = try tracker.on_response(view, 200);
    try std.testing.expect(completed.is_error_response);
}

test "connectivity check tracker timeout collection" {
    var tracker = ConnectivityCheckTracker.init(std.testing.allocator, .{ .base_rto_ms = 100, .max_retransmits = 2 });
    defer tracker.deinit();

    const a = [_]u8{ 21, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const b = [_]u8{ 22, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

    try tracker.start_check(a, 0, 1, .{ .stream_id = 1, .component_id = 1, .candidate_pair_id = 1 });
    try tracker.start_check(b, 50, 2, .{ .stream_id = 1, .component_id = 2, .candidate_pair_id = 2 });

    var expired: [4]TimedOutCheck = undefined;
    const count = try tracker.expire_checks(749, &expired);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualDeep(a, expired[0].transaction_id);
    try std.testing.expectEqual(@as(u64, 1), expired[0].user_tag);
    try std.testing.expectEqual(@as(usize, 1), tracker.pending_count());
}

test "connectivity check tracker cancel removes pending" {
    var tracker = ConnectivityCheckTracker.init(std.testing.allocator, .{});
    defer tracker.deinit();

    const tx_id = [_]u8{ 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31 };
    try tracker.start_check(tx_id, 0, 99, .{ .stream_id = 3, .component_id = 1, .candidate_pair_id = 5 });
    try std.testing.expect(tracker.cancel_check(tx_id));
    try std.testing.expectEqual(@as(usize, 0), tracker.pending_count());
}
