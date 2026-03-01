const std = @import("std");
const parser = @import("parser.zig");
const encoder = @import("encoder.zig");

pub const priority_attr_type: u16 = 0x0024;
pub const use_candidate_attr_type: u16 = 0x0025;
pub const ice_controlled_attr_type: u16 = 0x8029;
pub const ice_controlling_attr_type: u16 = 0x802A;

pub const Role = enum {
    controlled,
    controlling,
};

pub const IceAttrError = error{
    InvalidAttrLength,
};

pub const IceUsageError = IceAttrError || parser.ParserError;

pub fn add_priority(builder: *encoder.Builder, priority: u32) encoder.EncodeError!void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, priority, .big);
    try builder.add_attr(priority_attr_type, &buf);
}

pub fn add_use_candidate(builder: *encoder.Builder) encoder.EncodeError!void {
    try builder.add_attr(use_candidate_attr_type, "");
}

pub fn add_ice_controlled(builder: *encoder.Builder, tie_breaker: u64) encoder.EncodeError!void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, tie_breaker, .big);
    try builder.add_attr(ice_controlled_attr_type, &buf);
}

pub fn add_ice_controlling(builder: *encoder.Builder, tie_breaker: u64) encoder.EncodeError!void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, tie_breaker, .big);
    try builder.add_attr(ice_controlling_attr_type, &buf);
}

pub fn read_priority(attr: parser.AttrView) IceAttrError!u32 {
    if (attr.header.attr_type != priority_attr_type or attr.value.len != 4) return error.InvalidAttrLength;
    return std.mem.readInt(u32, attr.value[0..4], .big);
}

pub fn has_use_candidate(view: parser.MessageView) IceUsageError!bool {
    var it = view.attr_iterator();
    while (try it.next()) |attr| {
        if (attr.header.attr_type == use_candidate_attr_type) {
            if (attr.value.len != 0) return error.InvalidAttrLength;
            return true;
        }
    }
    return false;
}

pub fn read_role(view: parser.MessageView) IceUsageError!?struct { role: Role, tie_breaker: u64 } {
    var it = view.attr_iterator();
    while (try it.next()) |attr| {
        if (attr.header.attr_type == ice_controlled_attr_type) {
            if (attr.value.len != 8) return error.InvalidAttrLength;
            return .{ .role = .controlled, .tie_breaker = std.mem.readInt(u64, attr.value[0..8], .big) };
        }

        if (attr.header.attr_type == ice_controlling_attr_type) {
            if (attr.value.len != 8) return error.InvalidAttrLength;
            return .{ .role = .controlling, .tie_breaker = std.mem.readInt(u64, attr.value[0..8], .big) };
        }
    }

    return null;
}

test "ice usage helpers encode and decode attributes" {
    const message = @import("message.zig");
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    var packet: [128]u8 = undefined;

    var builder = try encoder.Builder.init(&packet, 0x0001, tx_id);
    try add_priority(&builder, 1234);
    try add_use_candidate(&builder);
    try add_ice_controlling(&builder, 0x1122334455667788);

    const bytes = try builder.finish();
    const view = try parser.parse_message(bytes);
    try std.testing.expectEqual(@as(usize, bytes.len - message.header_size), view.body.len);

    var it = view.attr_iterator();
    const first = (try it.next()).?;
    const prio = try read_priority(first);
    try std.testing.expectEqual(@as(u32, 1234), prio);

    try std.testing.expect(try has_use_candidate(view));

    const role = (try read_role(view)).?;
    try std.testing.expectEqual(Role.controlling, role.role);
    try std.testing.expectEqual(@as(u64, 0x1122334455667788), role.tie_breaker);
}

test "use-candidate requires empty body" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    var packet: [32]u8 = undefined;
    var builder = try encoder.Builder.init(&packet, 0x0001, tx_id);
    try builder.add_attr(use_candidate_attr_type, "x");

    const bytes = try builder.finish();
    const view = try parser.parse_message(bytes);
    try std.testing.expectError(error.InvalidAttrLength, has_use_candidate(view));
}
