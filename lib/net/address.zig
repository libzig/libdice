const std = @import("std");
const candidate = @import("../core/candidate.zig");

pub fn to_std(address: candidate.Address) std.net.Address {
    return switch (address) {
        .ipv4 => |v4| std.net.Address.initIp4(v4.ip, v4.port),
        .ipv6 => |v6| std.net.Address.initIp6(v6.ip, v6.port, 0, 0),
    };
}

pub fn from_std(address: std.net.Address) !candidate.Address {
    return switch (address.any.family) {
        std.posix.AF.INET => .{ .ipv4 = .{
            .ip = @as(*const [4]u8, @ptrCast(&address.in.sa.addr)).*,
            .port = address.in.getPort(),
        } },
        std.posix.AF.INET6 => .{ .ipv6 = .{
            .ip = address.in6.sa.addr,
            .port = address.in6.getPort(),
        } },
        else => error.UnsupportedAddressFamily,
    };
}

pub fn parse_ip_port(text: []const u8) !candidate.Address {
    const addr = try std.net.Address.parseIpAndPort(text);
    return try from_std(addr);
}

test "candidate/std address roundtrip ipv4" {
    const original: candidate.Address = .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 5000 } };
    const std_addr = to_std(original);
    const converted = try from_std(std_addr);
    try std.testing.expect(candidate.Address.eql(original, converted));
}

test "candidate/std address roundtrip ipv6" {
    const original: candidate.Address = .{ .ipv6 = .{ .ip = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, .port = 5050 } };
    const std_addr = to_std(original);
    const converted = try from_std(std_addr);
    try std.testing.expect(candidate.Address.eql(original, converted));
}

test "parse ip port helper" {
    const a = try parse_ip_port("127.0.0.1:3478");
    try std.testing.expectEqual(@as(u16, 3478), a.ipv4.port);
}
