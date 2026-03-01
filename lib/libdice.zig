const std = @import("std");

pub const EventLoop = @import("core/events.zig").EventLoop;
pub const EventTask = @import("core/events.zig").Task;
pub const FeatureFlags = @import("core/feature_flags.zig").FeatureFlags;
pub const TimerWheel = @import("core/timers.zig").TimerWheel;
pub const TimerId = @import("core/timers.zig").TimerId;
pub const StunHeader = @import("protocol/stun/message.zig").Header;
pub const StunAttrHeader = @import("protocol/stun/attrs.zig").AttrHeader;
pub const StunMessageView = @import("protocol/stun/parser.zig").MessageView;
pub const parse_stun_message = @import("protocol/stun/parser.zig").parse_message;
pub const StunMessageBuilder = @import("protocol/stun/encoder.zig").Builder;
pub const StunTransactionId = @import("protocol/stun/transaction.zig").TransactionId;
pub const stun_tx_from_rng = @import("protocol/stun/transaction.zig").from_rng;
pub const stun_tx_equals = @import("protocol/stun/transaction.zig").equals;

pub const version = "0.0.1";

pub fn active_feature_flags() FeatureFlags {
    return FeatureFlags.from_build_options();
}

pub fn build_banner() []const u8 {
    return "libdice: bootstrap build is healthy";
}

test "build_banner returns expected string" {
    try std.testing.expectEqualStrings("libdice: bootstrap build is healthy", build_banner());
}

test "exports are reachable" {
    var flags = FeatureFlags{};
    try std.testing.expect(flags.ice_udp);
    flags.ice_udp = false;
    try std.testing.expect(!flags.ice_udp);
    try std.testing.expectEqualStrings("0.0.1", version);
}

test "active feature flags are accessible" {
    const flags = active_feature_flags();
    try std.testing.expect(flags.ice_udp);
}

test "timer wheel export is reachable" {
    var wheel = TimerWheel.init(std.testing.allocator);
    defer wheel.deinit();

    try std.testing.expectEqual(@as(usize, 0), wheel.pending_count());
}

test "stun header export is reachable" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    const header = StunHeader.init(0x0001, 0, tx_id);
    try std.testing.expectEqual(@as(u16, 0x0001), header.message_type);
}

test "stun attr header export is reachable" {
    const attr = StunAttrHeader.init(0x0006, 5);
    try std.testing.expectEqual(@as(u16, 0x0006), attr.attr_type);
}

test "stun parser export is reachable" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    var packet: [20]u8 = undefined;
    const header = StunHeader.init(0x0001, 0, tx_id);
    _ = try header.encode(&packet);

    const view = try parse_stun_message(&packet);
    try std.testing.expectEqual(@as(usize, 0), view.body.len);
}

test "stun builder export is reachable" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    var packet: [32]u8 = undefined;

    var builder = try StunMessageBuilder.init(&packet, 0x0001, tx_id);
    const bytes = try builder.finish();
    try std.testing.expectEqual(@as(usize, 20), bytes.len);
}

test "stun transaction exports are reachable" {
    var prng = std.Random.DefaultPrng.init(1234);
    const random = prng.random();

    const tx = stun_tx_from_rng(random);
    try std.testing.expect(stun_tx_equals(tx, tx));
}
