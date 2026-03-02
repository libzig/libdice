const std = @import("std");
const message = @import("message.zig");
const encoder = @import("encoder.zig");
const parser = @import("parser.zig");
const attrs = @import("attrs.zig");
const hmac_sha1 = @import("../../crypto/hmac_sha1.zig");

pub const message_integrity_type: u16 = 0x0008;
pub const message_integrity_size: usize = hmac_sha1.mac_length;

pub const fingerprint_type: u16 = 0x8028;
pub const fingerprint_size: usize = 4;
pub const fingerprint_xor: u32 = 0x5354554e;

pub const IntegrityError = parser.ParserError || error{
    MissingAttribute,
    InvalidAttrLength,
};

pub fn compute_message_integrity(message_bytes: []const u8, key: []const u8) hmac_sha1.Mac {
    return hmac_sha1.compute(key, message_bytes);
}

pub fn verify_message_integrity(expected: hmac_sha1.Mac, message_bytes: []const u8, key: []const u8) bool {
    return hmac_sha1.verify(expected, key, message_bytes);
}

pub fn write_message_integrity(out: []u8, message_bytes: []const u8, key: []const u8) error{BufferTooSmall}!void {
    if (out.len < message_integrity_size) return error.BufferTooSmall;
    const mac = compute_message_integrity(message_bytes, key);
    @memcpy(out[0..message_integrity_size], &mac);
}

pub fn compute_fingerprint(message_bytes: []const u8) u32 {
    return std.hash.Crc32.hash(message_bytes) ^ fingerprint_xor;
}

pub fn write_fingerprint_be(out: []u8, message_bytes: []const u8) error{BufferTooSmall}!void {
    if (out.len < fingerprint_size) return error.BufferTooSmall;
    std.mem.writeInt(u32, out[0..4], compute_fingerprint(message_bytes), .big);
}

pub fn read_fingerprint_be(in: []const u8) error{BufferTooSmall}!u32 {
    if (in.len < fingerprint_size) return error.BufferTooSmall;
    return std.mem.readInt(u32, in[0..4], .big);
}

pub fn add_message_integrity_attr(builder: *encoder.Builder, key: []const u8) encoder.EncodeError!void {
    const body_len_before = builder.write_index - message.header_size;
    const message_len_with_integrity = body_len_before + attrs.attr_header_size + message_integrity_size;

    var encoded_header: [message.header_size]u8 = undefined;
    const adjusted_header = message.Header.init(builder.header.message_type, @intCast(message_len_with_integrity), builder.header.transaction_id);
    _ = adjusted_header.encode(&encoded_header) catch return error.BufferTooSmall;

    var mac: hmac_sha1.Mac = undefined;
    var hmac_ctx = std.crypto.auth.hmac.HmacSha1.init(key);
    hmac_ctx.update(&encoded_header);
    hmac_ctx.update(builder.buffer[message.header_size..builder.write_index]);
    hmac_ctx.final(&mac);

    try builder.add_attr(message_integrity_type, &mac);
}

pub fn add_fingerprint_attr(builder: *encoder.Builder) encoder.EncodeError!void {
    const body_len_before = builder.write_index - message.header_size;
    const message_len_with_fingerprint = body_len_before + attrs.attr_header_size + fingerprint_size;

    var encoded_header: [message.header_size]u8 = undefined;
    const adjusted_header = message.Header.init(builder.header.message_type, @intCast(message_len_with_fingerprint), builder.header.transaction_id);
    _ = adjusted_header.encode(&encoded_header) catch return error.BufferTooSmall;

    var crc = std.hash.Crc32.init();
    crc.update(&encoded_header);
    crc.update(builder.buffer[message.header_size..builder.write_index]);

    var value: [4]u8 = undefined;
    std.mem.writeInt(u32, &value, crc.final() ^ fingerprint_xor, .big);
    try builder.add_attr(fingerprint_type, &value);
}

fn find_attr_with_offset(view: parser.MessageView, attr_type: u16) parser.ParserError!?struct {
    attr: parser.AttrView,
    body_offset: usize,
} {
    var it = view.attr_iterator();
    var body_offset: usize = 0;

    while (try it.next()) |attr| {
        if (attr.header.attr_type == attr_type) {
            return .{ .attr = attr, .body_offset = body_offset };
        }
        body_offset += attr.total_size;
    }

    return null;
}

pub fn has_attr(view: parser.MessageView, attr_type: u16) parser.ParserError!bool {
    return (try find_attr_with_offset(view, attr_type)) != null;
}

fn compute_message_integrity_for_body_prefix(header: message.Header, body_prefix: []const u8, key: []const u8) hmac_sha1.Mac {
    var encoded_header: [message.header_size]u8 = undefined;
    const message_len_with_integrity = body_prefix.len + attrs.attr_header_size + message_integrity_size;
    const adjusted_header = message.Header.init(header.message_type, @intCast(message_len_with_integrity), header.transaction_id);
    _ = adjusted_header.encode(&encoded_header) catch unreachable;

    var mac: hmac_sha1.Mac = undefined;
    var hmac_ctx = std.crypto.auth.hmac.HmacSha1.init(key);
    hmac_ctx.update(&encoded_header);
    hmac_ctx.update(body_prefix);
    hmac_ctx.final(&mac);
    return mac;
}

fn compute_fingerprint_for_body_prefix(header: message.Header, body_prefix: []const u8) u32 {
    var encoded_header: [message.header_size]u8 = undefined;
    const message_len_with_fingerprint = body_prefix.len + attrs.attr_header_size + fingerprint_size;
    const adjusted_header = message.Header.init(header.message_type, @intCast(message_len_with_fingerprint), header.transaction_id);
    _ = adjusted_header.encode(&encoded_header) catch unreachable;

    var crc = std.hash.Crc32.init();
    crc.update(&encoded_header);
    crc.update(body_prefix);
    return crc.final() ^ fingerprint_xor;
}

pub fn verify_embedded_message_integrity(view: parser.MessageView, key: []const u8) IntegrityError!bool {
    const found = try find_attr_with_offset(view, message_integrity_type) orelse return error.MissingAttribute;
    if (found.attr.value.len != message_integrity_size) return error.InvalidAttrLength;

    const expected = compute_message_integrity_for_body_prefix(view.header, view.body[0..found.body_offset], key);

    var actual: hmac_sha1.Mac = undefined;
    @memcpy(&actual, found.attr.value[0..message_integrity_size]);
    return std.crypto.timing_safe.eql(hmac_sha1.Mac, expected, actual);
}

pub fn verify_embedded_fingerprint(view: parser.MessageView) IntegrityError!bool {
    const found = try find_attr_with_offset(view, fingerprint_type) orelse return error.MissingAttribute;
    if (found.attr.value.len != fingerprint_size) return error.InvalidAttrLength;

    const expected = compute_fingerprint_for_body_prefix(view.header, view.body[0..found.body_offset]);
    const actual = std.mem.readInt(u32, found.attr.value[0..4], .big);
    return expected == actual;
}

test "message integrity known vector" {
    const mac = compute_message_integrity("The quick brown fox jumps over the lazy dog", "key");
    const expected = [_]u8{
        0xde, 0x7c, 0x9b, 0x85, 0xb8, 0xb7, 0x8a, 0xa6, 0xbc, 0x8a,
        0x7a, 0x36, 0xf7, 0x0a, 0x90, 0x70, 0x1c, 0x9d, 0xb4, 0xd9,
    };
    try std.testing.expectEqualSlices(u8, &expected, &mac);
    try std.testing.expect(verify_message_integrity(mac, "The quick brown fox jumps over the lazy dog", "key"));
}

test "fingerprint known vectors" {
    try std.testing.expectEqual(@as(u32, 0x5354554e), compute_fingerprint(""));
    try std.testing.expectEqual(@as(u32, 0x6670148c), compute_fingerprint("abc"));
}

test "fingerprint read write big endian" {
    var bytes: [4]u8 = undefined;
    try write_fingerprint_be(&bytes, "abc");
    const parsed = try read_fingerprint_be(&bytes);
    try std.testing.expectEqual(@as(u32, 0x6670148c), parsed);
}

test "integrity writers reject short buffers" {
    var mac_buf: [19]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, write_message_integrity(&mac_buf, "data", "key"));

    var fp_buf: [3]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, write_fingerprint_be(&fp_buf, "data"));
    try std.testing.expectError(error.BufferTooSmall, read_fingerprint_be(&fp_buf));
}

test "embedded message integrity verification" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    var packet: [128]u8 = undefined;

    var builder = try encoder.Builder.init(&packet, 0x0001, tx_id);
    try builder.add_attr(0x0006, "user");
    try add_message_integrity_attr(&builder, "secret");

    const bytes = try builder.finish();
    const view = try parser.parse_message(bytes);

    try std.testing.expect(try verify_embedded_message_integrity(view, "secret"));
    try std.testing.expect(!(try verify_embedded_message_integrity(view, "wrong-secret")));
}

test "embedded fingerprint verification" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    var packet: [128]u8 = undefined;

    var builder = try encoder.Builder.init(&packet, 0x0001, tx_id);
    try builder.add_attr(0x0006, "user");
    try add_fingerprint_attr(&builder);

    const bytes = try builder.finish();
    const view = try parser.parse_message(bytes);
    try std.testing.expect(try verify_embedded_fingerprint(view));
}

test "embedded integrity helpers fail when attribute missing" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    var packet: [64]u8 = undefined;

    var builder = try encoder.Builder.init(&packet, 0x0001, tx_id);
    try builder.add_attr(0x0006, "user");

    const bytes = try builder.finish();
    const view = try parser.parse_message(bytes);

    try std.testing.expectError(error.MissingAttribute, verify_embedded_message_integrity(view, "key"));
    try std.testing.expectError(error.MissingAttribute, verify_embedded_fingerprint(view));
}
