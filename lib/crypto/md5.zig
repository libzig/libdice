const std = @import("std");

pub const digest_length = std.crypto.hash.Md5.digest_length;
pub const Digest = [digest_length]u8;

pub fn digest(data: []const u8) Digest {
    var out: Digest = undefined;
    std.crypto.hash.Md5.hash(data, &out, .{});
    return out;
}

pub fn digest_hex(data: []const u8, out: []u8) error{BufferTooSmall}![]const u8 {
    if (out.len < digest_length * 2) return error.BufferTooSmall;

    const hash = digest(data);
    const alphabet = "0123456789abcdef";
    for (hash, 0..) |byte, idx| {
        out[idx * 2] = alphabet[(byte >> 4) & 0x0f];
        out[idx * 2 + 1] = alphabet[byte & 0x0f];
    }

    return out[0 .. digest_length * 2];
}

test "md5 known vectors" {
    var hex: [32]u8 = undefined;

    const empty_hex = try digest_hex("", &hex);
    try std.testing.expectEqualStrings("d41d8cd98f00b204e9800998ecf8427e", empty_hex);

    const fox_hex = try digest_hex("The quick brown fox jumps over the lazy dog", &hex);
    try std.testing.expectEqualStrings("9e107d9d372bb6826bd81d3542a419d6", fox_hex);
}

test "md5 hex rejects short output buffer" {
    var hex: [31]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, digest_hex("abc", &hex));
}
