const std = @import("std");
const message = @import("message.zig");
const attrs = @import("attrs.zig");

pub const ParserError = message.ParseError || attrs.AttrError || error{
    MessageTruncated,
};

pub const MessageView = struct {
    header: message.Header,
    raw: []const u8,
    body: []const u8,

    pub fn attr_iterator(self: MessageView) AttrIterator {
        return .{ .remaining = self.body };
    }
};

pub const AttrView = struct {
    header: attrs.AttrHeader,
    value: []const u8,
    total_size: usize,
};

pub const AttrIterator = struct {
    remaining: []const u8,

    pub fn next(self: *AttrIterator) ParserError!?AttrView {
        if (self.remaining.len == 0) return null;

        const view = try attrs.decode_attr_view(self.remaining);
        self.remaining = self.remaining[view.total_size..];

        return .{
            .header = view.header,
            .value = view.value,
            .total_size = view.total_size,
        };
    }
};

pub fn parse_message(input: []const u8) ParserError!MessageView {
    const header = try message.Header.decode(input);

    const body_len = @as(usize, header.message_length);
    const total_len = message.header_size + body_len;
    if (input.len < total_len) return error.MessageTruncated;

    return .{
        .header = header,
        .raw = input[0..total_len],
        .body = input[message.header_size..total_len],
    };
}

test "parse message with two attributes" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };

    var packet: [36]u8 = undefined;

    const header = message.Header.init(0x0001, 16, tx_id);
    _ = try header.encode(packet[0..message.header_size]);

    _ = try attrs.encode_attr(0x0006, "ab", packet[message.header_size .. message.header_size + 8]);
    _ = try attrs.encode_attr(0x0008, "cd", packet[message.header_size + 8 .. message.header_size + 16]);

    const view = try parse_message(&packet);
    try std.testing.expectEqual(@as(u16, 0x0001), view.header.message_type);

    var it = view.attr_iterator();
    const a = (try it.next()).?;
    try std.testing.expectEqual(@as(u16, 0x0006), a.header.attr_type);
    try std.testing.expectEqualStrings("ab", a.value);

    const b = (try it.next()).?;
    try std.testing.expectEqual(@as(u16, 0x0008), b.header.attr_type);
    try std.testing.expectEqualStrings("cd", b.value);

    try std.testing.expectEqual(@as(?AttrView, null), try it.next());
}

test "parse_message rejects truncated body" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    var packet: [message.header_size]u8 = undefined;

    const header = message.Header.init(0x0001, 4, tx_id);
    _ = try header.encode(&packet);

    try std.testing.expectError(error.MessageTruncated, parse_message(&packet));
}

test "iterator rejects truncated attribute" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };

    var packet: [24]u8 = undefined;
    const header = message.Header.init(0x0001, 4, tx_id);
    _ = try header.encode(packet[0..message.header_size]);

    // Body has only the attribute header. No value bytes are present.
    packet[20] = 0x00;
    packet[21] = 0x06;
    packet[22] = 0x00;
    packet[23] = 0x04;

    const view = try parse_message(&packet);
    var it = view.attr_iterator();
    try std.testing.expectError(attrs.AttrError.BufferTooShort, it.next());
}
