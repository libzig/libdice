const std = @import("std");
pub const component = @import("component.zig");
pub const candidate = @import("candidate.zig");

pub const max_ufrag_len: usize = 32;
pub const max_password_len: usize = 256;

pub const Credentials = struct {
    ufrag_buf: [max_ufrag_len]u8,
    ufrag_len: u8,
    password_buf: [max_password_len]u8,
    password_len: u16,

    pub fn from_slices(ufrag_in: []const u8, password_in: []const u8) error{CredentialTooLong}!Credentials {
        if (ufrag_in.len > max_ufrag_len or password_in.len > max_password_len) return error.CredentialTooLong;

        var creds = Credentials{
            .ufrag_buf = [_]u8{0} ** max_ufrag_len,
            .ufrag_len = @intCast(ufrag_in.len),
            .password_buf = [_]u8{0} ** max_password_len,
            .password_len = @intCast(password_in.len),
        };

        @memcpy(creds.ufrag_buf[0..ufrag_in.len], ufrag_in);
        @memcpy(creds.password_buf[0..password_in.len], password_in);
        return creds;
    }

    pub fn ufrag(self: *const Credentials) []const u8 {
        return self.ufrag_buf[0..self.ufrag_len];
    }

    pub fn password(self: *const Credentials) []const u8 {
        return self.password_buf[0..self.password_len];
    }
};

pub const Stream = struct {
    allocator: std.mem.Allocator,
    id: u32,
    components: std.ArrayList(component.Component),
    local_candidates: candidate.CandidateList,
    remote_candidates: candidate.CandidateList,
    local_credentials: ?Credentials,
    remote_credentials: ?Credentials,

    pub fn init(allocator: std.mem.Allocator, id: u32) Stream {
        return .{
            .allocator = allocator,
            .id = id,
            .components = .empty,
            .local_candidates = candidate.CandidateList.init(allocator),
            .remote_candidates = candidate.CandidateList.init(allocator),
            .local_credentials = null,
            .remote_credentials = null,
        };
    }

    pub fn deinit(self: *Stream) void {
        self.local_candidates.deinit();
        self.remote_candidates.deinit();
        self.components.deinit(self.allocator);
    }

    pub fn add_component(self: *Stream, component_id: u16) !void {
        try self.components.append(self.allocator, component.Component.init(component_id));
    }

    pub fn get_component(self: *Stream, component_id: u16) ?*component.Component {
        for (self.components.items) |*item| {
            if (item.id == component_id) return item;
        }
        return null;
    }

    pub fn component_count(self: Stream) usize {
        return self.components.items.len;
    }

    pub fn set_local_credentials(self: *Stream, ufrag: []const u8, password: []const u8) !void {
        self.local_credentials = try Credentials.from_slices(ufrag, password);
    }

    pub fn set_remote_credentials(self: *Stream, ufrag: []const u8, password: []const u8) !void {
        self.remote_credentials = try Credentials.from_slices(ufrag, password);
    }

    pub fn add_local_candidate(self: *Stream, value: candidate.Candidate) !bool {
        return self.local_candidates.add(value);
    }

    pub fn add_remote_candidate(self: *Stream, value: candidate.Candidate) !bool {
        return self.remote_candidates.add(value);
    }

    pub fn local_candidate_count(self: Stream, component_id: u16) usize {
        return self.local_candidates.count_for_component(component_id);
    }

    pub fn remote_candidate_count(self: Stream, component_id: u16) usize {
        return self.remote_candidates.count_for_component(component_id);
    }

    pub fn find_local_candidate_by_id(self: *const Stream, candidate_id: u64) ?candidate.Candidate {
        return self.local_candidates.find_by_id(candidate_id);
    }

    pub fn find_remote_candidate_by_id(self: *const Stream, candidate_id: u64) ?candidate.Candidate {
        return self.remote_candidates.find_by_id(candidate_id);
    }

    fn copy_candidates_for_component(
        self: *const Stream,
        allocator: std.mem.Allocator,
        source: *const candidate.CandidateList,
        component_filter: ?u16,
    ) ![]candidate.Candidate {
        var count: usize = 0;
        for (source.items.items) |item| {
            if (component_filter) |component_id| {
                if (item.component_id != component_id) continue;
            }
            count += 1;
        }

        var out = try allocator.alloc(candidate.Candidate, count);
        var idx: usize = 0;
        for (source.items.items) |item| {
            if (component_filter) |component_id| {
                if (item.component_id != component_id) continue;
            }
            out[idx] = item;
            idx += 1;
        }

        _ = self;
        return out;
    }

    pub fn copy_local_candidates(self: *const Stream, allocator: std.mem.Allocator, component_filter: ?u16) ![]candidate.Candidate {
        return self.copy_candidates_for_component(allocator, &self.local_candidates, component_filter);
    }

    pub fn copy_remote_candidates(self: *const Stream, allocator: std.mem.Allocator, component_filter: ?u16) ![]candidate.Candidate {
        return self.copy_candidates_for_component(allocator, &self.remote_candidates, component_filter);
    }
};

test "stream manages components" {
    var stream = Stream.init(std.testing.allocator, 5);
    defer stream.deinit();

    try stream.add_component(1);
    try stream.add_component(2);
    try std.testing.expectEqual(@as(usize, 2), stream.component_count());

    const c1 = stream.get_component(1).?;
    try std.testing.expectEqual(@as(u16, 1), c1.id);
    try std.testing.expectEqual(@as(?*component.Component, null), stream.get_component(3));
}

test "stream credentials storage" {
    var stream = Stream.init(std.testing.allocator, 1);
    defer stream.deinit();

    try stream.set_local_credentials("local_u", "local_password");
    try stream.set_remote_credentials("remote_u", "remote_password");

    try std.testing.expectEqualStrings("local_u", (&stream.local_credentials.?).ufrag());
    try std.testing.expectEqualStrings("remote_password", (&stream.remote_credentials.?).password());
}

test "credential length validation" {
    var oversized_ufrag: [33]u8 = undefined;
    @memset(&oversized_ufrag, 'u');
    try std.testing.expectError(error.CredentialTooLong, Credentials.from_slices(&oversized_ufrag, "ok"));
}

test "stream candidate storage by component" {
    var stream = Stream.init(std.testing.allocator, 3);
    defer stream.deinit();

    const a1: candidate.Address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 1 }, .port = 5000 } };
    const a2: candidate.Address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 2 }, .port = 5001 } };

    const c1 = candidate.Candidate{
        .id = 1,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .host, a1),
        .priority = candidate.compute_candidate_priority(.host, 10, 1),
        .address = a1,
    };

    const c2 = candidate.Candidate{
        .id = 2,
        .component_id = 2,
        .candidate_type = .srflx,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .srflx, a2),
        .priority = candidate.compute_candidate_priority(.srflx, 20, 2),
        .address = a2,
    };

    try std.testing.expect(try stream.add_local_candidate(c1));
    try std.testing.expect(try stream.add_remote_candidate(c2));

    try std.testing.expectEqual(@as(usize, 1), stream.local_candidate_count(1));
    try std.testing.expectEqual(@as(usize, 1), stream.remote_candidate_count(2));
    try std.testing.expectEqual(@as(usize, 0), stream.remote_candidate_count(1));
}

test "stream candidate copy helpers" {
    var stream = Stream.init(std.testing.allocator, 4);
    defer stream.deinit();

    const a1: candidate.Address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 10 }, .port = 7000 } };
    const a2: candidate.Address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 11 }, .port = 7001 } };

    try std.testing.expect(try stream.add_local_candidate(.{
        .id = 1,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .host, a1),
        .priority = candidate.compute_candidate_priority(.host, 1, 1),
        .address = a1,
    }));
    try std.testing.expect(try stream.add_local_candidate(.{
        .id = 2,
        .component_id = 2,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .host, a2),
        .priority = candidate.compute_candidate_priority(.host, 1, 2),
        .address = a2,
    }));

    const all = try stream.copy_local_candidates(std.testing.allocator, null);
    defer std.testing.allocator.free(all);
    try std.testing.expectEqual(@as(usize, 2), all.len);

    const comp2 = try stream.copy_local_candidates(std.testing.allocator, 2);
    defer std.testing.allocator.free(comp2);
    try std.testing.expectEqual(@as(usize, 1), comp2.len);
    try std.testing.expectEqual(@as(u16, 2), comp2[0].component_id);
}

test "stream find candidate by id" {
    var stream = Stream.init(std.testing.allocator, 8);
    defer stream.deinit();

    const a1: candidate.Address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 20 }, .port = 7000 } };
    const a2: candidate.Address = .{ .ipv4 = .{ .ip = .{ 198, 51, 100, 20 }, .port = 8000 } };

    try std.testing.expect(try stream.add_local_candidate(.{
        .id = 10,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .host, a1),
        .priority = candidate.compute_candidate_priority(.host, 10, 1),
        .address = a1,
    }));
    try std.testing.expect(try stream.add_remote_candidate(.{
        .id = 20,
        .component_id = 1,
        .candidate_type = .srflx,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .srflx, a2),
        .priority = candidate.compute_candidate_priority(.srflx, 10, 1),
        .address = a2,
    }));

    try std.testing.expectEqual(@as(u64, 10), stream.find_local_candidate_by_id(10).?.id);
    try std.testing.expectEqual(@as(u64, 20), stream.find_remote_candidate_by_id(20).?.id);
    try std.testing.expectEqual(@as(?candidate.Candidate, null), stream.find_local_candidate_by_id(999));
}
