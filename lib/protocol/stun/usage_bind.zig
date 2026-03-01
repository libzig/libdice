const std = @import("std");
const message = @import("message.zig");
const parser = @import("parser.zig");
const encoder = @import("encoder.zig");
const integrity = @import("integrity.zig");
const address_attrs = @import("address_attrs.zig");

pub const binding_request_type: u16 = 0x0001;
pub const binding_response_type: u16 = 0x0101;
pub const binding_error_response_type: u16 = 0x0111;

pub const username_attr_type: u16 = 0x0006;
pub const software_attr_type: u16 = 0x8022;

pub const BuildError = encoder.EncodeError;

pub const ParseBindingResponseError = parser.ParserError || integrity.IntegrityError || address_attrs.AddressAttrError || error{
    NotBindingResponse,
    InvalidIntegrity,
};

pub const BindingSuccessResponseOptions = struct {
    xor_mapped_address: ?address_attrs.StunAddress = null,
    software: ?[]const u8 = null,
    integrity_key: ?[]const u8 = null,
    include_fingerprint: bool = false,
};

pub const BindingSuccessResponseInfo = struct {
    transaction_id: [12]u8,
    xor_mapped_address: ?address_attrs.StunAddress,
    software: ?[]const u8,
    has_message_integrity: bool,
    has_fingerprint: bool,
};

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

pub fn build_binding_success_response(buffer: []u8, transaction_id: [12]u8, options: BindingSuccessResponseOptions) BuildError![]const u8 {
    var builder = try encoder.Builder.init(buffer, binding_response_type, transaction_id);

    if (options.xor_mapped_address) |value| {
        try address_attrs.add_xor_mapped_address(&builder, value, transaction_id);
    }

    if (options.software) |value| {
        try builder.add_attr(software_attr_type, value);
    }

    if (options.integrity_key) |key| {
        try integrity.add_message_integrity_attr(&builder, key);
    }

    if (options.include_fingerprint) {
        try integrity.add_fingerprint_attr(&builder);
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

fn read_software(view: parser.MessageView) parser.ParserError!?[]const u8 {
    var it = view.attr_iterator();
    while (try it.next()) |attr| {
        if (attr.header.attr_type == software_attr_type) return attr.value;
    }
    return null;
}

pub fn parse_binding_response(view: parser.MessageView, integrity_key: ?[]const u8) ParseBindingResponseError!BindingSuccessResponseInfo {
    if (!is_binding_response(view)) return error.NotBindingResponse;

    const has_message_integrity = try integrity.has_attr(view, integrity.message_integrity_type);
    const has_fingerprint = try integrity.has_attr(view, integrity.fingerprint_type);

    if (integrity_key) |key| {
        if (has_message_integrity and !(try integrity.verify_embedded_message_integrity(view, key))) return error.InvalidIntegrity;
        if (has_fingerprint and !(try integrity.verify_embedded_fingerprint(view))) return error.InvalidIntegrity;
    }

    const maybe_xor_attr = try address_attrs.find_xor_mapped_address(view);
    const xor_mapped_address = if (maybe_xor_attr) |attr|
        try address_attrs.decode_xor_mapped_address(attr, view.header.transaction_id)
    else
        null;

    return .{
        .transaction_id = view.header.transaction_id,
        .xor_mapped_address = xor_mapped_address,
        .software = try read_software(view),
        .has_message_integrity = has_message_integrity,
        .has_fingerprint = has_fingerprint,
    };
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
    const parsed = try parse_binding_response(response_view, null);
    try std.testing.expectEqualSlices(u8, &tx_id, &parsed.transaction_id);

    var request_packet: [message.header_size]u8 = undefined;
    const bad_header = message.Header.init(binding_request_type, 0, tx_id);
    _ = try bad_header.encode(&request_packet);

    const request_view = try parser.parse_message(&request_packet);
    try std.testing.expectError(error.NotBindingResponse, parse_binding_response(request_view, null));
}

test "build and parse binding success response with xor-mapped-address" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    const mapped: address_attrs.StunAddress = .{ .ipv4 = .{ .port = 5000, .ip = .{ 203, 0, 113, 7 } } };

    var packet: [256]u8 = undefined;
    const bytes = try build_binding_success_response(&packet, tx_id, .{
        .xor_mapped_address = mapped,
        .software = "libdice-bind",
        .integrity_key = "bind-key",
        .include_fingerprint = true,
    });

    const view = try parser.parse_message(bytes);
    const parsed = try parse_binding_response(view, "bind-key");
    try std.testing.expectEqualSlices(u8, &tx_id, &parsed.transaction_id);
    try std.testing.expectEqualDeep(mapped, parsed.xor_mapped_address.?);
    try std.testing.expectEqualStrings("libdice-bind", parsed.software.?);
    try std.testing.expect(parsed.has_message_integrity);
    try std.testing.expect(parsed.has_fingerprint);
}

test "binding response parser rejects invalid integrity" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    var packet: [128]u8 = undefined;

    const bytes = try build_binding_success_response(&packet, tx_id, .{
        .integrity_key = "expected-key",
    });

    const view = try parser.parse_message(bytes);
    try std.testing.expectError(error.InvalidIntegrity, parse_binding_response(view, "wrong-key"));
}
