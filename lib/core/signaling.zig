const std = @import("std");
const stream_mod = @import("stream.zig");
const candidate = @import("candidate.zig");

pub const StreamDescription = struct {
    stream_id: u32,
    credentials: ?stream_mod.Credentials,
    candidates: []candidate.Candidate,

    pub fn deinit(self: *StreamDescription, allocator: std.mem.Allocator) void {
        allocator.free(self.candidates);
        self.candidates = &[_]candidate.Candidate{};
    }
};

pub const RemoteDescription = struct {
    credentials: ?stream_mod.Credentials = null,
    candidates: []const candidate.Candidate = &[_]candidate.Candidate{},
};

pub const ApplySummary = struct {
    credentials_updated: bool,
    candidates_processed: usize,
    candidates_added: usize,
};

pub fn build_local_description(
    allocator: std.mem.Allocator,
    stream: *const stream_mod.Stream,
    component_filter: ?u16,
) !StreamDescription {
    const local_candidates = try stream.copy_local_candidates(allocator, component_filter);

    return .{
        .stream_id = stream.id,
        .credentials = stream.local_credentials,
        .candidates = local_candidates,
    };
}

pub fn apply_remote_description(
    stream: *stream_mod.Stream,
    remote: RemoteDescription,
) !ApplySummary {
    var credentials_updated = false;
    if (remote.credentials) |creds| {
        stream.remote_credentials = creds;
        credentials_updated = true;
    }

    var candidates_added: usize = 0;
    for (remote.candidates) |value| {
        if (try stream.add_remote_candidate(value)) candidates_added += 1;
    }

    return .{
        .credentials_updated = credentials_updated,
        .candidates_processed = remote.candidates.len,
        .candidates_added = candidates_added,
    };
}

test "build local description returns credentials and filtered candidates" {
    var stream = stream_mod.Stream.init(std.testing.allocator, 10);
    defer stream.deinit();
    try stream.add_component(1);
    try stream.add_component(2);
    try stream.set_local_credentials("ufragA", "pwdA");

    const c1_addr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 1 }, .port = 5000 } };
    const c2_addr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 2 }, .port = 5001 } };
    try std.testing.expect(try stream.add_local_candidate(.{
        .id = 1,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .host, c1_addr),
        .priority = candidate.compute_candidate_priority(.host, 10, 1),
        .address = c1_addr,
    }));
    try std.testing.expect(try stream.add_local_candidate(.{
        .id = 2,
        .component_id = 2,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .host, c2_addr),
        .priority = candidate.compute_candidate_priority(.host, 10, 2),
        .address = c2_addr,
    }));

    var desc = try build_local_description(std.testing.allocator, &stream, 1);
    defer desc.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 10), desc.stream_id);
    try std.testing.expectEqualStrings("ufragA", (&desc.credentials.?).ufrag());
    try std.testing.expectEqual(@as(usize, 1), desc.candidates.len);
    try std.testing.expectEqual(@as(u16, 1), desc.candidates[0].component_id);
}

test "apply remote description updates creds and dedupes candidates" {
    var stream = stream_mod.Stream.init(std.testing.allocator, 11);
    defer stream.deinit();
    try stream.add_component(1);

    const addr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 198, 51, 100, 10 }, .port = 6000 } };
    const remote_candidate = candidate.Candidate{
        .id = 100,
        .component_id = 1,
        .candidate_type = .srflx,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .srflx, addr),
        .priority = candidate.compute_candidate_priority(.srflx, 20, 1),
        .address = addr,
    };

    const creds = try stream_mod.Credentials.from_slices("ufragB", "pwdB");
    const remote = RemoteDescription{
        .credentials = creds,
        .candidates = &[_]candidate.Candidate{ remote_candidate, remote_candidate },
    };

    const summary = try apply_remote_description(&stream, remote);
    try std.testing.expect(summary.credentials_updated);
    try std.testing.expectEqual(@as(usize, 2), summary.candidates_processed);
    try std.testing.expectEqual(@as(usize, 1), summary.candidates_added);
    try std.testing.expectEqualStrings("ufragB", (&stream.remote_credentials.?).ufrag());
    try std.testing.expectEqual(@as(usize, 1), stream.remote_candidate_count(1));
}

test "apply remote description preserves tcp role" {
    var stream = stream_mod.Stream.init(std.testing.allocator, 12);
    defer stream.deinit();
    try stream.add_component(1);

    const addr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 198, 51, 100, 22 }, .port = 7000 } };
    const remote_candidate = candidate.Candidate{
        .id = 200,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .tcp,
        .foundation = candidate.compute_foundation(.tcp, .host, addr),
        .priority = candidate.compute_candidate_priority(.host, 30, 1),
        .address = addr,
        .tcp_role = .active,
    };

    const summary = try apply_remote_description(&stream, .{ .candidates = &[_]candidate.Candidate{remote_candidate} });
    try std.testing.expectEqual(@as(usize, 1), summary.candidates_added);
    const stored = stream.find_remote_candidate_by_id(200).?;
    try std.testing.expectEqual(candidate.TcpRole.active, stored.tcp_role.?);
}
