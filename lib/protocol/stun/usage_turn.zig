const std = @import("std");
const encoder = @import("encoder.zig");
const parser = @import("parser.zig");
const integrity = @import("integrity.zig");
const address_attrs = @import("address_attrs.zig");

pub const allocate_request_type: u16 = 0x0003;
pub const allocate_success_response_type: u16 = 0x0103;
pub const allocate_error_response_type: u16 = 0x0113;

pub const refresh_request_type: u16 = 0x0004;
pub const refresh_success_response_type: u16 = 0x0104;
pub const refresh_error_response_type: u16 = 0x0114;

pub const create_permission_request_type: u16 = 0x0008;
pub const create_permission_success_response_type: u16 = 0x0108;
pub const create_permission_error_response_type: u16 = 0x0118;

pub const channel_bind_request_type: u16 = 0x0009;
pub const channel_bind_success_response_type: u16 = 0x0109;
pub const channel_bind_error_response_type: u16 = 0x0119;
pub const send_indication_type: u16 = 0x0016;
pub const data_indication_type: u16 = 0x0017;

pub const username_attr_type: u16 = 0x0006;
pub const realm_attr_type: u16 = 0x0014;
pub const nonce_attr_type: u16 = 0x0015;
pub const requested_transport_attr_type: u16 = 0x0019;
pub const lifetime_attr_type: u16 = 0x000D;
pub const software_attr_type: u16 = 0x8022;
pub const error_code_attr_type: u16 = 0x0009;
pub const channel_number_attr_type: u16 = 0x000C;
pub const data_attr_type: u16 = 0x0013;

pub const requested_transport_udp: u8 = 17;

pub const TurnError = parser.ParserError || integrity.IntegrityError || address_attrs.AddressAttrError || error{
    InvalidAttrLength,
    InvalidErrorCode,
    NotAllocateSuccessResponse,
    NotRefreshSuccessResponse,
    NotDataIndication,
    InvalidIntegrity,
};

pub const TurnBuildError = encoder.EncodeError || error{
    NoPeerAddress,
};

pub const AllocateRequestOptions = struct {
    username: ?[]const u8 = null,
    realm: ?[]const u8 = null,
    nonce: ?[]const u8 = null,
    software: ?[]const u8 = null,
    lifetime_seconds: ?u32 = null,
    requested_transport: u8 = requested_transport_udp,
};

pub const AllocateSuccessResponseInfo = struct {
    transaction_id: [12]u8,
    relayed_address: ?address_attrs.StunAddress,
    mapped_address: ?address_attrs.StunAddress,
    lifetime_seconds: ?u32,
    software: ?[]const u8,
    has_message_integrity: bool,
    has_fingerprint: bool,
};

pub const RefreshSuccessResponseInfo = struct {
    transaction_id: [12]u8,
    lifetime_seconds: ?u32,
    has_message_integrity: bool,
    has_fingerprint: bool,
};

pub const DataIndicationInfo = struct {
    transaction_id: [12]u8,
    peer_address: address_attrs.StunAddress,
    data: []const u8,
};

pub const ChannelBindRequestOptions = struct {
    channel_number: u16,
    peer_address: address_attrs.StunAddress,
    username: ?[]const u8 = null,
    realm: ?[]const u8 = null,
    nonce: ?[]const u8 = null,
    integrity_key: ?[]const u8 = null,
    include_fingerprint: bool = false,
};

pub const SendIndicationOptions = struct {
    peer_address: address_attrs.StunAddress,
    data: []const u8,
};

pub const CreatePermissionRequestOptions = struct {
    peer_addresses: []const address_attrs.StunAddress,
    username: ?[]const u8 = null,
    realm: ?[]const u8 = null,
    nonce: ?[]const u8 = null,
    integrity_key: ?[]const u8 = null,
    include_fingerprint: bool = false,
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

pub fn build_channel_bind_request(buffer: []u8, transaction_id: [12]u8, options: ChannelBindRequestOptions) encoder.EncodeError![]const u8 {
    var builder = try encoder.Builder.init(buffer, channel_bind_request_type, transaction_id);

    var ch_number: [4]u8 = .{ 0, 0, 0, 0 };
    std.mem.writeInt(u16, ch_number[0..2], options.channel_number, .big);
    try builder.add_attr(channel_number_attr_type, &ch_number);
    try address_attrs.add_xor_peer_address(&builder, options.peer_address, transaction_id);

    if (options.username) |value| try builder.add_attr(username_attr_type, value);
    if (options.realm) |value| try builder.add_attr(realm_attr_type, value);
    if (options.nonce) |value| try builder.add_attr(nonce_attr_type, value);

    if (options.integrity_key) |key| {
        try integrity.add_message_integrity_attr(&builder, key);
    }

    if (options.include_fingerprint) {
        try integrity.add_fingerprint_attr(&builder);
    }

    return builder.finish();
}

pub fn build_send_indication(buffer: []u8, transaction_id: [12]u8, options: SendIndicationOptions) encoder.EncodeError![]const u8 {
    var builder = try encoder.Builder.init(buffer, send_indication_type, transaction_id);
    try address_attrs.add_xor_peer_address(&builder, options.peer_address, transaction_id);
    try builder.add_attr(data_attr_type, options.data);
    return builder.finish();
}

pub fn build_create_permission_request(buffer: []u8, transaction_id: [12]u8, options: CreatePermissionRequestOptions) TurnBuildError![]const u8 {
    if (options.peer_addresses.len == 0) return error.NoPeerAddress;

    var builder = try encoder.Builder.init(buffer, create_permission_request_type, transaction_id);

    for (options.peer_addresses) |peer| {
        try address_attrs.add_xor_peer_address(&builder, peer, transaction_id);
    }

    if (options.username) |value| try builder.add_attr(username_attr_type, value);
    if (options.realm) |value| try builder.add_attr(realm_attr_type, value);
    if (options.nonce) |value| try builder.add_attr(nonce_attr_type, value);

    if (options.integrity_key) |key| {
        try integrity.add_message_integrity_attr(&builder, key);
    }

    if (options.include_fingerprint) {
        try integrity.add_fingerprint_attr(&builder);
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

pub fn read_channel_number(view: parser.MessageView) TurnError!?u16 {
    var it = view.attr_iterator();
    while (try it.next()) |attr| {
        if (attr.header.attr_type == channel_number_attr_type) {
            if (attr.value.len != 4) return error.InvalidAttrLength;
            return std.mem.readInt(u16, attr.value[0..2], .big);
        }
    }
    return null;
}

pub fn read_data_attr(view: parser.MessageView) TurnError!?[]const u8 {
    var it = view.attr_iterator();
    while (try it.next()) |attr| {
        if (attr.header.attr_type == data_attr_type) return attr.value;
    }
    return null;
}

pub fn is_data_indication(view: parser.MessageView) bool {
    return view.header.message_type == data_indication_type;
}

pub fn parse_data_indication(view: parser.MessageView) TurnError!DataIndicationInfo {
    if (!is_data_indication(view)) return error.NotDataIndication;

    const peer_attr = (try address_attrs.find_xor_peer_address(view)) orelse return error.InvalidAttrLength;
    const payload = (try read_data_attr(view)) orelse return error.InvalidAttrLength;

    return .{
        .transaction_id = view.header.transaction_id,
        .peer_address = try address_attrs.decode_xor_address(peer_attr, view.header.transaction_id),
        .data = payload,
    };
}

pub fn count_xor_peer_addresses(view: parser.MessageView) parser.ParserError!usize {
    var count: usize = 0;
    var it = view.attr_iterator();
    while (try it.next()) |attr| {
        if (attr.header.attr_type == address_attrs.xor_peer_address_attr_type) count += 1;
    }
    return count;
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

fn read_software(view: parser.MessageView) parser.ParserError!?[]const u8 {
    var it = view.attr_iterator();
    while (try it.next()) |attr| {
        if (attr.header.attr_type == software_attr_type) return attr.value;
    }
    return null;
}

pub fn parse_allocate_success_response(view: parser.MessageView, integrity_key: ?[]const u8) TurnError!AllocateSuccessResponseInfo {
    if (!is_allocate_success_response(view)) return error.NotAllocateSuccessResponse;

    const has_message_integrity = try integrity.has_attr(view, integrity.message_integrity_type);
    const has_fingerprint = try integrity.has_attr(view, integrity.fingerprint_type);

    if (integrity_key) |key| {
        if (has_message_integrity and !(try integrity.verify_embedded_message_integrity(view, key))) return error.InvalidIntegrity;
        if (has_fingerprint and !(try integrity.verify_embedded_fingerprint(view))) return error.InvalidIntegrity;
    }

    const relayed_attr = try address_attrs.find_xor_relayed_address(view);
    const mapped_attr = try address_attrs.find_xor_mapped_address(view);

    return .{
        .transaction_id = view.header.transaction_id,
        .relayed_address = if (relayed_attr) |attr| try address_attrs.decode_xor_address(attr, view.header.transaction_id) else null,
        .mapped_address = if (mapped_attr) |attr| try address_attrs.decode_xor_address(attr, view.header.transaction_id) else null,
        .lifetime_seconds = try read_lifetime_seconds(view),
        .software = try read_software(view),
        .has_message_integrity = has_message_integrity,
        .has_fingerprint = has_fingerprint,
    };
}

pub fn parse_refresh_success_response(view: parser.MessageView, integrity_key: ?[]const u8) TurnError!RefreshSuccessResponseInfo {
    if (!is_refresh_success_response(view)) return error.NotRefreshSuccessResponse;

    const has_message_integrity = try integrity.has_attr(view, integrity.message_integrity_type);
    const has_fingerprint = try integrity.has_attr(view, integrity.fingerprint_type);

    if (integrity_key) |key| {
        if (has_message_integrity and !(try integrity.verify_embedded_message_integrity(view, key))) return error.InvalidIntegrity;
        if (has_fingerprint and !(try integrity.verify_embedded_fingerprint(view))) return error.InvalidIntegrity;
    }

    return .{
        .transaction_id = view.header.transaction_id,
        .lifetime_seconds = try read_lifetime_seconds(view),
        .has_message_integrity = has_message_integrity,
        .has_fingerprint = has_fingerprint,
    };
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

test "parse allocate success response with relayed and mapped addresses" {
    const message = @import("message.zig");
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };

    const relayed: address_attrs.StunAddress = .{ .ipv4 = .{ .port = 6000, .ip = .{ 203, 0, 113, 40 } } };
    const mapped: address_attrs.StunAddress = .{ .ipv4 = .{ .port = 4000, .ip = .{ 198, 51, 100, 20 } } };

    var packet: [320]u8 = undefined;
    var builder = try encoder.Builder.init(&packet, allocate_success_response_type, tx_id);
    try address_attrs.add_xor_relayed_address(&builder, relayed, tx_id);
    try address_attrs.add_xor_mapped_address(&builder, mapped, tx_id);

    var lifetime_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &lifetime_buf, 3600, .big);
    try builder.add_attr(lifetime_attr_type, &lifetime_buf);
    try builder.add_attr(software_attr_type, "libdice-turn");
    try integrity.add_message_integrity_attr(&builder, "turn-key");
    try integrity.add_fingerprint_attr(&builder);

    const bytes = try builder.finish();
    const view = try parser.parse_message(bytes);
    try std.testing.expectEqual(@as(usize, bytes.len - message.header_size), view.body.len);

    const parsed = try parse_allocate_success_response(view, "turn-key");
    try std.testing.expectEqualDeep(relayed, parsed.relayed_address.?);
    try std.testing.expectEqualDeep(mapped, parsed.mapped_address.?);
    try std.testing.expectEqual(@as(u32, 3600), parsed.lifetime_seconds.?);
    try std.testing.expectEqualStrings("libdice-turn", parsed.software.?);
    try std.testing.expect(parsed.has_message_integrity);
    try std.testing.expect(parsed.has_fingerprint);
}

test "channel bind request and send indication builders" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    const peer: address_attrs.StunAddress = .{ .ipv4 = .{ .port = 3479, .ip = .{ 203, 0, 113, 55 } } };
    var packet: [256]u8 = undefined;

    const bind_bytes = try build_channel_bind_request(&packet, tx_id, .{
        .channel_number = 0x4001,
        .peer_address = peer,
        .username = "user",
        .realm = "example.org",
        .nonce = "nonce",
        .integrity_key = "turn-key",
        .include_fingerprint = true,
    });

    const bind_view = try parser.parse_message(bind_bytes);
    try std.testing.expectEqual(@as(?u16, 0x4001), try read_channel_number(bind_view));
    const peer_attr = (try address_attrs.find_xor_peer_address(bind_view)).?;
    const decoded_peer = try address_attrs.decode_xor_address(peer_attr, tx_id);
    try std.testing.expectEqualDeep(peer, decoded_peer);

    const send_bytes = try build_send_indication(&packet, tx_id, .{
        .peer_address = peer,
        .data = "hello-turn-peer",
    });

    const send_view = try parser.parse_message(send_bytes);
    try std.testing.expectEqualStrings("hello-turn-peer", (try read_data_attr(send_view)).?);
    const send_peer_attr = (try address_attrs.find_xor_peer_address(send_view)).?;
    const send_peer = try address_attrs.decode_xor_address(send_peer_attr, tx_id);
    try std.testing.expectEqualDeep(peer, send_peer);
}

test "create permission request supports multiple peer addresses" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    const peers = [_]address_attrs.StunAddress{
        .{ .ipv4 = .{ .port = 5001, .ip = .{ 203, 0, 113, 10 } } },
        .{ .ipv4 = .{ .port = 5002, .ip = .{ 203, 0, 113, 11 } } },
    };

    var packet: [320]u8 = undefined;
    const bytes = try build_create_permission_request(&packet, tx_id, .{
        .peer_addresses = &peers,
        .username = "user",
        .realm = "example.org",
        .nonce = "nonce",
        .integrity_key = "turn-key",
        .include_fingerprint = true,
    });

    const view = try parser.parse_message(bytes);
    try std.testing.expectEqual(@as(u16, create_permission_request_type), view.header.message_type);
    try std.testing.expectEqual(@as(usize, 2), try count_xor_peer_addresses(view));
    try std.testing.expect(try integrity.verify_embedded_message_integrity(view, "turn-key"));
    try std.testing.expect(try integrity.verify_embedded_fingerprint(view));
}

test "create permission request rejects empty peer list" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    var packet: [64]u8 = undefined;
    const peers = [_]address_attrs.StunAddress{};

    try std.testing.expectError(error.NoPeerAddress, build_create_permission_request(&packet, tx_id, .{ .peer_addresses = &peers }));
}

test "parse TURN data indication with xor peer and data" {
    const tx_id = [_]u8{ 3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5, 8 };
    const peer: address_attrs.StunAddress = .{ .ipv4 = .{ .port = 7777, .ip = .{ 203, 0, 113, 90 } } };
    var packet: [256]u8 = undefined;

    var builder = try encoder.Builder.init(&packet, data_indication_type, tx_id);
    try address_attrs.add_xor_peer_address(&builder, peer, tx_id);
    try builder.add_attr(data_attr_type, "relay-payload");
    const bytes = try builder.finish();

    const view = try parser.parse_message(bytes);
    try std.testing.expect(is_data_indication(view));
    const parsed = try parse_data_indication(view);
    try std.testing.expectEqualDeep(peer, parsed.peer_address);
    try std.testing.expectEqualStrings("relay-payload", parsed.data);
}
