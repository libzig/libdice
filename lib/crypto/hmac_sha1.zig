const std = @import("std");

pub const mac_length = std.crypto.auth.hmac.HmacSha1.mac_length;
pub const Mac = [mac_length]u8;

pub fn compute(key: []const u8, msg: []const u8) Mac {
    var out: Mac = undefined;
    std.crypto.auth.hmac.HmacSha1.create(&out, msg, key);
    return out;
}

pub fn verify(expected: Mac, key: []const u8, msg: []const u8) bool {
    const actual = compute(key, msg);
    return std.crypto.timing_safe.eql(Mac, expected, actual);
}

test "hmac sha1 known vector" {
    const mac = compute("key", "The quick brown fox jumps over the lazy dog");
    const expected = [_]u8{
        0xde, 0x7c, 0x9b, 0x85, 0xb8, 0xb7, 0x8a, 0xa6, 0xbc, 0x8a,
        0x7a, 0x36, 0xf7, 0x0a, 0x90, 0x70, 0x1c, 0x9d, 0xb4, 0xd9,
    };
    try std.testing.expectEqualSlices(u8, &expected, &mac);
}

test "hmac sha1 verify returns true for matching input" {
    const expected = compute("k", "m");
    try std.testing.expect(verify(expected, "k", "m"));
    try std.testing.expect(!verify(expected, "k", "other"));
}
