const std = @import("std");

pub const attr_header_size: usize = 4;

pub const AttrError = error{
    BufferTooShort,
    InvalidLength,
};

pub const AttrHeader = struct {
    attr_type: u16,
    attr_length: u16,

    pub fn init(attr_type: u16, attr_length: u16) AttrHeader {
        return .{
            .attr_type = attr_type,
            .attr_length = attr_length,
        };
    }

    pub fn padded_value_length(self: AttrHeader) usize {
        const length = @as(usize, self.attr_length);
        return (length + 3) & ~@as(usize, 3);
    }

    pub fn encoded_size(self: AttrHeader) usize {
        return attr_header_size + self.padded_value_length();
    }

    pub fn encode(self: AttrHeader, out: []u8) AttrError![]const u8 {
        if (out.len < attr_header_size) return AttrError.BufferTooShort;

        std.mem.writeInt(u16, out[0..2], self.attr_type, .big);
        std.mem.writeInt(u16, out[2..4], self.attr_length, .big);
        return out[0..attr_header_size];
    }

    pub fn decode(input: []const u8) AttrError!AttrHeader {
        if (input.len < attr_header_size) return AttrError.BufferTooShort;

        const attr_type = std.mem.readInt(u16, input[0..2], .big);
        const attr_length = std.mem.readInt(u16, input[2..4], .big);

        return .{
            .attr_type = attr_type,
            .attr_length = attr_length,
        };
    }
};

pub fn encode_attr(attr_type: u16, value: []const u8, out: []u8) AttrError![]const u8 {
    const header = AttrHeader.init(attr_type, @intCast(value.len));
    const total = header.encoded_size();
    if (out.len < total) return AttrError.BufferTooShort;

    _ = try header.encode(out[0..attr_header_size]);
    @memcpy(out[attr_header_size .. attr_header_size + value.len], value);

    const padding = header.padded_value_length() - value.len;
    if (padding > 0) {
        @memset(out[attr_header_size + value.len .. total], 0);
    }

    return out[0..total];
}

pub fn decode_attr_view(input: []const u8) AttrError!struct {
    header: AttrHeader,
    value: []const u8,
    total_size: usize,
} {
    const header = try AttrHeader.decode(input);
    const value_len = @as(usize, header.attr_length);
    const total = attr_header_size + ((value_len + 3) & ~@as(usize, 3));
    if (input.len < total) return AttrError.BufferTooShort;

    return .{
        .header = header,
        .value = input[attr_header_size .. attr_header_size + value_len],
        .total_size = total,
    };
}

test "attribute header roundtrip" {
    const original = AttrHeader.init(0x0006, 13);

    var bytes: [attr_header_size]u8 = undefined;
    _ = try original.encode(&bytes);

    const parsed = try AttrHeader.decode(&bytes);
    try std.testing.expectEqual(original.attr_type, parsed.attr_type);
    try std.testing.expectEqual(original.attr_length, parsed.attr_length);
    try std.testing.expectEqual(@as(usize, 16), parsed.padded_value_length());
}

test "attribute encode adds 4-byte padding" {
    const value = "abc";
    var bytes: [8]u8 = undefined;

    const encoded = try encode_attr(0x8022, value, &bytes);
    try std.testing.expectEqual(@as(usize, 8), encoded.len);
    try std.testing.expectEqual(@as(u8, 0), encoded[7]);

    const view = try decode_attr_view(encoded);
    try std.testing.expectEqual(@as(u16, 0x8022), view.header.attr_type);
    try std.testing.expectEqualStrings("abc", view.value);
}

test "decode_attr_view rejects truncated payload" {
    var bytes = [_]u8{
        0x80, 0x22,
        0x00, 0x04,
        0x61, 0x62,
    };

    try std.testing.expectError(AttrError.BufferTooShort, decode_attr_view(&bytes));
}
