const std = @import("std");
const message = @import("message.zig");
const parser = @import("parser.zig");
const encoder = @import("encoder.zig");

pub const binding_request_type: u16 = 0x0001;
pub const binding_response_type: u16 = 0x0101;
pub const binding_error_response_type: u16 = 0x0111;

pub const username_attr_type: u16 = 0x0006;
pub const software_attr_type: u16 = 0x8022;

pub const BuildError = encoder.EncodeError;

pub fn build_binding_request(buffer: []u8, transaction_id: [12]u8, username: ?[]const u8, software: ?[]const u8) BuildError![]const u8 {
    var builder = try encoder.Builder.init(buffer, binding_request_type, transaction_id);

    if (username) |value| {
        try builder.add_attr(username_attr_type, value);
    }

    if (software) |value| {
        try builder.add_attr(software_attr_type, value);
    }

    return builder.finish();
}

pub fn is_binding_request(view: parser.MessageView) bool {
    return view.header.message_type == binding_request_type;
}

pub fn is_binding_response(view: parser.MessageView) bool {
    return view.header.message_type == binding_response_type;
}

pub fn is_binding_error_response(view: parser.MessageView) bool {
    return view.header.message_type == binding_error_response_type;
}

pub fn parse_binding_response(view: parser.MessageView) error{NotBindingResponse}!struct { transaction_id: [12]u8 } {
    if (!is_binding_response(view)) return error.NotBindingResponse;
    return .{ .transaction_id = view.header.transaction_id };
}

test "build bare binding request" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    var packet: [message.header_size]u8 = undefined;

    const bytes = try build_binding_request(&packet, tx_id, null, null);
    const parsed = try parser.parse_message(bytes);

    try std.testing.expect(is_binding_request(parsed));
    try std.testing.expectEqual(@as(usize, 0), parsed.body.len);
}

test "build binding request with username and software" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    var packet: [128]u8 = undefined;

    const bytes = try build_binding_request(&packet, tx_id, "ufrag", "libdice");
    const parsed = try parser.parse_message(bytes);

    try std.testing.expect(is_binding_request(parsed));

    var it = parsed.attr_iterator();
    const a = (try it.next()).?;
    try std.testing.expectEqual(username_attr_type, a.header.attr_type);
    try std.testing.expectEqualStrings("ufrag", a.value);

    const b = (try it.next()).?;
    try std.testing.expectEqual(software_attr_type, b.header.attr_type);
    try std.testing.expectEqualStrings("libdice", b.value);
}

test "parse binding response validates message type" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };

    var response_packet: [message.header_size]u8 = undefined;
    const ok_header = message.Header.init(binding_response_type, 0, tx_id);
    _ = try ok_header.encode(&response_packet);

    const response_view = try parser.parse_message(&response_packet);
    const parsed = try parse_binding_response(response_view);
    try std.testing.expectEqualSlices(u8, &tx_id, &parsed.transaction_id);

    var request_packet: [message.header_size]u8 = undefined;
    const bad_header = message.Header.init(binding_request_type, 0, tx_id);
    _ = try bad_header.encode(&request_packet);

    const request_view = try parser.parse_message(&request_packet);
    try std.testing.expectError(error.NotBindingResponse, parse_binding_response(request_view));
}
