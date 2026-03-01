const std = @import("std");
const message = @import("message.zig");
const attrs = @import("attrs.zig");
const parser = @import("parser.zig");

pub const EncodeError = error{
    BufferTooSmall,
};

pub const Builder = struct {
    buffer: []u8,
    header: message.Header,
    write_index: usize,

    pub fn init(buffer: []u8, message_type: u16, transaction_id: [12]u8) EncodeError!Builder {
        if (buffer.len < message.header_size) return EncodeError.BufferTooSmall;

        return .{
            .buffer = buffer,
            .header = message.Header.init(message_type, 0, transaction_id),
            .write_index = message.header_size,
        };
    }

    pub fn add_attr(self: *Builder, attr_type: u16, value: []const u8) EncodeError!void {
        const available = self.buffer[self.write_index..];
        const encoded = attrs.encode_attr(attr_type, value, available) catch return EncodeError.BufferTooSmall;
        self.write_index += encoded.len;

        const body_len = self.write_index - message.header_size;
        self.header.message_length = @intCast(body_len);
    }

    pub fn finish(self: *Builder) EncodeError![]const u8 {
        _ = self.header.encode(self.buffer[0..message.header_size]) catch return EncodeError.BufferTooSmall;
        return self.buffer[0..self.write_index];
    }
};

test "builder emits parseable message" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    var packet: [64]u8 = undefined;

    var builder = try Builder.init(&packet, 0x0001, tx_id);
    try builder.add_attr(0x0006, "ufrag");
    try builder.add_attr(0x0008, "password");

    const bytes = try builder.finish();
    const parsed = try parser.parse_message(bytes);

    try std.testing.expectEqual(@as(u16, 0x0001), parsed.header.message_type);
    try std.testing.expectEqual(@as(usize, bytes.len - message.header_size), parsed.body.len);

    var it = parsed.attr_iterator();
    const a = (try it.next()).?;
    try std.testing.expectEqual(@as(u16, 0x0006), a.header.attr_type);
    try std.testing.expectEqualStrings("ufrag", a.value);

    const b = (try it.next()).?;
    try std.testing.expectEqual(@as(u16, 0x0008), b.header.attr_type);
    try std.testing.expectEqualStrings("password", b.value);

    try std.testing.expectEqual(@as(?parser.AttrView, null), try it.next());
}

test "builder fails when packet buffer is too small" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    var packet: [24]u8 = undefined;

    var builder = try Builder.init(&packet, 0x0001, tx_id);
    try std.testing.expectError(EncodeError.BufferTooSmall, builder.add_attr(0x0006, "hello"));
}
