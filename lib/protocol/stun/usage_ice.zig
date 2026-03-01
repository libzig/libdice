const std = @import("std");
const parser = @import("parser.zig");
const encoder = @import("encoder.zig");
const usage_bind = @import("usage_bind.zig");
const integrity = @import("integrity.zig");

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

pub const ConnectivityUsageError = IceUsageError || integrity.IntegrityError || error{
    NotConnectivityCheck,
    DuplicateRoleAttributes,
    InvalidIntegrity,
};

pub const RoleTieBreaker = struct {
    role: Role,
    tie_breaker: u64,
};

pub const ConnectivityCheckRequestOptions = struct {
    username: ?[]const u8 = null,
    priority: ?u32 = null,
    role: ?RoleTieBreaker = null,
    use_candidate: bool = false,
    integrity_key: ?[]const u8 = null,
    include_fingerprint: bool = false,
};

pub const ConnectivityCheckRequestInfo = struct {
    transaction_id: [12]u8,
    username: ?[]const u8,
    priority: ?u32,
    role: ?RoleTieBreaker,
    use_candidate: bool,
    has_message_integrity: bool,
    has_fingerprint: bool,
};

pub const ConnectivityCheckSuccessResponseOptions = struct {
    software: ?[]const u8 = null,
    integrity_key: ?[]const u8 = null,
    include_fingerprint: bool = false,
};

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

pub fn build_connectivity_check_request(buffer: []u8, transaction_id: [12]u8, options: ConnectivityCheckRequestOptions) encoder.EncodeError![]const u8 {
    var builder = try encoder.Builder.init(buffer, usage_bind.binding_request_type, transaction_id);

    if (options.username) |value| {
        try builder.add_attr(usage_bind.username_attr_type, value);
    }

    if (options.priority) |value| {
        try add_priority(&builder, value);
    }

    if (options.role) |value| {
        switch (value.role) {
            .controlled => try add_ice_controlled(&builder, value.tie_breaker),
            .controlling => try add_ice_controlling(&builder, value.tie_breaker),
        }
    }

    if (options.use_candidate) {
        try add_use_candidate(&builder);
    }

    if (options.integrity_key) |key| {
        try integrity.add_message_integrity_attr(&builder, key);
    }

    if (options.include_fingerprint) {
        try integrity.add_fingerprint_attr(&builder);
    }

    return builder.finish();
}

pub fn build_connectivity_check_success_response(buffer: []u8, transaction_id: [12]u8, options: ConnectivityCheckSuccessResponseOptions) encoder.EncodeError![]const u8 {
    var builder = try encoder.Builder.init(buffer, usage_bind.binding_response_type, transaction_id);

    if (options.software) |value| {
        try builder.add_attr(usage_bind.software_attr_type, value);
    }

    if (options.integrity_key) |key| {
        try integrity.add_message_integrity_attr(&builder, key);
    }

    if (options.include_fingerprint) {
        try integrity.add_fingerprint_attr(&builder);
    }

    return builder.finish();
}

pub fn is_connectivity_check_request(view: parser.MessageView) bool {
    return view.header.message_type == usage_bind.binding_request_type;
}

pub fn is_connectivity_check_success_response(view: parser.MessageView) bool {
    return view.header.message_type == usage_bind.binding_response_type;
}

fn read_username(view: parser.MessageView) ConnectivityUsageError!?[]const u8 {
    var it = view.attr_iterator();
    while (try it.next()) |attr| {
        if (attr.header.attr_type == usage_bind.username_attr_type) {
            return attr.value;
        }
    }

    return null;
}

fn read_priority_in_view(view: parser.MessageView) ConnectivityUsageError!?u32 {
    var it = view.attr_iterator();
    while (try it.next()) |attr| {
        if (attr.header.attr_type == priority_attr_type) {
            return try read_priority(attr);
        }
    }

    return null;
}

fn read_single_role(view: parser.MessageView) ConnectivityUsageError!?RoleTieBreaker {
    var it = view.attr_iterator();
    var role: ?RoleTieBreaker = null;

    while (try it.next()) |attr| {
        if (attr.header.attr_type == ice_controlled_attr_type) {
            if (attr.value.len != 8) return error.InvalidAttrLength;
            if (role != null) return error.DuplicateRoleAttributes;

            role = .{
                .role = .controlled,
                .tie_breaker = std.mem.readInt(u64, attr.value[0..8], .big),
            };
            continue;
        }

        if (attr.header.attr_type == ice_controlling_attr_type) {
            if (attr.value.len != 8) return error.InvalidAttrLength;
            if (role != null) return error.DuplicateRoleAttributes;

            role = .{
                .role = .controlling,
                .tie_breaker = std.mem.readInt(u64, attr.value[0..8], .big),
            };
        }
    }

    return role;
}

pub fn parse_connectivity_check_request(view: parser.MessageView, integrity_key: ?[]const u8) ConnectivityUsageError!ConnectivityCheckRequestInfo {
    if (!is_connectivity_check_request(view)) return error.NotConnectivityCheck;

    const has_integrity_attr = try integrity.has_attr(view, integrity.message_integrity_type);
    const has_fingerprint_attr = try integrity.has_attr(view, integrity.fingerprint_type);

    if (integrity_key) |key| {
        if (has_integrity_attr) {
            const ok = try integrity.verify_embedded_message_integrity(view, key);
            if (!ok) return error.InvalidIntegrity;
        }
        if (has_fingerprint_attr) {
            const ok = try integrity.verify_embedded_fingerprint(view);
            if (!ok) return error.InvalidIntegrity;
        }
    }

    return .{
        .transaction_id = view.header.transaction_id,
        .username = try read_username(view),
        .priority = try read_priority_in_view(view),
        .role = try read_single_role(view),
        .use_candidate = try has_use_candidate(view),
        .has_message_integrity = has_integrity_attr,
        .has_fingerprint = has_fingerprint_attr,
    };
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

test "connectivity check request end-to-end with integrity and fingerprint" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    var packet: [256]u8 = undefined;

    const bytes = try build_connectivity_check_request(&packet, tx_id, .{
        .username = "local:remote",
        .priority = 1862270975,
        .role = .{ .role = .controlling, .tie_breaker = 0x1020304050607080 },
        .use_candidate = true,
        .integrity_key = "ice-password",
        .include_fingerprint = true,
    });

    const view = try parser.parse_message(bytes);
    const info = try parse_connectivity_check_request(view, "ice-password");

    try std.testing.expectEqualSlices(u8, &tx_id, &info.transaction_id);
    try std.testing.expectEqualStrings("local:remote", info.username.?);
    try std.testing.expectEqual(@as(u32, 1862270975), info.priority.?);
    try std.testing.expectEqual(Role.controlling, info.role.?.role);
    try std.testing.expectEqual(@as(u64, 0x1020304050607080), info.role.?.tie_breaker);
    try std.testing.expect(info.use_candidate);
    try std.testing.expect(info.has_message_integrity);
    try std.testing.expect(info.has_fingerprint);
}

test "connectivity check parser rejects duplicate role attributes" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    var packet: [128]u8 = undefined;

    var builder = try encoder.Builder.init(&packet, usage_bind.binding_request_type, tx_id);
    try add_ice_controlled(&builder, 1);
    try add_ice_controlling(&builder, 2);

    const bytes = try builder.finish();
    const view = try parser.parse_message(bytes);
    try std.testing.expectError(error.DuplicateRoleAttributes, parse_connectivity_check_request(view, null));
}

test "connectivity check builder can produce success response" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    var packet: [192]u8 = undefined;

    const bytes = try build_connectivity_check_success_response(&packet, tx_id, .{
        .software = "libdice-check",
        .integrity_key = "ice-password",
        .include_fingerprint = true,
    });

    const view = try parser.parse_message(bytes);
    try std.testing.expect(is_connectivity_check_success_response(view));
    try std.testing.expect(try integrity.verify_embedded_message_integrity(view, "ice-password"));
    try std.testing.expect(try integrity.verify_embedded_fingerprint(view));
}
