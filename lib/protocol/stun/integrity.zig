const std = @import("std");
const hmac_sha1 = @import("../../crypto/hmac_sha1.zig");

pub const message_integrity_type: u16 = 0x0008;
pub const message_integrity_size: usize = hmac_sha1.mac_length;

pub const fingerprint_type: u16 = 0x8028;
pub const fingerprint_size: usize = 4;
pub const fingerprint_xor: u32 = 0x5354554e;

pub fn compute_message_integrity(message_bytes: []const u8, key: []const u8) hmac_sha1.Mac {
    return hmac_sha1.compute(key, message_bytes);
}

pub fn verify_message_integrity(expected: hmac_sha1.Mac, message_bytes: []const u8, key: []const u8) bool {
    return hmac_sha1.verify(expected, key, message_bytes);
}

pub fn write_message_integrity(out: []u8, message_bytes: []const u8, key: []const u8) error{BufferTooSmall}!void {
    if (out.len < message_integrity_size) return error.BufferTooSmall;
    const mac = compute_message_integrity(message_bytes, key);
    @memcpy(out[0..message_integrity_size], &mac);
}

pub fn compute_fingerprint(message_bytes: []const u8) u32 {
    return std.hash.Crc32.hash(message_bytes) ^ fingerprint_xor;
}

pub fn write_fingerprint_be(out: []u8, message_bytes: []const u8) error{BufferTooSmall}!void {
    if (out.len < fingerprint_size) return error.BufferTooSmall;
    std.mem.writeInt(u32, out[0..4], compute_fingerprint(message_bytes), .big);
}

pub fn read_fingerprint_be(in: []const u8) error{BufferTooSmall}!u32 {
    if (in.len < fingerprint_size) return error.BufferTooSmall;
    return std.mem.readInt(u32, in[0..4], .big);
}

test "message integrity known vector" {
    const mac = compute_message_integrity("The quick brown fox jumps over the lazy dog", "key");
    const expected = [_]u8{
        0xde, 0x7c, 0x9b, 0x85, 0xb8, 0xb7, 0x8a, 0xa6, 0xbc, 0x8a,
        0x7a, 0x36, 0xf7, 0x0a, 0x90, 0x70, 0x1c, 0x9d, 0xb4, 0xd9,
    };
    try std.testing.expectEqualSlices(u8, &expected, &mac);
    try std.testing.expect(verify_message_integrity(mac, "The quick brown fox jumps over the lazy dog", "key"));
}

test "fingerprint known vectors" {
    try std.testing.expectEqual(@as(u32, 0x5354554e), compute_fingerprint(""));
    try std.testing.expectEqual(@as(u32, 0x6670148c), compute_fingerprint("abc"));
}

test "fingerprint read write big endian" {
    var bytes: [4]u8 = undefined;
    try write_fingerprint_be(&bytes, "abc");
    const parsed = try read_fingerprint_be(&bytes);
    try std.testing.expectEqual(@as(u32, 0x6670148c), parsed);
}

test "integrity writers reject short buffers" {
    var mac_buf: [19]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, write_message_integrity(&mac_buf, "data", "key"));

    var fp_buf: [3]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, write_fingerprint_be(&fp_buf, "data"));
    try std.testing.expectError(error.BufferTooSmall, read_fingerprint_be(&fp_buf));
}
