const std = @import("std");

pub const header_size: usize = 20;
pub const magic_cookie: u32 = 0x2112A442;

pub const ParseError = error{
    BufferTooShort,
    InvalidCookie,
    InvalidLength,
};

pub const Header = struct {
    message_type: u16,
    message_length: u16,
    transaction_id: [12]u8,

    pub fn init(message_type: u16, message_length: u16, transaction_id: [12]u8) Header {
        return .{
            .message_type = message_type,
            .message_length = message_length,
            .transaction_id = transaction_id,
        };
    }

    pub fn encode(self: Header, out: []u8) ParseError![]const u8 {
        if (out.len < header_size) return ParseError.BufferTooShort;
        if ((self.message_length % 4) != 0) return ParseError.InvalidLength;

        std.mem.writeInt(u16, out[0..2], self.message_type, .big);
        std.mem.writeInt(u16, out[2..4], self.message_length, .big);
        std.mem.writeInt(u32, out[4..8], magic_cookie, .big);
        @memcpy(out[8..20], &self.transaction_id);

        return out[0..header_size];
    }

    pub fn decode(input: []const u8) ParseError!Header {
        if (input.len < header_size) return ParseError.BufferTooShort;

        const cookie = std.mem.readInt(u32, input[4..8], .big);
        if (cookie != magic_cookie) return ParseError.InvalidCookie;

        const length = std.mem.readInt(u16, input[2..4], .big);
        if ((length % 4) != 0) return ParseError.InvalidLength;

        var tx_id: [12]u8 = undefined;
        @memcpy(&tx_id, input[8..20]);

        return .{
            .message_type = std.mem.readInt(u16, input[0..2], .big),
            .message_length = length,
            .transaction_id = tx_id,
        };
    }
};

test "header encodes and decodes roundtrip" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    const original = Header.init(0x0001, 0, tx_id);

    var buffer: [header_size]u8 = undefined;
    const encoded = try original.encode(&buffer);
    try std.testing.expectEqual(@as(usize, header_size), encoded.len);

    const parsed = try Header.decode(encoded);
    try std.testing.expectEqual(original.message_type, parsed.message_type);
    try std.testing.expectEqual(original.message_length, parsed.message_length);
    try std.testing.expectEqualSlices(u8, &original.transaction_id, &parsed.transaction_id);
}

test "decode rejects invalid cookie" {
    var packet = [_]u8{
        0x00, 0x01,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0,    1,
        2,    3,
        4,    5,
        6,    7,
        8,    9,
        10,   11,
    };

    try std.testing.expectError(ParseError.InvalidCookie, Header.decode(&packet));
}

test "decode rejects invalid body length alignment" {
    var packet = [_]u8{
        0x00, 0x01,
        0x00, 0x03,
        0x21, 0x12,
        0xA4, 0x42,
        0,    1,
        2,    3,
        4,    5,
        6,    7,
        8,    9,
        10,   11,
    };

    try std.testing.expectError(ParseError.InvalidLength, Header.decode(&packet));
}
