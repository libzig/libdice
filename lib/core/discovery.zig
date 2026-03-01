const std = @import("std");
const candidate = @import("candidate.zig");

pub const InterfaceAddress = struct {
    address: candidate.Address,
    transport: candidate.Transport = .udp,
    local_preference: u16 = 65535,
};

pub const GatherResult = struct {
    candidates: []candidate.Candidate,
    next_candidate_id: u64,

    pub fn deinit(self: GatherResult, allocator: std.mem.Allocator) void {
        allocator.free(self.candidates);
    }
};

fn is_ipv6(address: candidate.Address) bool {
    return switch (address) {
        .ipv4 => false,
        .ipv6 => true,
    };
}

pub fn gather_host_candidates(
    allocator: std.mem.Allocator,
    stream_id: u32,
    interfaces: []const InterfaceAddress,
    component_ids: []const u16,
    next_candidate_id_start: u64,
    include_ipv6: bool,
) !GatherResult {
    const max_count: usize = interfaces.len * component_ids.len;
    var out = try allocator.alloc(candidate.Candidate, max_count);
    errdefer allocator.free(out);

    var next_id = next_candidate_id_start;
    var written: usize = 0;

    _ = stream_id;

    for (component_ids) |component_id| {
        for (interfaces) |iface| {
            if (!include_ipv6 and is_ipv6(iface.address)) continue;

            const foundation = candidate.compute_foundation(iface.transport, .host, iface.address);
            const prio = candidate.compute_candidate_priority(.host, iface.local_preference, component_id);

            out[written] = .{
                .id = next_id,
                .component_id = component_id,
                .candidate_type = .host,
                .transport = iface.transport,
                .foundation = foundation,
                .priority = prio,
                .address = iface.address,
                .base_address = iface.address,
            };

            written += 1;
            next_id += 1;
        }
    }

    if (written < out.len) {
        out = try allocator.realloc(out, written);
    }

    return .{
        .candidates = out,
        .next_candidate_id = next_id,
    };
}

test "host discovery gathers one candidate per interface x component" {
    const interfaces = [_]InterfaceAddress{
        .{ .address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 10 }, .port = 5000 } }, .local_preference = 100 },
        .{ .address = .{ .ipv6 = .{ .ip = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, .port = 5001 } }, .local_preference = 90 },
    };
    const components = [_]u16{ 1, 2 };

    const result = try gather_host_candidates(std.testing.allocator, 1, &interfaces, &components, 10, true);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), result.candidates.len);
    try std.testing.expectEqual(@as(u64, 14), result.next_candidate_id);
    try std.testing.expectEqual(@as(u64, 10), result.candidates[0].id);
    try std.testing.expectEqual(@as(u16, 1), result.candidates[0].component_id);
    try std.testing.expectEqual(candidate.CandidateType.host, result.candidates[0].candidate_type);
}

test "host discovery can skip ipv6 addresses" {
    const interfaces = [_]InterfaceAddress{
        .{ .address = .{ .ipv4 = .{ .ip = .{ 198, 51, 100, 20 }, .port = 7000 } } },
        .{ .address = .{ .ipv6 = .{ .ip = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 }, .port = 7001 } } },
    };
    const components = [_]u16{1};

    const result = try gather_host_candidates(std.testing.allocator, 2, &interfaces, &components, 30, false);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.candidates.len);
    try std.testing.expectEqual(@as(u64, 31), result.next_candidate_id);
    try std.testing.expectEqual(candidate.Transport.udp, result.candidates[0].transport);
}
