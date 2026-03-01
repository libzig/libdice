const std = @import("std");
const candidate = @import("../core/candidate.zig");
const udp_socket = @import("udp_socket.zig");
const parser = @import("../protocol/stun/parser.zig");
const usage_turn = @import("../protocol/stun/usage_turn.zig");
const address_attrs = @import("../protocol/stun/address_attrs.zig");
const channel_data = @import("../protocol/turn/channel_data.zig");

pub const Permission = struct {
    peer: candidate.Address,
    expires_at_ms: u64,

    pub fn refresh_due_at_ms(self: Permission, refresh_margin_ms: u64) u64 {
        if (refresh_margin_ms >= self.expires_at_ms) return 0;
        return self.expires_at_ms - refresh_margin_ms;
    }
};

pub const ChannelBinding = struct {
    channel_number: u16,
    peer: candidate.Address,
    expires_at_ms: u64,

    pub fn refresh_due_at_ms(self: ChannelBinding, refresh_margin_ms: u64) u64 {
        if (refresh_margin_ms >= self.expires_at_ms) return 0;
        return self.expires_at_ms - refresh_margin_ms;
    }
};

pub const AllocationLease = struct {
    relayed_address: ?address_attrs.StunAddress,
    mapped_address: ?address_attrs.StunAddress,
    lifetime_seconds: u32,
    expires_at_ms: u64,

    pub fn refresh_due_at_ms(self: AllocationLease, refresh_margin_ms: u64) u64 {
        if (refresh_margin_ms >= self.expires_at_ms) return 0;
        return self.expires_at_ms - refresh_margin_ms;
    }
};

pub const ReceivedPacket = union(enum) {
    stun: parser.MessageView,
    channel_data: channel_data.FrameView,
    relayed_data: struct {
        peer: candidate.Address,
        payload: []const u8,
    },
};

pub const UdpRecvError = @typeInfo(@typeInfo(@TypeOf(udp_socket.UdpSocket.recv_from)).@"fn".return_type.?).error_union.error_set;

pub const TurnUdpSocketError = UdpRecvError || parser.ParserError || channel_data.ChannelDataError || usage_turn.TurnError || error{
    UnexpectedSource,
    OutOfMemory,
};

pub const TurnUdpSocket = struct {
    const PendingRefreshKind = enum {
        permission,
        channel,
    };

    const PendingRefresh = struct {
        transaction_id: [12]u8,
        kind: PendingRefreshKind,
        peer: candidate.Address,
        channel_number: u16,
        lifetime_seconds: u32,
    };

    pub const permission_default_lifetime_seconds: u32 = 300;
    pub const channel_default_lifetime_seconds: u32 = 600;

    allocator: std.mem.Allocator,
    socket: udp_socket.UdpSocket,
    server: candidate.Address,
    allocation: ?AllocationLease,
    permissions: std.ArrayList(Permission),
    channels: std.ArrayList(ChannelBinding),
    pending_refreshes: std.ArrayList(PendingRefresh),
    auth_realm: std.ArrayList(u8),
    auth_nonce: std.ArrayList(u8),
    auth_retry_required: bool,

    pub fn init_nonblocking(allocator: std.mem.Allocator, local_bind: candidate.Address, server: candidate.Address) !TurnUdpSocket {
        return .{
            .allocator = allocator,
            .socket = try udp_socket.UdpSocket.bind_nonblocking(local_bind),
            .server = server,
            .allocation = null,
            .permissions = .empty,
            .channels = .empty,
            .pending_refreshes = .empty,
            .auth_realm = .empty,
            .auth_nonce = .empty,
            .auth_retry_required = false,
        };
    }

    pub fn deinit(self: *TurnUdpSocket) void {
        self.auth_realm.deinit(self.allocator);
        self.auth_nonce.deinit(self.allocator);
        self.pending_refreshes.deinit(self.allocator);
        self.permissions.deinit(self.allocator);
        self.channels.deinit(self.allocator);
        self.socket.deinit();
    }

    pub fn local_address(self: TurnUdpSocket) !candidate.Address {
        return self.socket.local_address();
    }

    pub fn send_allocate_request(self: *TurnUdpSocket, packet_buf: []u8, transaction_id: [12]u8, options: usage_turn.AllocateRequestOptions) !usize {
        const packet = try usage_turn.build_allocate_request(packet_buf, transaction_id, options);
        return self.socket.send_to(self.server, packet);
    }

    pub fn on_allocate_success(self: *TurnUdpSocket, view: parser.MessageView, now_ms: u64, integrity_key: ?[]const u8) TurnUdpSocketError!void {
        const info = try usage_turn.parse_allocate_success_response(view, integrity_key);
        const lifetime_seconds = info.lifetime_seconds orelse 600;
        self.allocation = .{
            .relayed_address = info.relayed_address,
            .mapped_address = info.mapped_address,
            .lifetime_seconds = lifetime_seconds,
            .expires_at_ms = now_ms + @as(u64, lifetime_seconds) * 1000,
        };
    }

    pub fn on_refresh_success(self: *TurnUdpSocket, view: parser.MessageView, now_ms: u64, integrity_key: ?[]const u8) TurnUdpSocketError!void {
        const info = try usage_turn.parse_refresh_success_response(view, integrity_key);
        const lifetime_seconds = info.lifetime_seconds orelse if (self.allocation) |lease| lease.lifetime_seconds else 600;

        if (self.allocation) |*lease| {
            lease.lifetime_seconds = lifetime_seconds;
            lease.expires_at_ms = now_ms + @as(u64, lifetime_seconds) * 1000;
        } else {
            self.allocation = .{
                .relayed_address = null,
                .mapped_address = null,
                .lifetime_seconds = lifetime_seconds,
                .expires_at_ms = now_ms + @as(u64, lifetime_seconds) * 1000,
            };
        }
    }

    pub fn on_server_stun(self: *TurnUdpSocket, view: parser.MessageView, now_ms: u64, integrity_key: ?[]const u8) TurnUdpSocketError!bool {
        if (usage_turn.is_allocate_success_response(view)) {
            try self.on_allocate_success(view, now_ms, integrity_key);
            return true;
        }
        if (usage_turn.is_refresh_success_response(view)) {
            try self.on_refresh_success(view, now_ms, integrity_key);
            return true;
        }
        if (view.header.message_type == usage_turn.create_permission_success_response_type) {
            const handled = try self.on_permission_refresh_success(view.header.transaction_id, now_ms);
            return handled;
        }
        if (view.header.message_type == usage_turn.channel_bind_success_response_type) {
            const handled = try self.on_channel_bind_refresh_success(view.header.transaction_id, now_ms);
            return handled;
        }
        if (view.header.message_type == usage_turn.allocate_error_response_type or
            view.header.message_type == usage_turn.refresh_error_response_type or
            view.header.message_type == usage_turn.create_permission_error_response_type or
            view.header.message_type == usage_turn.channel_bind_error_response_type)
        {
            return try self.on_server_error(view);
        }
        return false;
    }

    pub fn has_auth_retry_required(self: *const TurnUdpSocket) bool {
        return self.auth_retry_required;
    }

    pub fn clear_auth_retry_required(self: *TurnUdpSocket) void {
        self.auth_retry_required = false;
    }

    pub fn auth_realm_value(self: *const TurnUdpSocket) ?[]const u8 {
        if (self.auth_realm.items.len == 0) return null;
        return self.auth_realm.items;
    }

    pub fn auth_nonce_value(self: *const TurnUdpSocket) ?[]const u8 {
        if (self.auth_nonce.items.len == 0) return null;
        return self.auth_nonce.items;
    }

    fn on_server_error(self: *TurnUdpSocket, view: parser.MessageView) !bool {
        const code = (try usage_turn.read_error_code(view)) orelse return false;
        _ = self.take_pending_refresh(view.header.transaction_id);

        if (code == 401 or code == 438) {
            const realm = (try usage_turn.read_realm(view)) orelse return false;
            const nonce = (try usage_turn.read_nonce(view)) orelse return false;
            try self.set_auth_challenge(realm, nonce);
            self.auth_retry_required = true;
        }

        return true;
    }

    fn set_auth_challenge(self: *TurnUdpSocket, realm: []const u8, nonce: []const u8) !void {
        self.auth_realm.clearRetainingCapacity();
        self.auth_nonce.clearRetainingCapacity();
        try self.auth_realm.appendSlice(self.allocator, realm);
        try self.auth_nonce.appendSlice(self.allocator, nonce);
    }

    pub fn note_permission_refresh_request(
        self: *TurnUdpSocket,
        transaction_id: [12]u8,
        peer: candidate.Address,
        lifetime_seconds: u32,
    ) !void {
        try self.pending_refreshes.append(self.allocator, .{
            .transaction_id = transaction_id,
            .kind = .permission,
            .peer = peer,
            .channel_number = 0,
            .lifetime_seconds = lifetime_seconds,
        });
    }

    pub fn note_channel_refresh_request(
        self: *TurnUdpSocket,
        transaction_id: [12]u8,
        channel_number: u16,
        peer: candidate.Address,
        lifetime_seconds: u32,
    ) !void {
        try self.pending_refreshes.append(self.allocator, .{
            .transaction_id = transaction_id,
            .kind = .channel,
            .peer = peer,
            .channel_number = channel_number,
            .lifetime_seconds = lifetime_seconds,
        });
    }

    fn on_permission_refresh_success(self: *TurnUdpSocket, transaction_id: [12]u8, now_ms: u64) !bool {
        const pending = self.take_pending_refresh(transaction_id) orelse return false;
        if (pending.kind != .permission) return false;
        try self.set_permission(pending.peer, now_ms, pending.lifetime_seconds);
        return true;
    }

    fn on_channel_bind_refresh_success(self: *TurnUdpSocket, transaction_id: [12]u8, now_ms: u64) !bool {
        const pending = self.take_pending_refresh(transaction_id) orelse return false;
        if (pending.kind != .channel) return false;
        try self.set_channel_binding(pending.channel_number, pending.peer, now_ms, pending.lifetime_seconds);
        return true;
    }

    fn take_pending_refresh(self: *TurnUdpSocket, transaction_id: [12]u8) ?PendingRefresh {
        var i: usize = 0;
        while (i < self.pending_refreshes.items.len) {
            const item = self.pending_refreshes.items[i];
            if (std.mem.eql(u8, &item.transaction_id, &transaction_id)) {
                _ = self.pending_refreshes.swapRemove(i);
                return item;
            }
            i += 1;
        }
        return null;
    }

    pub fn send_refresh_request(self: *TurnUdpSocket, packet_buf: []u8, transaction_id: [12]u8, lifetime_seconds: ?u32, nonce: ?[]const u8, realm: ?[]const u8, username: ?[]const u8) !usize {
        const packet = try usage_turn.build_refresh_request(packet_buf, transaction_id, lifetime_seconds, nonce, realm, username);
        return self.socket.send_to(self.server, packet);
    }

    pub fn send_create_permission_request(self: *TurnUdpSocket, packet_buf: []u8, transaction_id: [12]u8, options: usage_turn.CreatePermissionRequestOptions) !usize {
        const packet = try usage_turn.build_create_permission_request(packet_buf, transaction_id, options);
        return self.socket.send_to(self.server, packet);
    }

    pub fn set_permission(self: *TurnUdpSocket, peer: candidate.Address, now_ms: u64, lifetime_seconds: u32) !void {
        const expires_at_ms = now_ms + @as(u64, lifetime_seconds) * 1000;
        for (self.permissions.items) |*entry| {
            if (candidate.Address.eql(entry.peer, peer)) {
                entry.expires_at_ms = expires_at_ms;
                return;
            }
        }

        try self.permissions.append(self.allocator, .{
            .peer = peer,
            .expires_at_ms = expires_at_ms,
        });
    }

    pub fn send_channel_bind_request(self: *TurnUdpSocket, packet_buf: []u8, transaction_id: [12]u8, options: usage_turn.ChannelBindRequestOptions) !usize {
        const packet = try usage_turn.build_channel_bind_request(packet_buf, transaction_id, options);
        return self.socket.send_to(self.server, packet);
    }

    pub fn set_channel_binding(self: *TurnUdpSocket, channel_number: u16, peer: candidate.Address, now_ms: u64, lifetime_seconds: u32) !void {
        const expires_at_ms = now_ms + @as(u64, lifetime_seconds) * 1000;
        for (self.channels.items) |*entry| {
            if (entry.channel_number == channel_number) {
                entry.peer = peer;
                entry.expires_at_ms = expires_at_ms;
                return;
            }
        }

        try self.channels.append(self.allocator, .{
            .channel_number = channel_number,
            .peer = peer,
            .expires_at_ms = expires_at_ms,
        });
    }

    pub fn send_data_indication(self: *TurnUdpSocket, packet_buf: []u8, transaction_id: [12]u8, options: usage_turn.SendIndicationOptions) !usize {
        const packet = try usage_turn.build_send_indication(packet_buf, transaction_id, options);
        return self.socket.send_to(self.server, packet);
    }

    pub fn send_channel_data(self: *TurnUdpSocket, packet_buf: []u8, channel_number: u16, payload: []const u8) !usize {
        const frame = try channel_data.encode_frame(packet_buf, channel_number, payload, false);
        return self.socket.send_to(self.server, frame);
    }

    pub fn send_to_peer(
        self: *TurnUdpSocket,
        packet_buf: []u8,
        transaction_id: [12]u8,
        peer: candidate.Address,
        payload: []const u8,
        now_ms: u64,
    ) !usize {
        if (self.find_channel_for_peer(peer, now_ms)) |binding| {
            return self.send_channel_data(packet_buf, binding.channel_number, payload);
        }

        const stun_peer = candidate_to_stun_address(peer);
        return self.send_data_indication(packet_buf, transaction_id, .{
            .peer_address = stun_peer,
            .data = payload,
        });
    }

    pub fn recv_from_server(self: *TurnUdpSocket, recv_buf: []u8) TurnUdpSocketError!?ReceivedPacket {
        const packet = self.socket.recv_from(recv_buf) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return err,
        };

        if (!candidate.Address.eql(packet.from, self.server)) return error.UnexpectedSource;
        if (packet.bytes < 4) return error.TruncatedFrame;

        const first = recv_buf[0];
        const is_channel_data = (first & 0b1100_0000) == 0b0100_0000;
        if (is_channel_data) {
            const frame = try channel_data.decode_frame(recv_buf[0..packet.bytes], false);
            if (self.find_channel_by_number(frame.channel_number)) |binding| {
                return .{ .relayed_data = .{ .peer = binding.peer, .payload = frame.payload } };
            }
            return .{ .channel_data = frame };
        }

        const view = try parser.parse_message(recv_buf[0..packet.bytes]);
        if (usage_turn.is_data_indication(view)) {
            const data_ind = try usage_turn.parse_data_indication(view);
            return .{ .relayed_data = .{
                .peer = stun_to_candidate_address(data_ind.peer_address),
                .payload = data_ind.data,
            } };
        }

        return .{ .stun = view };
    }

    pub fn permission_count(self: TurnUdpSocket) usize {
        return self.permissions.items.len;
    }

    pub fn collect_due_permission_refreshes(self: *TurnUdpSocket, now_ms: u64, refresh_margin_ms: u64, out: []candidate.Address) usize {
        var due: usize = 0;
        for (self.permissions.items) |entry| {
            if (entry.expires_at_ms <= now_ms) continue;
            if (now_ms < entry.refresh_due_at_ms(refresh_margin_ms)) continue;
            if (due < out.len) out[due] = entry.peer;
            due += 1;
        }
        return due;
    }

    pub fn prune_expired_permissions(self: *TurnUdpSocket, now_ms: u64) usize {
        var removed: usize = 0;
        var i: usize = 0;
        while (i < self.permissions.items.len) {
            if (self.permissions.items[i].expires_at_ms > now_ms) {
                i += 1;
                continue;
            }
            _ = self.permissions.orderedRemove(i);
            removed += 1;
        }
        return removed;
    }

    pub fn channel_binding_count(self: TurnUdpSocket) usize {
        return self.channels.items.len;
    }

    pub fn collect_due_channel_refreshes(self: *TurnUdpSocket, now_ms: u64, refresh_margin_ms: u64, out: []ChannelBinding) usize {
        var due: usize = 0;
        for (self.channels.items) |entry| {
            if (entry.expires_at_ms <= now_ms) continue;
            if (now_ms < entry.refresh_due_at_ms(refresh_margin_ms)) continue;
            if (due < out.len) out[due] = entry;
            due += 1;
        }
        return due;
    }

    pub fn prune_expired_channel_bindings(self: *TurnUdpSocket, now_ms: u64) usize {
        var removed: usize = 0;
        var i: usize = 0;
        while (i < self.channels.items.len) {
            if (self.channels.items[i].expires_at_ms > now_ms) {
                i += 1;
                continue;
            }
            _ = self.channels.orderedRemove(i);
            removed += 1;
        }
        return removed;
    }

    fn find_channel_by_number(self: *const TurnUdpSocket, channel_number: u16) ?ChannelBinding {
        for (self.channels.items) |entry| {
            if (entry.channel_number == channel_number) return entry;
        }
        return null;
    }

    fn find_channel_for_peer(self: *const TurnUdpSocket, peer: candidate.Address, now_ms: u64) ?ChannelBinding {
        for (self.channels.items) |entry| {
            if (entry.expires_at_ms < now_ms) continue;
            if (candidate.Address.eql(entry.peer, peer)) return entry;
        }
        return null;
    }
};

fn candidate_to_stun_address(address: candidate.Address) address_attrs.StunAddress {
    return switch (address) {
        .ipv4 => |v4| .{ .ipv4 = .{ .port = v4.port, .ip = v4.ip } },
        .ipv6 => |v6| .{ .ipv6 = .{ .port = v6.port, .ip = v6.ip } },
    };
}

fn stun_to_candidate_address(address: address_attrs.StunAddress) candidate.Address {
    return switch (address) {
        .ipv4 => |v4| .{ .ipv4 = .{ .port = v4.port, .ip = v4.ip } },
        .ipv6 => |v6| .{ .ipv6 = .{ .port = v6.port, .ip = v6.ip } },
    };
}

test "turn udp socket sends allocate request to server" {
    var server = try udp_socket.UdpSocket.bind(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer server.deinit();
    const server_addr = try server.local_address();

    var turn = try TurnUdpSocket.init_nonblocking(std.testing.allocator, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } }, server_addr);
    defer turn.deinit();

    const tx_id = [_]u8{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 };
    var out: [256]u8 = undefined;
    _ = try turn.send_allocate_request(&out, tx_id, .{ .username = "u", .realm = "r", .nonce = "n" });

    var recv: [256]u8 = undefined;
    const got = try server.recv_from(&recv);
    const view = try parser.parse_message(recv[0..got.bytes]);
    try std.testing.expectEqual(@as(u16, usage_turn.allocate_request_type), view.header.message_type);
}

test "turn udp socket updates allocation lease from allocate success" {
    var turn = try TurnUdpSocket.init_nonblocking(
        std.testing.allocator,
        .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } },
        .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 3478 } },
    );
    defer turn.deinit();

    const tx_id = [_]u8{ 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2 };
    var packet: [128]u8 = undefined;
    var builder = try @import("../protocol/stun/encoder.zig").Builder.init(&packet, usage_turn.allocate_success_response_type, tx_id);
    var lifetime: [4]u8 = undefined;
    std.mem.writeInt(u32, &lifetime, 120, .big);
    try builder.add_attr(usage_turn.lifetime_attr_type, &lifetime);
    const bytes = try builder.finish();

    const view = try parser.parse_message(bytes);
    try turn.on_allocate_success(view, 1_000, null);

    try std.testing.expect(turn.allocation != null);
    try std.testing.expectEqual(@as(u64, 121_000), turn.allocation.?.expires_at_ms);
    try std.testing.expectEqual(@as(u64, 120_000), turn.allocation.?.refresh_due_at_ms(1_000));
}

test "turn udp socket refresh success updates allocation lease expiry" {
    var turn = try TurnUdpSocket.init_nonblocking(
        std.testing.allocator,
        .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } },
        .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 3478 } },
    );
    defer turn.deinit();

    turn.allocation = .{
        .relayed_address = null,
        .mapped_address = null,
        .lifetime_seconds = 120,
        .expires_at_ms = 121_000,
    };

    const tx_id = [_]u8{ 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 1, 2 };
    var packet: [128]u8 = undefined;
    var builder = try @import("../protocol/stun/encoder.zig").Builder.init(&packet, usage_turn.refresh_success_response_type, tx_id);
    var lifetime: [4]u8 = undefined;
    std.mem.writeInt(u32, &lifetime, 300, .big);
    try builder.add_attr(usage_turn.lifetime_attr_type, &lifetime);
    const bytes = try builder.finish();

    const view = try parser.parse_message(bytes);
    try turn.on_refresh_success(view, 2_000, null);
    try std.testing.expect(turn.allocation != null);
    try std.testing.expectEqual(@as(u32, 300), turn.allocation.?.lifetime_seconds);
    try std.testing.expectEqual(@as(u64, 302_000), turn.allocation.?.expires_at_ms);
}

test "turn udp socket applies permission and channel success responses" {
    var turn = try TurnUdpSocket.init_nonblocking(
        std.testing.allocator,
        .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } },
        .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 3478 } },
    );
    defer turn.deinit();

    const peer: candidate.Address = .{ .ipv4 = .{ .ip = .{ 203, 0, 113, 50 }, .port = 6000 } };

    const tx_perm = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    try turn.note_permission_refresh_request(tx_perm, peer, 300);
    var packet_perm: [64]u8 = undefined;
    const perm_header = @import("../protocol/stun/message.zig").Header.init(usage_turn.create_permission_success_response_type, 0, tx_perm);
    _ = try perm_header.encode(&packet_perm);
    const perm_view = try parser.parse_message(packet_perm[0..20]);
    try std.testing.expect(try turn.on_server_stun(perm_view, 5_000, null));
    try std.testing.expectEqual(@as(usize, 1), turn.permission_count());
    try std.testing.expectEqual(@as(u64, 305_000), turn.permissions.items[0].expires_at_ms);

    const tx_channel = [_]u8{ 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9 };
    try turn.note_channel_refresh_request(tx_channel, 0x4011, peer, 600);
    var packet_channel: [64]u8 = undefined;
    const channel_header = @import("../protocol/stun/message.zig").Header.init(usage_turn.channel_bind_success_response_type, 0, tx_channel);
    _ = try channel_header.encode(&packet_channel);
    const channel_view = try parser.parse_message(packet_channel[0..20]);
    try std.testing.expect(try turn.on_server_stun(channel_view, 8_000, null));
    try std.testing.expectEqual(@as(usize, 1), turn.channel_binding_count());
    try std.testing.expectEqual(@as(u64, 608_000), turn.channels.items[0].expires_at_ms);
}

test "turn udp socket captures auth challenge from stale nonce error" {
    var turn = try TurnUdpSocket.init_nonblocking(
        std.testing.allocator,
        .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } },
        .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 3478 } },
    );
    defer turn.deinit();

    const tx_id = [_]u8{ 8, 1, 8, 2, 8, 3, 8, 4, 8, 5, 8, 6 };
    var packet: [192]u8 = undefined;
    var builder = try @import("../protocol/stun/encoder.zig").Builder.init(&packet, usage_turn.refresh_error_response_type, tx_id);
    const err_438 = [_]u8{ 0x00, 0x00, 0x04, 0x26 };
    try builder.add_attr(usage_turn.error_code_attr_type, &err_438);
    try builder.add_attr(usage_turn.realm_attr_type, "example.org");
    try builder.add_attr(usage_turn.nonce_attr_type, "new-nonce");
    const bytes = try builder.finish();
    const view = try parser.parse_message(bytes);

    try std.testing.expect(try turn.on_server_stun(view, 0, null));
    try std.testing.expect(turn.has_auth_retry_required());
    try std.testing.expectEqualStrings("example.org", turn.auth_realm_value().?);
    try std.testing.expectEqualStrings("new-nonce", turn.auth_nonce_value().?);
}

test "turn udp socket sends and decodes channel data" {
    var server = try udp_socket.UdpSocket.bind(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer server.deinit();
    const server_addr = try server.local_address();

    var turn = try TurnUdpSocket.init_nonblocking(std.testing.allocator, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } }, server_addr);
    defer turn.deinit();

    var out: [256]u8 = undefined;
    _ = try turn.send_channel_data(&out, 0x4001, "hello");

    var recv: [256]u8 = undefined;
    const got = try server.recv_from(&recv);
    const frame = try channel_data.decode_frame(recv[0..got.bytes], false);
    try std.testing.expectEqual(@as(u16, 0x4001), frame.channel_number);
    try std.testing.expectEqualStrings("hello", frame.payload);
}

test "turn udp socket receives stun and channel data from server" {
    var server = try udp_socket.UdpSocket.bind(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer server.deinit();
    const server_addr = try server.local_address();

    var turn = try TurnUdpSocket.init_nonblocking(std.testing.allocator, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } }, server_addr);
    defer turn.deinit();

    const client_addr = try turn.local_address();

    var stun_packet: [20]u8 = undefined;
    const tx_id = [_]u8{ 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3 };
    const header = @import("../protocol/stun/message.zig").Header.init(usage_turn.allocate_success_response_type, 0, tx_id);
    _ = try header.encode(&stun_packet);
    _ = try server.send_to(client_addr, &stun_packet);

    var recv: [256]u8 = undefined;
    const parsed_stun = (try turn.recv_from_server(&recv)).?;
    switch (parsed_stun) {
        .stun => |view| try std.testing.expectEqual(@as(u16, usage_turn.allocate_success_response_type), view.header.message_type),
        else => return error.UnexpectedPacketType,
    }

    var frame_buf: [32]u8 = undefined;
    const frame = try channel_data.encode_frame(&frame_buf, 0x4002, "ok", false);
    _ = try server.send_to(client_addr, frame);

    const parsed_frame = (try turn.recv_from_server(&recv)).?;
    switch (parsed_frame) {
        .channel_data => |view| {
            try std.testing.expectEqual(@as(u16, 0x4002), view.channel_number);
            try std.testing.expectEqualStrings("ok", view.payload);
        },
        else => return error.UnexpectedPacketType,
    }
}

test "turn udp socket decapsulates TURN data indication as relayed data" {
    var server = try udp_socket.UdpSocket.bind(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer server.deinit();
    const server_addr = try server.local_address();

    var turn = try TurnUdpSocket.init_nonblocking(std.testing.allocator, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } }, server_addr);
    defer turn.deinit();
    const client_addr = try turn.local_address();

    const tx_id = [_]u8{ 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5 };
    const peer: address_attrs.StunAddress = .{ .ipv4 = .{ .port = 9000, .ip = .{ 203, 0, 113, 90 } } };
    var packet: [256]u8 = undefined;
    var builder = try @import("../protocol/stun/encoder.zig").Builder.init(&packet, usage_turn.data_indication_type, tx_id);
    try address_attrs.add_xor_peer_address(&builder, peer, tx_id);
    try builder.add_attr(usage_turn.data_attr_type, "hello-relay");
    const bytes = try builder.finish();
    _ = try server.send_to(client_addr, bytes);

    var recv: [256]u8 = undefined;
    const parsed = (try turn.recv_from_server(&recv)).?;
    switch (parsed) {
        .relayed_data => |data| {
            try std.testing.expectEqualStrings("hello-relay", data.payload);
            try std.testing.expectEqualDeep(stun_to_candidate_address(peer), data.peer);
        },
        else => return error.UnexpectedPacketType,
    }
}

test "turn udp socket send_to_peer prefers active channel binding" {
    var server = try udp_socket.UdpSocket.bind(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer server.deinit();
    const server_addr = try server.local_address();

    var turn = try TurnUdpSocket.init_nonblocking(std.testing.allocator, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } }, server_addr);
    defer turn.deinit();

    const peer_addr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 203, 0, 113, 91 }, .port = 5000 } };
    try turn.set_channel_binding(0x4005, peer_addr, 1_000, 60);

    const tx_id = [_]u8{ 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6 };
    var out: [256]u8 = undefined;
    _ = try turn.send_to_peer(&out, tx_id, peer_addr, "abc", 2_000);

    var recv: [256]u8 = undefined;
    const got = try server.recv_from(&recv);
    const frame = try channel_data.decode_frame(recv[0..got.bytes], false);
    try std.testing.expectEqual(@as(u16, 0x4005), frame.channel_number);
    try std.testing.expectEqualStrings("abc", frame.payload);
}

test "turn udp socket send_to_peer falls back to data indication" {
    var server = try udp_socket.UdpSocket.bind(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer server.deinit();
    const server_addr = try server.local_address();

    var turn = try TurnUdpSocket.init_nonblocking(std.testing.allocator, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } }, server_addr);
    defer turn.deinit();

    const peer_addr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 203, 0, 113, 92 }, .port = 5001 } };
    const tx_id = [_]u8{ 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7 };
    var out: [256]u8 = undefined;
    _ = try turn.send_to_peer(&out, tx_id, peer_addr, "xyz", 1_000);

    var recv: [256]u8 = undefined;
    const got = try server.recv_from(&recv);
    const view = try parser.parse_message(recv[0..got.bytes]);
    try std.testing.expectEqual(@as(u16, usage_turn.send_indication_type), view.header.message_type);
    try std.testing.expectEqualStrings("xyz", (try usage_turn.read_data_attr(view)).?);
    const peer_attr = (try address_attrs.find_xor_peer_address(view)).?;
    const parsed_peer = try address_attrs.decode_xor_address(peer_attr, view.header.transaction_id);
    try std.testing.expectEqualDeep(candidate_to_stun_address(peer_addr), parsed_peer);
}

test "turn udp socket tracks permissions and channel bindings" {
    var turn = try TurnUdpSocket.init_nonblocking(
        std.testing.allocator,
        .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } },
        .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 3478 } },
    );
    defer turn.deinit();

    const peer_a: candidate.Address = .{ .ipv4 = .{ .ip = .{ 203, 0, 113, 10 }, .port = 5000 } };
    const peer_b: candidate.Address = .{ .ipv4 = .{ .ip = .{ 203, 0, 113, 11 }, .port = 5001 } };

    try turn.set_permission(peer_a, 1000, 300);
    try turn.set_permission(peer_a, 2000, 300);
    try std.testing.expectEqual(@as(usize, 1), turn.permission_count());

    try turn.set_channel_binding(0x4001, peer_a, 1000, 600);
    try turn.set_channel_binding(0x4001, peer_b, 2000, 600);
    try std.testing.expectEqual(@as(usize, 1), turn.channel_binding_count());

    var due_permissions: [2]candidate.Address = undefined;
    const p_due = turn.collect_due_permission_refreshes(250_000, 50_000, &due_permissions);
    try std.testing.expectEqual(@as(usize, 1), p_due);
    try std.testing.expectEqualDeep(peer_a, due_permissions[0]);

    var due_channels: [2]ChannelBinding = undefined;
    const c_due = turn.collect_due_channel_refreshes(590_000, 20_000, &due_channels);
    try std.testing.expectEqual(@as(usize, 1), c_due);
    try std.testing.expectEqual(@as(u16, 0x4001), due_channels[0].channel_number);

    try std.testing.expectEqual(@as(usize, 1), turn.prune_expired_permissions(400_001));
    try std.testing.expectEqual(@as(usize, 0), turn.permission_count());
    try std.testing.expectEqual(@as(usize, 1), turn.prune_expired_channel_bindings(900_001));
    try std.testing.expectEqual(@as(usize, 0), turn.channel_binding_count());
}

test "turn udp socket due refresh collectors skip already expired entries" {
    var turn = try TurnUdpSocket.init_nonblocking(
        std.testing.allocator,
        .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } },
        .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 3478 } },
    );
    defer turn.deinit();

    const peer: candidate.Address = .{ .ipv4 = .{ .ip = .{ 203, 0, 113, 20 }, .port = 6000 } };
    try turn.set_permission(peer, 0, 1);
    try turn.set_channel_binding(0x4010, peer, 0, 1);

    var due_permissions: [2]candidate.Address = undefined;
    var due_channels: [2]ChannelBinding = undefined;
    const p_due = turn.collect_due_permission_refreshes(2_000, 60_000, &due_permissions);
    const c_due = turn.collect_due_channel_refreshes(2_000, 60_000, &due_channels);
    try std.testing.expectEqual(@as(usize, 0), p_due);
    try std.testing.expectEqual(@as(usize, 0), c_due);
}
