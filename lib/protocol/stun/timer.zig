const std = @import("std");

pub const RetryPolicy = struct {
    base_rto_ms: u32 = 500,
    max_retransmits: u8 = 7,

    pub fn next_delay_ms(self: RetryPolicy, transmissions_sent: u8) u64 {
        const shift: u6 = @intCast(if (transmissions_sent == 0) 0 else transmissions_sent - 1);
        return @as(u64, self.base_rto_ms) << shift;
    }

    pub fn total_timeout_ms(self: RetryPolicy) u64 {
        var sum: u64 = 0;
        var sent: u8 = 1;
        const max_total_sends = self.max_retransmits + 1;
        while (sent <= max_total_sends) : (sent += 1) {
            sum += self.next_delay_ms(sent);
        }
        return sum;
    }
};

test "retry policy exponential backoff values" {
    const policy = RetryPolicy{ .base_rto_ms = 500, .max_retransmits = 7 };
    try std.testing.expectEqual(@as(u64, 500), policy.next_delay_ms(1));
    try std.testing.expectEqual(@as(u64, 1000), policy.next_delay_ms(2));
    try std.testing.expectEqual(@as(u64, 2000), policy.next_delay_ms(3));
    try std.testing.expectEqual(@as(u64, 64000), policy.next_delay_ms(8));
}

test "retry policy total timeout" {
    const policy = RetryPolicy{ .base_rto_ms = 500, .max_retransmits = 7 };
    try std.testing.expectEqual(@as(u64, 127500), policy.total_timeout_ms());

    const short = RetryPolicy{ .base_rto_ms = 100, .max_retransmits = 2 };
    try std.testing.expectEqual(@as(u64, 700), short.total_timeout_ms());
}
