const std = @import("std");
const message = @import("message.zig");
const parser = @import("parser.zig");
const timer = @import("timer.zig");

pub const TransactionId = [12]u8;
pub const RetryPolicy = timer.RetryPolicy;

pub const PendingTransaction = struct {
    transaction_id: TransactionId,
    user_tag: u64,
    first_sent_ms: u64,
    last_sent_ms: u64,
    transmissions_sent: u8,
    next_retransmit_at_ms: u64,
    expire_at_ms: u64,
};

pub const MatchedResponse = struct {
    transaction_id: TransactionId,
    user_tag: u64,
    rtt_ms: u64,
    transmissions_sent: u8,
    message_type: u16,
    message_class: message.MessageClass,
    is_error_response: bool,
};

pub const MatchError = parser.ParserError || error{
    NotResponse,
    UnknownTransaction,
    ClockSkew,
};

pub const TransactionStore = struct {
    allocator: std.mem.Allocator,
    policy: RetryPolicy,
    map: std.AutoHashMap(TransactionId, PendingTransaction),

    pub fn init(allocator: std.mem.Allocator, policy: RetryPolicy) TransactionStore {
        return .{
            .allocator = allocator,
            .policy = policy,
            .map = std.AutoHashMap(TransactionId, PendingTransaction).init(allocator),
        };
    }

    pub fn deinit(self: *TransactionStore) void {
        self.map.deinit();
    }

    pub fn count(self: TransactionStore) usize {
        return self.map.count();
    }

    pub fn start(self: *TransactionStore, transaction_id: TransactionId, now_ms: u64, user_tag: u64) !void {
        const first_delay = self.policy.next_delay_ms(1);
        const entry = PendingTransaction{
            .transaction_id = transaction_id,
            .user_tag = user_tag,
            .first_sent_ms = now_ms,
            .last_sent_ms = now_ms,
            .transmissions_sent = 1,
            .next_retransmit_at_ms = now_ms + first_delay,
            .expire_at_ms = now_ms + self.policy.total_timeout_ms(),
        };

        try self.map.put(transaction_id, entry);
    }

    pub fn get(self: *TransactionStore, transaction_id: TransactionId) ?*PendingTransaction {
        return self.map.getPtr(transaction_id);
    }

    pub fn acknowledge(self: *TransactionStore, transaction_id: TransactionId) bool {
        return self.map.remove(transaction_id);
    }

    pub fn match_response(self: *TransactionStore, view: parser.MessageView, now_ms: u64) MatchError!MatchedResponse {
        if (!message.is_response_type(view.header.message_type)) return error.NotResponse;

        const tx = self.map.get(view.header.transaction_id) orelse return error.UnknownTransaction;
        if (now_ms < tx.first_sent_ms) return error.ClockSkew;

        const matched = MatchedResponse{
            .transaction_id = view.header.transaction_id,
            .user_tag = tx.user_tag,
            .rtt_ms = now_ms - tx.first_sent_ms,
            .transmissions_sent = tx.transmissions_sent,
            .message_type = view.header.message_type,
            .message_class = message.message_class(view.header.message_type),
            .is_error_response = message.is_error_response_type(view.header.message_type),
        };

        _ = self.map.remove(view.header.transaction_id);
        return matched;
    }

    pub fn collect_due_retransmits(self: *TransactionStore, now_ms: u64, out: []TransactionId) usize {
        var due_count: usize = 0;
        var it = self.map.iterator();
        while (it.next()) |entry| {
            const tx = entry.value_ptr.*;
            const max_total_sends = self.policy.max_retransmits + 1;
            if (tx.transmissions_sent >= max_total_sends) continue;
            if (now_ms < tx.next_retransmit_at_ms) continue;

            if (due_count < out.len) {
                out[due_count] = entry.key_ptr.*;
            }
            due_count += 1;
        }

        return due_count;
    }

    pub fn mark_retransmitted(self: *TransactionStore, transaction_id: TransactionId, now_ms: u64) error{ NotFound, RetryLimitReached }!void {
        const tx = self.map.getPtr(transaction_id) orelse return error.NotFound;

        const max_total_sends = self.policy.max_retransmits + 1;
        if (tx.transmissions_sent >= max_total_sends) return error.RetryLimitReached;

        tx.transmissions_sent += 1;
        tx.last_sent_ms = now_ms;
        tx.next_retransmit_at_ms = now_ms + self.policy.next_delay_ms(tx.transmissions_sent);
    }

    pub fn expire_and_collect(self: *TransactionStore, now_ms: u64, out: []TransactionId) usize {
        var removed: usize = 0;
        while (true) {
            var found: ?TransactionId = null;

            var it = self.map.iterator();
            while (it.next()) |entry| {
                if (now_ms >= entry.value_ptr.expire_at_ms) {
                    found = entry.key_ptr.*;
                    break;
                }
            }

            if (found) |id| {
                _ = self.map.remove(id);
                if (removed < out.len) out[removed] = id;
                removed += 1;
                continue;
            }

            break;
        }

        return removed;
    }
};

pub fn from_rng(random: std.Random) TransactionId {
    var tx_id: TransactionId = undefined;
    random.bytes(&tx_id);
    return tx_id;
}

pub fn from_header(header: message.Header) TransactionId {
    return header.transaction_id;
}

pub fn equals(a: TransactionId, b: TransactionId) bool {
    return std.mem.eql(u8, &a, &b);
}

pub fn to_hex(tx_id: TransactionId, out: []u8) error{BufferTooSmall}![]const u8 {
    if (out.len < 24) return error.BufferTooSmall;

    const hex = "0123456789abcdef";
    for (tx_id, 0..) |byte, idx| {
        out[idx * 2] = hex[(byte >> 4) & 0x0f];
        out[idx * 2 + 1] = hex[byte & 0x0f];
    }

    return out[0..24];
}

test "transaction id can be extracted from header" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    const header = message.Header.init(0x0001, 0, tx_id);

    const extracted = from_header(header);
    try std.testing.expect(equals(tx_id, extracted));
}

test "transaction id generator uses RNG bytes" {
    var prng = std.Random.DefaultPrng.init(0xBADC0FFE);
    const random = prng.random();

    const a = from_rng(random);
    const b = from_rng(random);

    try std.testing.expect(!equals(a, b));
}

test "transaction id hex formatting" {
    const tx_id = [_]u8{ 0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe, 0x01, 0x23, 0x45, 0x67 };
    var buffer: [24]u8 = undefined;
    const hex = try to_hex(tx_id, &buffer);

    try std.testing.expectEqualStrings("1032547698badcfe01234567", hex);
}

test "transaction id hex formatting rejects short output buffer" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    var buffer: [23]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, to_hex(tx_id, &buffer));
}

test "transaction store schedules retransmit and acknowledge" {
    var store = TransactionStore.init(std.testing.allocator, .{});
    defer store.deinit();

    const tx_id = [_]u8{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 };
    try store.start(tx_id, 1000, 42);
    try std.testing.expectEqual(@as(usize, 1), store.count());

    var due: [4]TransactionId = undefined;
    try std.testing.expectEqual(@as(usize, 0), store.collect_due_retransmits(1499, &due));
    try std.testing.expectEqual(@as(usize, 1), store.collect_due_retransmits(1500, &due));
    try std.testing.expectEqualDeep(tx_id, due[0]);

    try store.mark_retransmitted(tx_id, 1500);
    const entry = store.get(tx_id).?;
    try std.testing.expectEqual(@as(u8, 2), entry.transmissions_sent);
    try std.testing.expectEqual(@as(u64, 2500), entry.next_retransmit_at_ms);

    try std.testing.expect(store.acknowledge(tx_id));
    try std.testing.expectEqual(@as(usize, 0), store.count());
}

test "transaction store enforces retry cap" {
    var store = TransactionStore.init(std.testing.allocator, .{ .base_rto_ms = 10, .max_retransmits = 1 });
    defer store.deinit();

    const tx_id = [_]u8{ 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2 };
    try store.start(tx_id, 0, 7);

    try store.mark_retransmitted(tx_id, 10);
    try std.testing.expectError(error.RetryLimitReached, store.mark_retransmitted(tx_id, 30));
}

test "transaction store expires old entries" {
    var store = TransactionStore.init(std.testing.allocator, .{ .base_rto_ms = 100, .max_retransmits = 2 });
    defer store.deinit();

    const a = [_]u8{ 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const b = [_]u8{ 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

    try store.start(a, 0, 1);
    try store.start(b, 50, 2);

    var expired: [4]TransactionId = undefined;
    // Timeout is 700ms for this policy.
    const removed = store.expire_and_collect(749, &expired);
    try std.testing.expectEqual(@as(usize, 1), removed);
    try std.testing.expectEqualDeep(a, expired[0]);
    try std.testing.expectEqual(@as(usize, 1), store.count());
}

test "transaction store matches success response and removes entry" {
    var store = TransactionStore.init(std.testing.allocator, .{});
    defer store.deinit();

    const tx_id = [_]u8{ 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9 };
    try store.start(tx_id, 1000, 123);
    try store.mark_retransmitted(tx_id, 1500);

    var packet: [message.header_size]u8 = undefined;
    const header = message.Header.init(0x0101, 0, tx_id);
    _ = try header.encode(&packet);

    const view = try parser.parse_message(&packet);
    const matched = try store.match_response(view, 1800);
    try std.testing.expectEqualDeep(tx_id, matched.transaction_id);
    try std.testing.expectEqual(@as(u64, 123), matched.user_tag);
    try std.testing.expectEqual(@as(u64, 800), matched.rtt_ms);
    try std.testing.expectEqual(@as(u8, 2), matched.transmissions_sent);
    try std.testing.expectEqual(message.MessageClass.success_response, matched.message_class);
    try std.testing.expect(!matched.is_error_response);
    try std.testing.expectEqual(@as(usize, 0), store.count());
}

test "transaction store matches error response" {
    var store = TransactionStore.init(std.testing.allocator, .{});
    defer store.deinit();

    const tx_id = [_]u8{ 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8 };
    try store.start(tx_id, 100, 5);

    var packet: [message.header_size]u8 = undefined;
    const header = message.Header.init(0x0111, 0, tx_id);
    _ = try header.encode(&packet);

    const view = try parser.parse_message(&packet);
    const matched = try store.match_response(view, 200);
    try std.testing.expect(matched.is_error_response);
    try std.testing.expectEqual(message.MessageClass.error_response, matched.message_class);
}

test "transaction store rejects non-response or unknown tx" {
    var store = TransactionStore.init(std.testing.allocator, .{});
    defer store.deinit();

    const tx_id = [_]u8{ 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7 };
    try store.start(tx_id, 100, 5);

    var request_packet: [message.header_size]u8 = undefined;
    const request_header = message.Header.init(0x0001, 0, tx_id);
    _ = try request_header.encode(&request_packet);
    const request_view = try parser.parse_message(&request_packet);
    try std.testing.expectError(error.NotResponse, store.match_response(request_view, 200));

    var unknown_packet: [message.header_size]u8 = undefined;
    const unknown_tx = [_]u8{ 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6 };
    const unknown_header = message.Header.init(0x0101, 0, unknown_tx);
    _ = try unknown_header.encode(&unknown_packet);
    const unknown_view = try parser.parse_message(&unknown_packet);
    try std.testing.expectError(error.UnknownTransaction, store.match_response(unknown_view, 200));
}
