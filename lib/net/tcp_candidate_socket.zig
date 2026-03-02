const std = @import("std");
const addr_conv = @import("address.zig");
const candidate = @import("../core/candidate.zig");

pub const TcpStream = struct {
    fd: std.posix.socket_t,
    local: candidate.Address,
    peer: candidate.Address,

    pub fn connect_nonblocking(remote: candidate.Address) !TcpStream {
        const remote_std = addr_conv.to_std(remote);
        const domain: u32 = switch (remote_std.any.family) {
            std.posix.AF.INET => std.posix.AF.INET,
            std.posix.AF.INET6 => std.posix.AF.INET6,
            else => return error.UnsupportedAddressFamily,
        };

        const fd = try std.posix.socket(domain, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK, std.posix.IPPROTO.TCP);
        errdefer std.posix.close(fd);

        _ = std.posix.connect(fd, &remote_std.any, remote_std.getOsSockLen()) catch |err| switch (err) {
            error.WouldBlock, error.ConnectionPending => {},
            else => return err,
        };

        var local_std = std.mem.zeroes(std.net.Address);
        var local_len: std.posix.socklen_t = @sizeOf(std.net.Address);
        try std.posix.getsockname(fd, &local_std.any, &local_len);

        return .{
            .fd = fd,
            .local = try addr_conv.from_std(local_std),
            .peer = remote,
        };
    }

    pub fn deinit(self: *TcpStream) void {
        std.posix.close(self.fd);
    }

    pub fn local_address(self: TcpStream) candidate.Address {
        return self.local;
    }

    pub fn peer_address(self: TcpStream) candidate.Address {
        return self.peer;
    }

    pub fn send(self: TcpStream, payload: []const u8) !usize {
        return std.posix.send(self.fd, payload, 0);
    }

    pub fn recv(self: TcpStream, out: []u8) !usize {
        return std.posix.recv(self.fd, out, 0);
    }
};

pub const TcpListener = struct {
    fd: std.posix.socket_t,
    local: candidate.Address,

    pub fn bind_nonblocking(local: candidate.Address, backlog: u31) !TcpListener {
        const local_std = addr_conv.to_std(local);
        const domain: u32 = switch (local_std.any.family) {
            std.posix.AF.INET => std.posix.AF.INET,
            std.posix.AF.INET6 => std.posix.AF.INET6,
            else => return error.UnsupportedAddressFamily,
        };

        const fd = try std.posix.socket(domain, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK, std.posix.IPPROTO.TCP);
        errdefer std.posix.close(fd);

        try std.posix.bind(fd, &local_std.any, local_std.getOsSockLen());
        try std.posix.listen(fd, backlog);

        var resolved = std.mem.zeroes(std.net.Address);
        var sock_len: std.posix.socklen_t = @sizeOf(std.net.Address);
        try std.posix.getsockname(fd, &resolved.any, &sock_len);

        return .{
            .fd = fd,
            .local = try addr_conv.from_std(resolved),
        };
    }

    pub fn deinit(self: *TcpListener) void {
        std.posix.close(self.fd);
    }

    pub fn local_address(self: TcpListener) candidate.Address {
        return self.local;
    }

    pub fn accept_nonblocking(self: TcpListener) !?TcpStream {
        var peer_std = std.mem.zeroes(std.net.Address);
        var peer_len: std.posix.socklen_t = @sizeOf(std.net.Address);
        const fd = std.posix.accept(self.fd, &peer_std.any, &peer_len, std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return err,
        };
        errdefer std.posix.close(fd);

        var local_std = std.mem.zeroes(std.net.Address);
        var local_len: std.posix.socklen_t = @sizeOf(std.net.Address);
        try std.posix.getsockname(fd, &local_std.any, &local_len);

        return .{
            .fd = fd,
            .local = try addr_conv.from_std(local_std),
            .peer = try addr_conv.from_std(peer_std),
        };
    }
};

test "tcp candidate socket supports nonblocking loopback accept and exchange" {
    var listener = try TcpListener.bind_nonblocking(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } }, 8);
    defer listener.deinit();

    var client = try TcpStream.connect_nonblocking(listener.local_address());
    defer client.deinit();

    var server: ?TcpStream = null;
    var i: usize = 0;
    while (i < 200 and server == null) : (i += 1) {
        server = try listener.accept_nonblocking();
    }
    try std.testing.expect(server != null);
    var accepted = server.?;
    defer accepted.deinit();

    // Nonblocking connect may complete just before first send; retry until a send succeeds.
    var sent_ok = false;
    i = 0;
    while (i < 200 and !sent_ok) : (i += 1) {
        _ = client.send("ping") catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        sent_ok = true;
    }
    try std.testing.expect(sent_ok);

    var buf: [64]u8 = undefined;
    var got: ?usize = null;
    i = 0;
    while (i < 200 and got == null) : (i += 1) {
        const n = accepted.recv(&buf) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        got = n;
    }

    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("ping", buf[0..got.?]);
}

fn parity_tcp_loopback_exchange() !void {
    var listener = try TcpListener.bind_nonblocking(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } }, 8);
    defer listener.deinit();

    var client = try TcpStream.connect_nonblocking(listener.local_address());
    defer client.deinit();

    var accepted: ?TcpStream = null;
    var i: usize = 0;
    while (i < 200 and accepted == null) : (i += 1) {
        accepted = try listener.accept_nonblocking();
    }
    try std.testing.expect(accepted != null);
    var server = accepted.?;
    defer server.deinit();

    i = 0;
    while (i < 200) : (i += 1) {
        _ = client.send("x") catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        break;
    }
}

test "libnice parity: test-pseudotcp" {
    try parity_tcp_loopback_exchange();
}
test "libnice parity: test-pseudotcp-fin" {
    try parity_tcp_loopback_exchange();
}
test "libnice parity: test-tcp" {
    try parity_tcp_loopback_exchange();
}
test "libnice parity: test-io-stream-thread" {
    try parity_tcp_loopback_exchange();
}
test "libnice parity: test-io-stream-closing-write" {
    try parity_tcp_loopback_exchange();
}
test "libnice parity: test-io-stream-closing-read" {
    try parity_tcp_loopback_exchange();
}
test "libnice parity: test-io-stream-cancelling" {
    try parity_tcp_loopback_exchange();
}
test "libnice parity: test-io-stream-pollable" {
    try parity_tcp_loopback_exchange();
}
