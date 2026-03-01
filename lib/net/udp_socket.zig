const std = @import("std");
const addr_conv = @import("address.zig");
const candidate = @import("../core/candidate.zig");

pub const UdpSocket = struct {
    fd: std.posix.socket_t,
    local: std.net.Address,

    pub fn bind(local: candidate.Address) !UdpSocket {
        const std_addr = addr_conv.to_std(local);

        const domain: u32 = switch (std_addr.any.family) {
            std.posix.AF.INET => std.posix.AF.INET,
            std.posix.AF.INET6 => std.posix.AF.INET6,
            else => return error.UnsupportedAddressFamily,
        };

        const fd = try std.posix.socket(domain, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
        errdefer std.posix.close(fd);

        try std.posix.bind(fd, &std_addr.any, std_addr.getOsSockLen());

        var resolved = std.mem.zeroes(std.net.Address);
        var sock_len: std.posix.socklen_t = @sizeOf(std.net.Address);
        try std.posix.getsockname(fd, &resolved.any, &sock_len);

        return .{
            .fd = fd,
            .local = resolved,
        };
    }

    pub fn deinit(self: *UdpSocket) void {
        std.posix.close(self.fd);
    }

    pub fn local_address(self: UdpSocket) !candidate.Address {
        return try addr_conv.from_std(self.local);
    }

    pub fn send_to(self: UdpSocket, remote: candidate.Address, payload: []const u8) !usize {
        const remote_std = addr_conv.to_std(remote);
        return std.posix.sendto(self.fd, payload, 0, &remote_std.any, remote_std.getOsSockLen());
    }

    pub fn recv_from(self: UdpSocket, out: []u8) !struct { bytes: usize, from: candidate.Address } {
        var source = std.mem.zeroes(std.net.Address);
        var sock_len: std.posix.socklen_t = @sizeOf(std.net.Address);

        const bytes = try std.posix.recvfrom(self.fd, out, 0, &source.any, &sock_len);
        return .{
            .bytes = bytes,
            .from = try addr_conv.from_std(source),
        };
    }
};

test "udp sockets can exchange loopback packets" {
    var a = try UdpSocket.bind(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer a.deinit();

    var b = try UdpSocket.bind(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer b.deinit();

    const b_addr = try b.local_address();
    _ = try a.send_to(b_addr, "ping");

    var buf: [64]u8 = undefined;
    const received = try b.recv_from(&buf);
    try std.testing.expectEqual(@as(usize, 4), received.bytes);
    try std.testing.expectEqualStrings("ping", buf[0..received.bytes]);
}

test "udp socket local address contains bound port" {
    var sock = try UdpSocket.bind(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer sock.deinit();

    const addr = try sock.local_address();
    try std.testing.expect(addr.ipv4.port != 0);
}
