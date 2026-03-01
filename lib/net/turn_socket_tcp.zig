const std = @import("std");
const parser = @import("../protocol/stun/parser.zig");
const channel_data = @import("../protocol/turn/channel_data.zig");

pub const default_max_frame_size: u16 = 65535;

pub const TurnTcpPacket = union(enum) {
    stun: parser.MessageView,
    channel_data: channel_data.FrameView,
};

pub const TurnTcpFramerError = std.mem.Allocator.Error || parser.ParserError || channel_data.ChannelDataError || error{
    InvalidFrameLength,
    FrameTooLarge,
    OutputTooSmall,
};

pub fn encode_framed_payload(out: []u8, payload: []const u8) TurnTcpFramerError![]const u8 {
    if (payload.len == 0) return error.InvalidFrameLength;
    if (payload.len > default_max_frame_size) return error.FrameTooLarge;
    if (out.len < payload.len + 2) return error.OutputTooSmall;

    std.mem.writeInt(u16, out[0..2], @as(u16, @intCast(payload.len)), .big);
    @memcpy(out[2 .. 2 + payload.len], payload);
    return out[0 .. 2 + payload.len];
}

pub const TurnTcpFramer = struct {
    allocator: std.mem.Allocator,
    max_frame_size: u16,
    buffer: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) TurnTcpFramer {
        return init_with_max_frame_size(allocator, default_max_frame_size);
    }

    pub fn init_with_max_frame_size(allocator: std.mem.Allocator, max_frame_size: u16) TurnTcpFramer {
        return .{
            .allocator = allocator,
            .max_frame_size = max_frame_size,
            .buffer = .empty,
        };
    }

    pub fn deinit(self: *TurnTcpFramer) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn push(self: *TurnTcpFramer, bytes: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, bytes);
    }

    pub fn buffered_bytes(self: TurnTcpFramer) usize {
        return self.buffer.items.len;
    }

    pub fn pop_payload(self: *TurnTcpFramer, out: []u8) TurnTcpFramerError!?[]const u8 {
        if (self.buffer.items.len < 2) return null;

        const frame_len = std.mem.readInt(u16, self.buffer.items[0..2], .big);
        if (frame_len == 0) return error.InvalidFrameLength;
        if (frame_len > self.max_frame_size) return error.FrameTooLarge;

        const full_len = 2 + @as(usize, frame_len);
        if (self.buffer.items.len < full_len) return null;
        if (out.len < frame_len) return error.OutputTooSmall;

        @memcpy(out[0..frame_len], self.buffer.items[2..full_len]);
        self.consume_prefix(full_len);
        return out[0..frame_len];
    }

    pub fn pop_packet(self: *TurnTcpFramer, out: []u8) TurnTcpFramerError!?TurnTcpPacket {
        const payload = try self.pop_payload(out) orelse return null;
        if (payload.len < 4) return error.InvalidFrameLength;

        const is_channel = (payload[0] & 0b1100_0000) == 0b0100_0000;
        if (is_channel) {
            return .{ .channel_data = try channel_data.decode_frame(payload, false) };
        }

        return .{ .stun = try parser.parse_message(payload) };
    }

    fn consume_prefix(self: *TurnTcpFramer, n: usize) void {
        if (n >= self.buffer.items.len) {
            self.buffer.clearRetainingCapacity();
            return;
        }

        const remain = self.buffer.items.len - n;
        std.mem.copyForwards(u8, self.buffer.items[0..remain], self.buffer.items[n..]);
        self.buffer.items.len = remain;
    }
};

test "turn tcp framer reassembles fragmented stun frame" {
    var framed: [64]u8 = undefined;
    var payload: [20]u8 = undefined;
    const tx = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    const header = @import("../protocol/stun/message.zig").Header.init(0x0101, 0, tx);
    _ = try header.encode(&payload);
    const frame = try encode_framed_payload(&framed, &payload);

    var framer = TurnTcpFramer.init(std.testing.allocator);
    defer framer.deinit();
    try framer.push(frame[0..3]);

    var out: [64]u8 = undefined;
    try std.testing.expectEqual(@as(?TurnTcpPacket, null), try framer.pop_packet(&out));

    try framer.push(frame[3..]);
    const packet = (try framer.pop_packet(&out)).?;
    switch (packet) {
        .stun => |view| try std.testing.expectEqual(@as(u16, 0x0101), view.header.message_type),
        else => return error.UnexpectedPacketType,
    }
}

test "turn tcp framer decodes channel data frames" {
    var framed: [64]u8 = undefined;
    var channel: [32]u8 = undefined;
    const channel_bytes = try channel_data.encode_frame(&channel, 0x4001, "abc", false);
    const frame = try encode_framed_payload(&framed, channel_bytes);

    var framer = TurnTcpFramer.init(std.testing.allocator);
    defer framer.deinit();
    try framer.push(frame);

    var out: [64]u8 = undefined;
    const packet = (try framer.pop_packet(&out)).?;
    switch (packet) {
        .channel_data => |view| {
            try std.testing.expectEqual(@as(u16, 0x4001), view.channel_number);
            try std.testing.expectEqualStrings("abc", view.payload);
        },
        else => return error.UnexpectedPacketType,
    }
}

test "turn tcp framer handles multiple queued packets" {
    var framed_a: [64]u8 = undefined;
    var framed_b: [64]u8 = undefined;
    var payload_a: [20]u8 = undefined;
    var payload_b: [20]u8 = undefined;

    const tx_a = [_]u8{ 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    const tx_b = [_]u8{ 20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 };
    _ = try @import("../protocol/stun/message.zig").Header.init(0x0101, 0, tx_a).encode(&payload_a);
    _ = try @import("../protocol/stun/message.zig").Header.init(0x0101, 0, tx_b).encode(&payload_b);

    const frame_a = try encode_framed_payload(&framed_a, &payload_a);
    const frame_b = try encode_framed_payload(&framed_b, &payload_b);

    var framer = TurnTcpFramer.init(std.testing.allocator);
    defer framer.deinit();
    try framer.push(frame_a);
    try framer.push(frame_b);

    var out: [64]u8 = undefined;
    _ = (try framer.pop_packet(&out)).?;
    _ = (try framer.pop_packet(&out)).?;
    try std.testing.expectEqual(@as(usize, 0), framer.buffered_bytes());
}

test "turn tcp framer validates frame length and output size" {
    var framer = TurnTcpFramer.init(std.testing.allocator);
    defer framer.deinit();

    try framer.push(&[_]u8{ 0x00, 0x00 });
    var out: [8]u8 = undefined;
    try std.testing.expectError(error.InvalidFrameLength, framer.pop_packet(&out));

    var framed: [16]u8 = undefined;
    const frame = try encode_framed_payload(&framed, "toolong");
    var small: [4]u8 = undefined;
    var framer2 = TurnTcpFramer.init(std.testing.allocator);
    defer framer2.deinit();
    try framer2.push(frame);
    try std.testing.expectError(error.OutputTooSmall, framer2.pop_payload(&small));
}

test "turn tcp framer enforces maximum frame size" {
    var framer = TurnTcpFramer.init_with_max_frame_size(std.testing.allocator, 4);
    defer framer.deinit();
    try framer.push(&[_]u8{ 0x00, 0x05, 1, 2, 3, 4, 5 });

    var out: [8]u8 = undefined;
    try std.testing.expectError(error.FrameTooLarge, framer.pop_payload(&out));
}
