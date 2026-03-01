const std = @import("std");
const stream_mod = @import("stream.zig");
const candidate = @import("candidate.zig");
const discovery = @import("discovery.zig");
const stream_connectivity = @import("stream_connectivity.zig");
const pair_builder = @import("pair_builder.zig");

pub const GatherSummary = struct {
    generated: usize,
    added: usize,
    next_candidate_id: u64,
};

pub const PairBuildSummary = pair_builder.PairBuildSummary;

pub const Agent = struct {
    allocator: std.mem.Allocator,
    streams: std.ArrayList(stream_mod.Stream),
    next_stream_id: u32,

    pub fn init(allocator: std.mem.Allocator) Agent {
        return .{
            .allocator = allocator,
            .streams = .empty,
            .next_stream_id = 1,
        };
    }

    pub fn deinit(self: *Agent) void {
        for (self.streams.items) |*stream| {
            stream.deinit();
        }
        self.streams.deinit(self.allocator);
    }

    pub fn stream_count(self: Agent) usize {
        return self.streams.items.len;
    }

    pub fn add_stream(self: *Agent, component_count: u16) !u32 {
        const stream_id = self.next_stream_id;
        self.next_stream_id += 1;

        var stream = stream_mod.Stream.init(self.allocator, stream_id);
        errdefer stream.deinit();

        var component_id: u16 = 1;
        while (component_id <= component_count) : (component_id += 1) {
            try stream.add_component(component_id);
        }

        try self.streams.append(self.allocator, stream);
        return stream_id;
    }

    pub fn get_stream(self: *Agent, stream_id: u32) ?*stream_mod.Stream {
        for (self.streams.items) |*stream| {
            if (stream.id == stream_id) return stream;
        }
        return null;
    }

    pub fn remove_stream(self: *Agent, stream_id: u32) bool {
        for (self.streams.items, 0..) |*stream, idx| {
            if (stream.id == stream_id) {
                stream.deinit();
                _ = self.streams.swapRemove(idx);
                return true;
            }
        }
        return false;
    }

    pub fn get_component(self: *Agent, stream_id: u32, component_id: u16) ?*stream_mod.component.Component {
        const stream = self.get_stream(stream_id) orelse return null;
        return stream.get_component(component_id);
    }

    pub fn set_remote_credentials(self: *Agent, stream_id: u32, ufrag: []const u8, password: []const u8) !void {
        const stream = self.get_stream(stream_id) orelse return error.NotFound;
        try stream.set_remote_credentials(ufrag, password);
    }

    pub fn add_local_candidate(self: *Agent, stream_id: u32, value: candidate.Candidate) !bool {
        const stream = self.get_stream(stream_id) orelse return error.NotFound;
        return stream.add_local_candidate(value);
    }

    pub fn add_remote_candidate(self: *Agent, stream_id: u32, value: candidate.Candidate) !bool {
        const stream = self.get_stream(stream_id) orelse return error.NotFound;
        return stream.add_remote_candidate(value);
    }

    pub fn local_candidate_count(self: *Agent, stream_id: u32, component_id: u16) !usize {
        const stream = self.get_stream(stream_id) orelse return error.NotFound;
        return stream.local_candidate_count(component_id);
    }

    pub fn remote_candidate_count(self: *Agent, stream_id: u32, component_id: u16) !usize {
        const stream = self.get_stream(stream_id) orelse return error.NotFound;
        return stream.remote_candidate_count(component_id);
    }

    pub fn gather_host_candidates(
        self: *Agent,
        stream_id: u32,
        interfaces: []const discovery.InterfaceAddress,
        component_ids: []const u16,
        next_candidate_id_start: u64,
        include_ipv6: bool,
    ) !GatherSummary {
        const stream = self.get_stream(stream_id) orelse return error.NotFound;

        for (component_ids) |component_id| {
            if (stream.get_component(component_id) == null) return error.InvalidComponent;
        }

        const gathered = try discovery.gather_host_candidates(
            self.allocator,
            stream_id,
            interfaces,
            component_ids,
            next_candidate_id_start,
            include_ipv6,
        );
        defer gathered.deinit(self.allocator);

        var added: usize = 0;
        for (gathered.candidates) |item| {
            if (try stream.add_local_candidate(item)) added += 1;
        }

        return .{
            .generated = gathered.candidates.len,
            .added = added,
            .next_candidate_id = gathered.next_candidate_id,
        };
    }

    pub fn populate_stream_checklists(
        self: *Agent,
        stream_id: u32,
        runtime: *stream_connectivity.StreamConnectivityRuntime,
        controlling: bool,
        start_pair_id: u64,
    ) !PairBuildSummary {
        const target = self.get_stream(stream_id) orelse return error.NotFound;
        return pair_builder.populate_stream_checklists(target, runtime, controlling, start_pair_id);
    }
};

test "agent manages stream lifecycle" {
    var agent = Agent.init(std.testing.allocator);
    defer agent.deinit();

    const s1 = try agent.add_stream(2);
    const s2 = try agent.add_stream(1);
    try std.testing.expectEqual(@as(usize, 2), agent.stream_count());

    const stream_1 = agent.get_stream(s1).?;
    try std.testing.expectEqual(@as(usize, 2), stream_1.component_count());

    try std.testing.expect(agent.remove_stream(s2));
    try std.testing.expectEqual(@as(usize, 1), agent.stream_count());
    try std.testing.expect(!agent.remove_stream(999));
}

test "agent component and credential access" {
    var agent = Agent.init(std.testing.allocator);
    defer agent.deinit();

    const stream_id = try agent.add_stream(2);
    const component = agent.get_component(stream_id, 2).?;
    try std.testing.expectEqual(@as(u16, 2), component.id);

    try agent.set_remote_credentials(stream_id, "ru", "rp");
    const stream = agent.get_stream(stream_id).?;
    try std.testing.expectEqualStrings("ru", (&stream.remote_credentials.?).ufrag());
    try std.testing.expectError(error.NotFound, agent.set_remote_credentials(404, "u", "p"));
}

test "agent candidate routing to stream" {
    var agent = Agent.init(std.testing.allocator);
    defer agent.deinit();

    const stream_id = try agent.add_stream(1);
    const addr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 203, 0, 113, 8 }, .port = 6000 } };
    const local = candidate.Candidate{
        .id = 1,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .host, addr),
        .priority = candidate.compute_candidate_priority(.host, 1, 1),
        .address = addr,
    };
    const remote = candidate.Candidate{
        .id = 2,
        .component_id = 1,
        .candidate_type = .srflx,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .srflx, addr),
        .priority = candidate.compute_candidate_priority(.srflx, 2, 1),
        .address = addr,
    };

    try std.testing.expect(try agent.add_local_candidate(stream_id, local));
    try std.testing.expect(try agent.add_remote_candidate(stream_id, remote));
    try std.testing.expectEqual(@as(usize, 1), try agent.local_candidate_count(stream_id, 1));
    try std.testing.expectEqual(@as(usize, 1), try agent.remote_candidate_count(stream_id, 1));
    try std.testing.expectError(error.NotFound, agent.local_candidate_count(999, 1));
}

test "agent host candidate gathering and dedupe" {
    var agent = Agent.init(std.testing.allocator);
    defer agent.deinit();

    const stream_id = try agent.add_stream(2);
    const interfaces = [_]discovery.InterfaceAddress{
        .{ .address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 30 }, .port = 5000 } }, .local_preference = 10 },
        .{ .address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 31 }, .port = 5001 } }, .local_preference = 11 },
    };
    const component_ids = [_]u16{ 1, 2 };

    const first = try agent.gather_host_candidates(stream_id, &interfaces, &component_ids, 100, true);
    try std.testing.expectEqual(@as(usize, 4), first.generated);
    try std.testing.expectEqual(@as(usize, 4), first.added);
    try std.testing.expectEqual(@as(u64, 104), first.next_candidate_id);

    const second = try agent.gather_host_candidates(stream_id, &interfaces, &component_ids, first.next_candidate_id, true);
    try std.testing.expectEqual(@as(usize, 4), second.generated);
    try std.testing.expectEqual(@as(usize, 0), second.added);

    try std.testing.expectEqual(@as(usize, 2), try agent.local_candidate_count(stream_id, 1));
    try std.testing.expectEqual(@as(usize, 2), try agent.local_candidate_count(stream_id, 2));
}

test "agent populates runtime checklists from stream candidates" {
    var agent = Agent.init(std.testing.allocator);
    defer agent.deinit();

    const stream_id = try agent.add_stream(1);
    const interfaces = [_]discovery.InterfaceAddress{
        .{ .address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 41 }, .port = 5100 } } },
    };
    const component_ids = [_]u16{1};
    _ = try agent.gather_host_candidates(stream_id, &interfaces, &component_ids, 100, true);

    const remote_addr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 198, 51, 100, 41 }, .port = 6100 } };
    try std.testing.expect(try agent.add_remote_candidate(stream_id, .{
        .id = 900,
        .component_id = 1,
        .candidate_type = .srflx,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .srflx, remote_addr),
        .priority = candidate.compute_candidate_priority(.srflx, 100, 1),
        .address = remote_addr,
    }));

    var runtime = try stream_connectivity.StreamConnectivityRuntime.init(std.testing.allocator, stream_id, &component_ids, .{}, .{});
    defer runtime.deinit();

    const summary = try agent.populate_stream_checklists(stream_id, &runtime, true, 2000);
    try std.testing.expectEqual(@as(usize, 1), summary.generated);
    try std.testing.expectEqual(@as(usize, 1), summary.added);
}
