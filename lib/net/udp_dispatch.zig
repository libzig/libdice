const std = @import("std");
const candidate = @import("../core/candidate.zig");
const udp_socket = @import("udp_socket.zig");

pub const ReceivedPacket = struct {
    stream_id: u32,
    component_id: u16,
    from: candidate.Address,
    bytes: usize,
};

const Binding = struct {
    stream_id: u32,
    component_id: u16,
    socket: udp_socket.UdpSocket,
};

pub const UdpDispatch = struct {
    allocator: std.mem.Allocator,
    bindings: std.ArrayList(Binding),

    pub fn init(allocator: std.mem.Allocator) UdpDispatch {
        return .{
            .allocator = allocator,
            .bindings = .empty,
        };
    }

    pub fn deinit(self: *UdpDispatch) void {
        for (self.bindings.items) |*binding| {
            binding.socket.deinit();
        }
        self.bindings.deinit(self.allocator);
    }

    pub fn binding_count(self: UdpDispatch) usize {
        return self.bindings.items.len;
    }

    pub fn add_binding(
        self: *UdpDispatch,
        stream_id: u32,
        component_id: u16,
        local: candidate.Address,
    ) !candidate.Address {
        var sock = try udp_socket.UdpSocket.bind_nonblocking(local);
        errdefer sock.deinit();

        const bound = try sock.local_address();
        try self.bindings.append(self.allocator, .{
            .stream_id = stream_id,
            .component_id = component_id,
            .socket = sock,
        });

        return bound;
    }

    fn find_binding(self: *UdpDispatch, stream_id: u32, component_id: u16) ?*Binding {
        for (self.bindings.items) |*binding| {
            if (binding.stream_id == stream_id and binding.component_id == component_id) return binding;
        }
        return null;
    }

    pub fn send(
        self: *UdpDispatch,
        stream_id: u32,
        component_id: u16,
        remote: candidate.Address,
        payload: []const u8,
    ) !usize {
        const binding = self.find_binding(stream_id, component_id) orelse return error.NotFound;
        return binding.socket.send_to(remote, payload);
    }

    pub fn recv_any(self: *UdpDispatch, buf: []u8) !?ReceivedPacket {
        for (self.bindings.items) |*binding| {
            const recv = binding.socket.recv_from(buf) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };

            return .{
                .stream_id = binding.stream_id,
                .component_id = binding.component_id,
                .from = recv.from,
                .bytes = recv.bytes,
            };
        }

        return null;
    }
};

test "udp dispatch routes by stream/component binding" {
    var dispatch = UdpDispatch.init(std.testing.allocator);
    defer dispatch.deinit();

    const addr_a = try dispatch.add_binding(1, 1, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    const addr_b = try dispatch.add_binding(2, 1, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });

    _ = addr_a;
    _ = try dispatch.send(1, 1, addr_b, "hello-b");

    var buf: [128]u8 = undefined;

    var tries: usize = 0;
    while (tries < 50) : (tries += 1) {
        if (try dispatch.recv_any(&buf)) |pkt| {
            try std.testing.expectEqual(@as(u32, 2), pkt.stream_id);
            try std.testing.expectEqual(@as(u16, 1), pkt.component_id);
            try std.testing.expectEqualStrings("hello-b", buf[0..pkt.bytes]);
            return;
        }

        std.Thread.sleep(1_000_000);
    }

    try std.testing.expect(false);
}

test "udp dispatch recv_any returns null when no data" {
    var dispatch = UdpDispatch.init(std.testing.allocator);
    defer dispatch.deinit();

    _ = try dispatch.add_binding(1, 1, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });

    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(@as(?ReceivedPacket, null), try dispatch.recv_any(&buf));
}

test "udp dispatch send returns notfound for missing binding" {
    var dispatch = UdpDispatch.init(std.testing.allocator);
    defer dispatch.deinit();

    const target = candidate.Address{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 9 } };
    try std.testing.expectError(error.NotFound, dispatch.send(123, 1, target, "x"));
}
