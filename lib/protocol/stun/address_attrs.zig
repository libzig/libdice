const std = @import("std");
const message = @import("message.zig");
const attrs = @import("attrs.zig");
const parser = @import("parser.zig");
const encoder = @import("encoder.zig");

pub const xor_mapped_address_attr_type: u16 = 0x0020;
pub const xor_peer_address_attr_type: u16 = 0x0012;
pub const xor_relayed_address_attr_type: u16 = 0x0016;

pub const family_ipv4: u8 = 0x01;
pub const family_ipv6: u8 = 0x02;

pub const AddressAttrError = error{
    InvalidAttrLength,
    InvalidFamily,
    InvalidAttrType,
    BufferTooSmall,
};

pub const StunAddress = union(enum) {
    ipv4: struct {
        port: u16,
        ip: [4]u8,
    },
    ipv6: struct {
        port: u16,
        ip: [16]u8,
    },
};

fn cookie_bytes() [4]u8 {
    var out: [4]u8 = undefined;
    std.mem.writeInt(u32, &out, message.magic_cookie, .big);
    return out;
}

pub fn encode_xor_mapped_address_value(out: []u8, address: StunAddress, transaction_id: [12]u8) AddressAttrError![]const u8 {
    const cookie = cookie_bytes();

    switch (address) {
        .ipv4 => |v4| {
            if (out.len < 8) return error.BufferTooSmall;

            out[0] = 0;
            out[1] = family_ipv4;

            const xport = v4.port ^ @as(u16, @truncate(message.magic_cookie >> 16));
            std.mem.writeInt(u16, out[2..4], xport, .big);

            for (v4.ip, 0..) |b, idx| {
                out[4 + idx] = b ^ cookie[idx];
            }

            return out[0..8];
        },
        .ipv6 => |v6| {
            if (out.len < 20) return error.BufferTooSmall;

            out[0] = 0;
            out[1] = family_ipv6;

            const xport = v6.port ^ @as(u16, @truncate(message.magic_cookie >> 16));
            std.mem.writeInt(u16, out[2..4], xport, .big);

            for (v6.ip[0..4], 0..) |b, idx| {
                out[4 + idx] = b ^ cookie[idx];
            }
            for (v6.ip[4..16], 0..) |b, idx| {
                out[8 + idx] = b ^ transaction_id[idx];
            }

            return out[0..20];
        },
    }
}

pub fn decode_xor_address(attr: parser.AttrView, transaction_id: [12]u8) AddressAttrError!StunAddress {
    if (attr.header.attr_type != xor_mapped_address_attr_type and attr.header.attr_type != xor_peer_address_attr_type and attr.header.attr_type != xor_relayed_address_attr_type) {
        return error.InvalidAttrType;
    }
    if (attr.value.len < 4) return error.InvalidAttrLength;

    const cookie = cookie_bytes();
    const family = attr.value[1];
    const port = std.mem.readInt(u16, attr.value[2..4], .big) ^ @as(u16, @truncate(message.magic_cookie >> 16));

    switch (family) {
        family_ipv4 => {
            if (attr.value.len != 8) return error.InvalidAttrLength;

            var ip: [4]u8 = undefined;
            for (&ip, 0..) |*byte, idx| {
                byte.* = attr.value[4 + idx] ^ cookie[idx];
            }

            return .{ .ipv4 = .{ .port = port, .ip = ip } };
        },
        family_ipv6 => {
            if (attr.value.len != 20) return error.InvalidAttrLength;

            var ip: [16]u8 = undefined;
            for (ip[0..4], 0..) |*byte, idx| {
                byte.* = attr.value[4 + idx] ^ cookie[idx];
            }
            for (ip[4..16], 0..) |*byte, idx| {
                byte.* = attr.value[8 + idx] ^ transaction_id[idx];
            }

            return .{ .ipv6 = .{ .port = port, .ip = ip } };
        },
        else => return error.InvalidFamily,
    }
}

pub fn decode_xor_mapped_address(attr: parser.AttrView, transaction_id: [12]u8) AddressAttrError!StunAddress {
    if (attr.header.attr_type != xor_mapped_address_attr_type) return error.InvalidAttrType;
    return decode_xor_address(attr, transaction_id);
}

pub fn add_xor_mapped_address(builder: *encoder.Builder, address: StunAddress, transaction_id: [12]u8) encoder.EncodeError!void {
    var value_buf: [20]u8 = undefined;
    const value = encode_xor_mapped_address_value(&value_buf, address, transaction_id) catch return error.BufferTooSmall;
    try builder.add_attr(xor_mapped_address_attr_type, value);
}

pub fn add_xor_peer_address(builder: *encoder.Builder, address: StunAddress, transaction_id: [12]u8) encoder.EncodeError!void {
    var value_buf: [20]u8 = undefined;
    const value = encode_xor_mapped_address_value(&value_buf, address, transaction_id) catch return error.BufferTooSmall;
    try builder.add_attr(xor_peer_address_attr_type, value);
}

pub fn add_xor_relayed_address(builder: *encoder.Builder, address: StunAddress, transaction_id: [12]u8) encoder.EncodeError!void {
    var value_buf: [20]u8 = undefined;
    const value = encode_xor_mapped_address_value(&value_buf, address, transaction_id) catch return error.BufferTooSmall;
    try builder.add_attr(xor_relayed_address_attr_type, value);
}

pub fn find_xor_mapped_address(view: parser.MessageView) parser.ParserError!?parser.AttrView {
    var it = view.attr_iterator();
    while (try it.next()) |attr| {
        if (attr.header.attr_type == xor_mapped_address_attr_type) return attr;
    }
    return null;
}

pub fn find_xor_peer_address(view: parser.MessageView) parser.ParserError!?parser.AttrView {
    var it = view.attr_iterator();
    while (try it.next()) |attr| {
        if (attr.header.attr_type == xor_peer_address_attr_type) return attr;
    }
    return null;
}

pub fn find_xor_relayed_address(view: parser.MessageView) parser.ParserError!?parser.AttrView {
    var it = view.attr_iterator();
    while (try it.next()) |attr| {
        if (attr.header.attr_type == xor_relayed_address_attr_type) return attr;
    }
    return null;
}

test "xor-mapped-address ipv4 roundtrip" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    const original: StunAddress = .{ .ipv4 = .{ .port = 3478, .ip = .{ 192, 0, 2, 1 } } };

    var value: [8]u8 = undefined;
    const encoded = try encode_xor_mapped_address_value(&value, original, tx_id);

    var packet: [12]u8 = undefined;
    _ = try attrs.encode_attr(xor_mapped_address_attr_type, encoded, &packet);
    const view = try attrs.decode_attr_view(&packet);
    const attr = parser.AttrView{ .header = view.header, .value = view.value, .total_size = view.total_size };

    const decoded = try decode_xor_mapped_address(attr, tx_id);
    try std.testing.expectEqualDeep(original, decoded);
}

test "xor-mapped-address ipv6 roundtrip" {
    const tx_id = [_]u8{ 1, 3, 5, 7, 9, 11, 13, 15, 2, 4, 6, 8 };
    const original: StunAddress = .{ .ipv6 = .{ .port = 50000, .ip = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 1, 0, 2, 0, 3, 0, 4, 0xaa, 0xbb, 0xcc, 0xdd } } };

    var value: [20]u8 = undefined;
    const encoded = try encode_xor_mapped_address_value(&value, original, tx_id);

    var packet: [24]u8 = undefined;
    _ = try attrs.encode_attr(xor_mapped_address_attr_type, encoded, &packet);
    const view = try attrs.decode_attr_view(&packet);
    const attr = parser.AttrView{ .header = view.header, .value = view.value, .total_size = view.total_size };

    const decoded = try decode_xor_mapped_address(attr, tx_id);
    try std.testing.expectEqualDeep(original, decoded);
}

test "xor-mapped-address rejects malformed length" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };

    var packet: [8]u8 = undefined;
    const malformed_value = [_]u8{ 0, family_ipv4, 0, 0 };
    _ = try attrs.encode_attr(xor_mapped_address_attr_type, &malformed_value, &packet);
    const view = try attrs.decode_attr_view(&packet);
    const attr = parser.AttrView{ .header = view.header, .value = view.value, .total_size = view.total_size };

    try std.testing.expectError(error.InvalidAttrLength, decode_xor_mapped_address(attr, tx_id));
}

test "xor-peer and xor-relayed helper adders" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    const peer: StunAddress = .{ .ipv4 = .{ .port = 4000, .ip = .{ 198, 51, 100, 5 } } };
    const relayed: StunAddress = .{ .ipv4 = .{ .port = 5000, .ip = .{ 203, 0, 113, 99 } } };

    var packet: [128]u8 = undefined;
    var builder = try encoder.Builder.init(&packet, 0x0001, tx_id);
    try add_xor_peer_address(&builder, peer, tx_id);
    try add_xor_relayed_address(&builder, relayed, tx_id);

    const bytes = try builder.finish();
    const view = try parser.parse_message(bytes);

    const peer_attr = (try find_xor_peer_address(view)).?;
    const relayed_attr = (try find_xor_relayed_address(view)).?;

    const decoded_peer = try decode_xor_address(peer_attr, tx_id);
    const decoded_relayed = try decode_xor_address(relayed_attr, tx_id);
    try std.testing.expectEqualDeep(peer, decoded_peer);
    try std.testing.expectEqualDeep(relayed, decoded_relayed);
}
