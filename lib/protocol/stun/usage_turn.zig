const std = @import("std");
const encoder = @import("encoder.zig");
const parser = @import("parser.zig");

pub const allocate_request_type: u16 = 0x0003;
pub const allocate_success_response_type: u16 = 0x0103;
pub const allocate_error_response_type: u16 = 0x0113;

pub const refresh_request_type: u16 = 0x0004;
pub const refresh_success_response_type: u16 = 0x0104;
pub const refresh_error_response_type: u16 = 0x0114;

pub const username_attr_type: u16 = 0x0006;
pub const realm_attr_type: u16 = 0x0014;
pub const nonce_attr_type: u16 = 0x0015;
pub const requested_transport_attr_type: u16 = 0x0019;
pub const lifetime_attr_type: u16 = 0x000D;
pub const software_attr_type: u16 = 0x8022;
pub const error_code_attr_type: u16 = 0x0009;

pub const requested_transport_udp: u8 = 17;

pub const TurnError = parser.ParserError || error{
    InvalidAttrLength,
    InvalidErrorCode,
};

pub const AllocateRequestOptions = struct {
    username: ?[]const u8 = null,
    realm: ?[]const u8 = null,
    nonce: ?[]const u8 = null,
    software: ?[]const u8 = null,
    lifetime_seconds: ?u32 = null,
    requested_transport: u8 = requested_transport_udp,
};

pub fn build_allocate_request(buffer: []u8, transaction_id: [12]u8, options: AllocateRequestOptions) encoder.EncodeError![]const u8 {
    var builder = try encoder.Builder.init(buffer, allocate_request_type, transaction_id);

    var requested_transport: [4]u8 = .{ options.requested_transport, 0, 0, 0 };
    try builder.add_attr(requested_transport_attr_type, &requested_transport);

    if (options.username) |value| {
        try builder.add_attr(username_attr_type, value);
    }

    if (options.realm) |value| {
        try builder.add_attr(realm_attr_type, value);
    }

    if (options.nonce) |value| {
        try builder.add_attr(nonce_attr_type, value);
    }

    if (options.software) |value| {
        try builder.add_attr(software_attr_type, value);
    }

    if (options.lifetime_seconds) |lifetime| {
        var lifetime_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &lifetime_buf, lifetime, .big);
        try builder.add_attr(lifetime_attr_type, &lifetime_buf);
    }

    return builder.finish();
}

pub fn build_refresh_request(buffer: []u8, transaction_id: [12]u8, lifetime_seconds: ?u32, nonce: ?[]const u8, realm: ?[]const u8, username: ?[]const u8) encoder.EncodeError![]const u8 {
    var builder = try encoder.Builder.init(buffer, refresh_request_type, transaction_id);

    if (lifetime_seconds) |lifetime| {
        var lifetime_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &lifetime_buf, lifetime, .big);
        try builder.add_attr(lifetime_attr_type, &lifetime_buf);
    }

    if (nonce) |value| {
        try builder.add_attr(nonce_attr_type, value);
    }

    if (realm) |value| {
        try builder.add_attr(realm_attr_type, value);
    }

    if (username) |value| {
        try builder.add_attr(username_attr_type, value);
    }

    return builder.finish();
}

pub fn is_allocate_success_response(view: parser.MessageView) bool {
    return view.header.message_type == allocate_success_response_type;
}

pub fn is_allocate_error_response(view: parser.MessageView) bool {
    return view.header.message_type == allocate_error_response_type;
}

pub fn is_refresh_success_response(view: parser.MessageView) bool {
    return view.header.message_type == refresh_success_response_type;
}

pub fn read_lifetime_seconds(view: parser.MessageView) TurnError!?u32 {
    var it = view.attr_iterator();
    while (try it.next()) |attr| {
        if (attr.header.attr_type == lifetime_attr_type) {
            if (attr.value.len != 4) return error.InvalidAttrLength;
            return std.mem.readInt(u32, attr.value[0..4], .big);
        }
    }

    return null;
}

pub fn read_requested_transport(view: parser.MessageView) TurnError!?u8 {
    var it = view.attr_iterator();
    while (try it.next()) |attr| {
        if (attr.header.attr_type == requested_transport_attr_type) {
            if (attr.value.len != 4) return error.InvalidAttrLength;
            return attr.value[0];
        }
    }

    return null;
}

pub fn read_error_code(view: parser.MessageView) TurnError!?u16 {
    var it = view.attr_iterator();
    while (try it.next()) |attr| {
        if (attr.header.attr_type != error_code_attr_type) continue;
        if (attr.value.len < 4) return error.InvalidAttrLength;

        const class = attr.value[2] & 0x07;
        const number = attr.value[3];
        if (class == 0 or class > 6 or number > 99) return error.InvalidErrorCode;

        return @as(u16, class) * 100 + number;
    }

    return null;
}

test "build allocate request with common TURN attributes" {
    const message = @import("message.zig");
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    var packet: [256]u8 = undefined;

    const bytes = try build_allocate_request(&packet, tx_id, .{
        .username = "user",
        .realm = "example.org",
        .nonce = "nonce-token",
        .software = "libdice",
        .lifetime_seconds = 600,
        .requested_transport = requested_transport_udp,
    });

    const view = try parser.parse_message(bytes);
    try std.testing.expectEqual(@as(u16, allocate_request_type), view.header.message_type);
    try std.testing.expectEqual(@as(usize, bytes.len - message.header_size), view.body.len);

    const transport = (try read_requested_transport(view)).?;
    try std.testing.expectEqual(@as(u8, requested_transport_udp), transport);

    const lifetime = (try read_lifetime_seconds(view)).?;
    try std.testing.expectEqual(@as(u32, 600), lifetime);
}

test "build refresh request with optional attributes" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    var packet: [128]u8 = undefined;

    const bytes = try build_refresh_request(&packet, tx_id, 0, "nonce-token", "example.org", "user");
    const view = try parser.parse_message(bytes);

    try std.testing.expectEqual(@as(u16, refresh_request_type), view.header.message_type);
    try std.testing.expectEqual(@as(u32, 0), (try read_lifetime_seconds(view)).?);
}

test "read error code from TURN error response" {
    const message = @import("message.zig");
    const attrs = @import("attrs.zig");

    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    var packet: [message.header_size + 8]u8 = undefined;

    const header = message.Header.init(allocate_error_response_type, 8, tx_id);
    _ = try header.encode(packet[0..message.header_size]);

    const err_value = [_]u8{ 0x00, 0x00, 0x04, 0x01 };
    _ = try attrs.encode_attr(error_code_attr_type, &err_value, packet[message.header_size..]);

    const view = try parser.parse_message(&packet);
    try std.testing.expect(is_allocate_error_response(view));
    try std.testing.expectEqual(@as(u16, 401), (try read_error_code(view)).?);
}

test "readers validate malformed TURN attribute lengths" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    var packet: [64]u8 = undefined;

    var builder = try encoder.Builder.init(&packet, allocate_request_type, tx_id);
    try builder.add_attr(requested_transport_attr_type, "ab");
    const bytes = try builder.finish();

    const view = try parser.parse_message(bytes);
    try std.testing.expectError(error.InvalidAttrLength, read_requested_transport(view));
}
