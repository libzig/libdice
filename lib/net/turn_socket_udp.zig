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
};

pub const ChannelBinding = struct {
    channel_number: u16,
    peer: candidate.Address,
    expires_at_ms: u64,
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
};

pub const TurnUdpSocketError = parser.ParserError || channel_data.ChannelDataError || usage_turn.TurnError || error{
    UnexpectedSource,
};

pub const TurnUdpSocket = struct {
    allocator: std.mem.Allocator,
    socket: udp_socket.UdpSocket,
    server: candidate.Address,
    allocation: ?AllocationLease,
    permissions: std.ArrayList(Permission),
    channels: std.ArrayList(ChannelBinding),

    pub fn init_nonblocking(allocator: std.mem.Allocator, local_bind: candidate.Address, server: candidate.Address) !TurnUdpSocket {
        return .{
            .allocator = allocator,
            .socket = try udp_socket.UdpSocket.bind_nonblocking(local_bind),
            .server = server,
            .allocation = null,
            .permissions = .empty,
            .channels = .empty,
        };
    }

    pub fn deinit(self: *TurnUdpSocket) void {
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
            return .{ .channel_data = try channel_data.decode_frame(recv_buf[0..packet.bytes], false) };
        }

        return .{ .stun = try parser.parse_message(recv_buf[0..packet.bytes]) };
    }

    pub fn permission_count(self: TurnUdpSocket) usize {
        return self.permissions.items.len;
    }

    pub fn channel_binding_count(self: TurnUdpSocket) usize {
        return self.channels.items.len;
    }
};

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
}
