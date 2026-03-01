const std = @import("std");
const message = @import("message.zig");

pub const TransactionId = [12]u8;

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
