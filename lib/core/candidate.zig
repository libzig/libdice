const std = @import("std");

pub const CandidateType = enum {
    host,
    srflx,
    relay,
    prflx,
};

pub const Transport = enum {
    udp,
    tcp,
};

pub const TcpRole = enum {
    active,
    passive,
    sim_open,
};

pub const Address = union(enum) {
    ipv4: struct {
        ip: [4]u8,
        port: u16,
    },
    ipv6: struct {
        ip: [16]u8,
        port: u16,
    },

    pub fn eql(a: Address, b: Address) bool {
        return switch (a) {
            .ipv4 => |av4| switch (b) {
                .ipv4 => |bv4| av4.port == bv4.port and std.mem.eql(u8, &av4.ip, &bv4.ip),
                else => false,
            },
            .ipv6 => |av6| switch (b) {
                .ipv6 => |bv6| av6.port == bv6.port and std.mem.eql(u8, &av6.ip, &bv6.ip),
                else => false,
            },
        };
    }
};

pub const Candidate = struct {
    id: u64,
    component_id: u16,
    candidate_type: CandidateType,
    transport: Transport,
    foundation: u32,
    priority: u32,
    address: Address,
    base_address: ?Address = null,
    tcp_role: ?TcpRole = null,

    pub fn semantically_equal(a: Candidate, b: Candidate) bool {
        return a.component_id == b.component_id and
            a.candidate_type == b.candidate_type and
            a.transport == b.transport and
            a.tcp_role == b.tcp_role and
            Address.eql(a.address, b.address);
    }
};

pub fn tcp_roles_compatible(local_role: ?TcpRole, remote_role: ?TcpRole) bool {
    if (local_role == null or remote_role == null) return true;

    const l = local_role.?;
    const r = remote_role.?;
    return switch (l) {
        .active => r == .passive or r == .sim_open,
        .passive => r == .active or r == .sim_open,
        .sim_open => r == .active or r == .passive or r == .sim_open,
    };
}

pub fn type_preference(candidate_type: CandidateType) u8 {
    return switch (candidate_type) {
        .host => 126,
        .prflx => 110,
        .srflx => 100,
        .relay => 0,
    };
}

pub fn compute_candidate_priority(candidate_type: CandidateType, local_preference: u16, component_id: u16) u32 {
    const type_pref = @as(u32, type_preference(candidate_type));
    const lp = @as(u32, local_preference);
    const c = @as(u32, component_id);
    return (type_pref << 24) | (lp << 8) | (256 - c);
}

pub fn compute_foundation(transport: Transport, candidate_type: CandidateType, address: Address) u32 {
    var hasher = std.hash.Fnv1a_32.init();

    switch (transport) {
        .udp => hasher.update("udp"),
        .tcp => hasher.update("tcp"),
    }

    switch (candidate_type) {
        .host => hasher.update("host"),
        .srflx => hasher.update("srflx"),
        .relay => hasher.update("relay"),
        .prflx => hasher.update("prflx"),
    }

    switch (address) {
        .ipv4 => |a| {
            hasher.update(&a.ip);
            var port_buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &port_buf, a.port, .big);
            hasher.update(&port_buf);
        },
        .ipv6 => |a| {
            hasher.update(&a.ip);
            var port_buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &port_buf, a.port, .big);
            hasher.update(&port_buf);
        },
    }

    return hasher.final();
}

pub const CandidateList = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Candidate),

    pub fn init(allocator: std.mem.Allocator) CandidateList {
        return .{
            .allocator = allocator,
            .items = .empty,
        };
    }

    pub fn deinit(self: *CandidateList) void {
        self.items.deinit(self.allocator);
    }

    pub fn count(self: CandidateList) usize {
        return self.items.items.len;
    }

    pub fn clear(self: *CandidateList) void {
        self.items.clearRetainingCapacity();
    }

    pub fn add(self: *CandidateList, candidate: Candidate) !bool {
        for (self.items.items) |existing| {
            if (Candidate.semantically_equal(existing, candidate)) return false;
        }
        try self.items.append(self.allocator, candidate);
        return true;
    }

    pub fn count_for_component(self: CandidateList, component_id: u16) usize {
        var result_count: usize = 0;
        for (self.items.items) |candidate| {
            if (candidate.component_id == component_id) result_count += 1;
        }
        return result_count;
    }

    pub fn find_by_id(self: *const CandidateList, candidate_id: u64) ?Candidate {
        for (self.items.items) |item| {
            if (item.id == candidate_id) return item;
        }
        return null;
    }
};

test "candidate priority ordering by type preference" {
    const host = compute_candidate_priority(.host, 65535, 1);
    const srflx = compute_candidate_priority(.srflx, 65535, 1);
    const relay = compute_candidate_priority(.relay, 65535, 1);

    try std.testing.expect(host > srflx);
    try std.testing.expect(srflx > relay);
}

test "foundation is stable for same tuple" {
    const address: Address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 10 }, .port = 5000 } };
    const a = compute_foundation(.udp, .host, address);
    const b = compute_foundation(.udp, .host, address);
    try std.testing.expectEqual(a, b);
}

test "candidate list deduplicates semantic duplicates" {
    var list = CandidateList.init(std.testing.allocator);
    defer list.deinit();

    const address: Address = .{ .ipv4 = .{ .ip = .{ 203, 0, 113, 9 }, .port = 3478 } };

    const c1 = Candidate{
        .id = 1,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = compute_foundation(.udp, .host, address),
        .priority = compute_candidate_priority(.host, 100, 1),
        .address = address,
    };

    const c2 = Candidate{
        .id = 2,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = c1.foundation,
        .priority = c1.priority,
        .address = address,
    };

    try std.testing.expect(try list.add(c1));
    try std.testing.expect(!(try list.add(c2)));
    try std.testing.expectEqual(@as(usize, 1), list.count());
}

test "candidate list clear retains allocation and empties items" {
    var list = CandidateList.init(std.testing.allocator);
    defer list.deinit();

    const address: Address = .{ .ipv4 = .{ .ip = .{ 203, 0, 113, 10 }, .port = 3478 } };
    try std.testing.expect(try list.add(.{
        .id = 1,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = compute_foundation(.udp, .host, address),
        .priority = compute_candidate_priority(.host, 1, 1),
        .address = address,
    }));

    list.clear();
    try std.testing.expectEqual(@as(usize, 0), list.count());
}

test "candidate list find by id" {
    var list = CandidateList.init(std.testing.allocator);
    defer list.deinit();

    const address: Address = .{ .ipv4 = .{ .ip = .{ 203, 0, 113, 20 }, .port = 3478 } };
    const item = Candidate{
        .id = 42,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = compute_foundation(.udp, .host, address),
        .priority = compute_candidate_priority(.host, 1, 1),
        .address = address,
    };

    try std.testing.expect(try list.add(item));
    const found = list.find_by_id(42).?;
    try std.testing.expectEqual(@as(u64, 42), found.id);
    try std.testing.expectEqual(@as(?Candidate, null), list.find_by_id(99));
}

test "tcp role compatibility matrix" {
    try std.testing.expect(tcp_roles_compatible(.active, .passive));
    try std.testing.expect(tcp_roles_compatible(.passive, .active));
    try std.testing.expect(tcp_roles_compatible(.sim_open, .sim_open));
    try std.testing.expect(tcp_roles_compatible(.active, .sim_open));
    try std.testing.expect(!tcp_roles_compatible(.active, .active));
    try std.testing.expect(!tcp_roles_compatible(.passive, .passive));
}

test "candidate semantic equality includes tcp role" {
    const address: Address = .{ .ipv4 = .{ .ip = .{ 203, 0, 113, 31 }, .port = 9000 } };
    const a = Candidate{
        .id = 1,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .tcp,
        .foundation = compute_foundation(.tcp, .host, address),
        .priority = compute_candidate_priority(.host, 1, 1),
        .address = address,
        .tcp_role = .active,
    };
    const b = Candidate{
        .id = 2,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .tcp,
        .foundation = a.foundation,
        .priority = a.priority,
        .address = address,
        .tcp_role = .passive,
    };

    try std.testing.expect(!Candidate.semantically_equal(a, b));
}
