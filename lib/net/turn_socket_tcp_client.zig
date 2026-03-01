const std = @import("std");
const candidate = @import("../core/candidate.zig");
const tcp_candidate_socket = @import("tcp_candidate_socket.zig");
const turn_tcp = @import("turn_socket_tcp.zig");
const usage_turn = @import("../protocol/stun/usage_turn.zig");
const address_attrs = @import("../protocol/stun/address_attrs.zig");

pub const TurnTcpClient = struct {
    allocator: std.mem.Allocator,
    stream: tcp_candidate_socket.TcpStream,
    framer: turn_tcp.TurnTcpFramer,
    server: candidate.Address,

    pub fn connect_nonblocking(allocator: std.mem.Allocator, server: candidate.Address) !TurnTcpClient {
        return .{
            .allocator = allocator,
            .stream = try tcp_candidate_socket.TcpStream.connect_nonblocking(server),
            .framer = turn_tcp.TurnTcpFramer.init(allocator),
            .server = server,
        };
    }

    pub fn deinit(self: *TurnTcpClient) void {
        self.framer.deinit();
        self.stream.deinit();
    }

    pub fn local_address(self: TurnTcpClient) candidate.Address {
        return self.stream.local_address();
    }

    pub fn send_payload(self: *TurnTcpClient, frame_buf: []u8, payload: []const u8) !usize {
        const frame = try turn_tcp.encode_framed_payload(frame_buf, payload);
        return self.stream.send(frame);
    }

    pub fn send_to_peer(
        self: *TurnTcpClient,
        frame_buf: []u8,
        packet_buf: []u8,
        transaction_id: [12]u8,
        peer: candidate.Address,
        payload: []const u8,
    ) !usize {
        const packet = try usage_turn.build_send_indication(packet_buf, transaction_id, .{
            .peer_address = candidate_to_stun_address(peer),
            .data = payload,
        });
        return self.send_payload(frame_buf, packet);
    }

    pub fn pump_read(self: *TurnTcpClient, recv_buf: []u8) !usize {
        const bytes = self.stream.recv(recv_buf) catch |err| switch (err) {
            error.WouldBlock => return 0,
            else => return err,
        };

        if (bytes > 0) {
            try self.framer.push(recv_buf[0..bytes]);
        }
        return bytes;
    }

    pub fn pop_packet(self: *TurnTcpClient, out_payload: []u8) !?turn_tcp.TurnTcpPacket {
        return self.framer.pop_packet(out_payload);
    }
};

fn candidate_to_stun_address(address: candidate.Address) address_attrs.StunAddress {
    return switch (address) {
        .ipv4 => |v4| .{ .ipv4 = .{ .port = v4.port, .ip = v4.ip } },
        .ipv6 => |v6| .{ .ipv6 = .{ .port = v6.port, .ip = v6.ip } },
    };
}

test "turn tcp client sends framed payload to server" {
    var listener = try tcp_candidate_socket.TcpListener.bind_nonblocking(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } }, 8);
    defer listener.deinit();

    var client = try TurnTcpClient.connect_nonblocking(std.testing.allocator, listener.local_address());
    defer client.deinit();

    var server_stream: ?tcp_candidate_socket.TcpStream = null;
    var i: usize = 0;
    while (i < 200 and server_stream == null) : (i += 1) {
        server_stream = try listener.accept_nonblocking();
    }
    try std.testing.expect(server_stream != null);
    var server = server_stream.?;
    defer server.deinit();

    var stun: [20]u8 = undefined;
    const tx = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    _ = try @import("../protocol/stun/message.zig").Header.init(0x0101, 0, tx).encode(&stun);

    var frame_buf: [64]u8 = undefined;
    _ = try client.send_payload(&frame_buf, &stun);

    var recv: [64]u8 = undefined;
    var got: ?usize = null;
    i = 0;
    while (i < 200 and got == null) : (i += 1) {
        const n = server.recv(&recv) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        got = n;
    }
    try std.testing.expect(got != null);

    const frame_len = std.mem.readInt(u16, recv[0..2], .big);
    try std.testing.expectEqual(@as(u16, 20), frame_len);
}

test "turn tcp client receives framed packet from server" {
    var listener = try tcp_candidate_socket.TcpListener.bind_nonblocking(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } }, 8);
    defer listener.deinit();

    var client = try TurnTcpClient.connect_nonblocking(std.testing.allocator, listener.local_address());
    defer client.deinit();

    var server_stream: ?tcp_candidate_socket.TcpStream = null;
    var i: usize = 0;
    while (i < 200 and server_stream == null) : (i += 1) {
        server_stream = try listener.accept_nonblocking();
    }
    try std.testing.expect(server_stream != null);
    var server = server_stream.?;
    defer server.deinit();

    var channel: [32]u8 = undefined;
    const payload = try @import("../protocol/turn/channel_data.zig").encode_frame(&channel, 0x4001, "abc", false);
    var framed: [64]u8 = undefined;
    const frame = try turn_tcp.encode_framed_payload(&framed, payload);
    _ = try server.send(frame);

    var recv: [64]u8 = undefined;
    var out_payload: [64]u8 = undefined;
    var packet: ?turn_tcp.TurnTcpPacket = null;
    i = 0;
    while (i < 200 and packet == null) : (i += 1) {
        _ = try client.pump_read(&recv);
        packet = try client.pop_packet(&out_payload);
    }
    try std.testing.expect(packet != null);
    switch (packet.?) {
        .channel_data => |view| {
            try std.testing.expectEqual(@as(u16, 0x4001), view.channel_number);
            try std.testing.expectEqualStrings("abc", view.payload);
        },
        else => return error.UnexpectedPacketType,
    }
}

test "turn tcp client send_to_peer wraps payload in send indication frame" {
    var listener = try tcp_candidate_socket.TcpListener.bind_nonblocking(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } }, 8);
    defer listener.deinit();

    var client = try TurnTcpClient.connect_nonblocking(std.testing.allocator, listener.local_address());
    defer client.deinit();

    var server_stream: ?tcp_candidate_socket.TcpStream = null;
    var i: usize = 0;
    while (i < 200 and server_stream == null) : (i += 1) {
        server_stream = try listener.accept_nonblocking();
    }
    try std.testing.expect(server_stream != null);
    var server = server_stream.?;
    defer server.deinit();

    var frame_buf: [256]u8 = undefined;
    var packet_buf: [256]u8 = undefined;
    const tx = [_]u8{ 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 1, 2 };
    const peer: candidate.Address = .{ .ipv4 = .{ .ip = .{ 203, 0, 113, 30 }, .port = 5000 } };
    _ = try client.send_to_peer(&frame_buf, &packet_buf, tx, peer, "hello");

    var recv: [256]u8 = undefined;
    var got: ?usize = null;
    i = 0;
    while (i < 200 and got == null) : (i += 1) {
        const n = server.recv(&recv) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        got = n;
    }
    try std.testing.expect(got != null);

    const frame_len = std.mem.readInt(u16, recv[0..2], .big);
    const view = try @import("../protocol/stun/parser.zig").parse_message(recv[2 .. 2 + frame_len]);
    try std.testing.expectEqual(@as(u16, usage_turn.send_indication_type), view.header.message_type);
    try std.testing.expectEqualStrings("hello", (try usage_turn.read_data_attr(view)).?);
}
