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
pub const stun_build_binding_request = @import("protocol/stun/usage_bind.zig").build_binding_request;
pub const stun_is_binding_request = @import("protocol/stun/usage_bind.zig").is_binding_request;
pub const stun_is_binding_response = @import("protocol/stun/usage_bind.zig").is_binding_response;
pub const stun_message_integrity_type = @import("protocol/stun/integrity.zig").message_integrity_type;
pub const stun_fingerprint_type = @import("protocol/stun/integrity.zig").fingerprint_type;
pub const stun_compute_message_integrity = @import("protocol/stun/integrity.zig").compute_message_integrity;
pub const stun_verify_message_integrity = @import("protocol/stun/integrity.zig").verify_message_integrity;
pub const stun_compute_fingerprint = @import("protocol/stun/integrity.zig").compute_fingerprint;
pub const HmacSha1Mac = @import("crypto/hmac_sha1.zig").Mac;
pub const hmac_sha1_compute = @import("crypto/hmac_sha1.zig").compute;
pub const hmac_sha1_verify = @import("crypto/hmac_sha1.zig").verify;
pub const Md5Digest = @import("crypto/md5.zig").Digest;
pub const md5_digest = @import("crypto/md5.zig").digest;

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

test "crypto exports are reachable" {
    const mac = hmac_sha1_compute("key", "message");
    try std.testing.expect(hmac_sha1_verify(mac, "key", "message"));

    const digest = md5_digest("message");
    try std.testing.expectEqual(@as(usize, 16), digest.len);
}

test "stun integrity exports are reachable" {
    const mac = stun_compute_message_integrity("payload", "key");
    try std.testing.expect(stun_verify_message_integrity(mac, "payload", "key"));

    const fp = stun_compute_fingerprint("payload");
    try std.testing.expect(fp != 0);
    try std.testing.expectEqual(@as(u16, 0x0008), stun_message_integrity_type);
    try std.testing.expectEqual(@as(u16, 0x8028), stun_fingerprint_type);
}

test "stun bind usage exports are reachable" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    var packet: [64]u8 = undefined;

    const bytes = try stun_build_binding_request(&packet, tx_id, null, null);
    const view = try parse_stun_message(bytes);
    try std.testing.expect(stun_is_binding_request(view));
    try std.testing.expect(!stun_is_binding_response(view));
}
