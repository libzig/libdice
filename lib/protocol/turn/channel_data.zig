const std = @import("std");

pub const channel_min: u16 = 0x4000;
pub const channel_max: u16 = 0x7FFF;

pub const ChannelDataError = error{
    InvalidChannelNumber,
    BufferTooSmall,
    TruncatedFrame,
};

pub const FrameView = struct {
    channel_number: u16,
    payload: []const u8,
    total_size: usize,
};

fn padded_len(len: usize) usize {
    return (len + 3) & ~@as(usize, 3);
}

pub fn encode_frame(out: []u8, channel_number: u16, payload: []const u8, pad_to_4: bool) ChannelDataError![]const u8 {
    if (channel_number < channel_min or channel_number > channel_max) return error.InvalidChannelNumber;

    const payload_size = if (pad_to_4) padded_len(payload.len) else payload.len;
    const total = 4 + payload_size;
    if (out.len < total) return error.BufferTooSmall;

    std.mem.writeInt(u16, out[0..2], channel_number, .big);
    std.mem.writeInt(u16, out[2..4], @intCast(payload.len), .big);
    @memcpy(out[4 .. 4 + payload.len], payload);

    if (pad_to_4 and payload_size != payload.len) {
        @memset(out[4 + payload.len .. total], 0);
    }

    return out[0..total];
}

pub fn decode_frame(input: []const u8, padded_input: bool) ChannelDataError!FrameView {
    if (input.len < 4) return error.TruncatedFrame;

    const channel_number = std.mem.readInt(u16, input[0..2], .big);
    if (channel_number < channel_min or channel_number > channel_max) return error.InvalidChannelNumber;

    const payload_len = @as(usize, std.mem.readInt(u16, input[2..4], .big));
    const payload_size = if (padded_input) padded_len(payload_len) else payload_len;
    const total = 4 + payload_size;
    if (input.len < total) return error.TruncatedFrame;

    return .{
        .channel_number = channel_number,
        .payload = input[4 .. 4 + payload_len],
        .total_size = total,
    };
}

test "channel data frame roundtrip without padding" {
    var buf: [64]u8 = undefined;
    const payload = "hello";

    const encoded = try encode_frame(&buf, 0x4001, payload, false);
    try std.testing.expectEqual(@as(usize, 9), encoded.len);

    const frame = try decode_frame(encoded, false);
    try std.testing.expectEqual(@as(u16, 0x4001), frame.channel_number);
    try std.testing.expectEqualStrings("hello", frame.payload);
    try std.testing.expectEqual(@as(usize, 9), frame.total_size);
}

test "channel data frame roundtrip with tcp-style padding" {
    var buf: [64]u8 = undefined;
    const payload = "abc";

    const encoded = try encode_frame(&buf, 0x4002, payload, true);
    try std.testing.expectEqual(@as(usize, 8), encoded.len);
    try std.testing.expectEqual(@as(u8, 0), encoded[7]);

    const frame = try decode_frame(encoded, true);
    try std.testing.expectEqual(@as(u16, 0x4002), frame.channel_number);
    try std.testing.expectEqualStrings("abc", frame.payload);
    try std.testing.expectEqual(@as(usize, 8), frame.total_size);
}

test "channel data rejects invalid channel range" {
    var buf: [16]u8 = undefined;
    try std.testing.expectError(error.InvalidChannelNumber, encode_frame(&buf, 0x3FFF, "x", false));
}

test "channel data decode rejects truncated frame" {
    const truncated = [_]u8{ 0x40, 0x01, 0x00, 0x04, 0x61, 0x62 };
    try std.testing.expectError(error.TruncatedFrame, decode_frame(&truncated, false));
}
