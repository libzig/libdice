const std = @import("std");
const agent_mod = @import("agent.zig");
const candidate = @import("candidate.zig");
const stream_connectivity = @import("stream_connectivity.zig");
const pair_builder = @import("pair_builder.zig");
const conncheck = @import("conncheck.zig");
const parser = @import("../protocol/stun/parser.zig");
const transaction = @import("../protocol/stun/transaction.zig");

pub const StartedCheck = struct {
    stream_id: u32,
    component_id: u16,
    transaction_id: transaction.TransactionId,
};

pub const TimedOutCheck = struct {
    stream_id: u32,
    component_id: u16,
    timed_out: conncheck.TimedOutCheck,
};

pub const RestartSummary = struct {
    stream_id: u32,
    pair_summary: pair_builder.PairBuildSummary,
};

const RuntimeEntry = struct {
    stream_id: u32,
    runtime: stream_connectivity.StreamConnectivityRuntime,
};

pub const IceRuntime = struct {
    allocator: std.mem.Allocator,
    agent: *agent_mod.Agent,
    retry_policy: transaction.RetryPolicy,
    entries: std.ArrayList(RuntimeEntry),

    pub fn init(allocator: std.mem.Allocator, agent: *agent_mod.Agent, retry_policy: transaction.RetryPolicy) IceRuntime {
        return .{
            .allocator = allocator,
            .agent = agent,
            .retry_policy = retry_policy,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *IceRuntime) void {
        for (self.entries.items) |*entry| {
            entry.runtime.deinit();
        }
        self.entries.deinit(self.allocator);
    }

    pub fn stream_count(self: IceRuntime) usize {
        return self.entries.items.len;
    }

    fn find_entry(self: *IceRuntime, stream_id: u32) ?*RuntimeEntry {
        for (self.entries.items) |*entry| {
            if (entry.stream_id == stream_id) return entry;
        }
        return null;
    }

    pub fn attach_stream(self: *IceRuntime, stream_id: u32) !bool {
        if (self.find_entry(stream_id) != null) return false;

        const stream = self.agent.get_stream(stream_id) orelse return error.NotFound;
        var component_ids = try self.allocator.alloc(u16, stream.components.items.len);
        defer self.allocator.free(component_ids);

        for (stream.components.items, 0..) |component_item, idx| {
            component_ids[idx] = component_item.id;
        }

        const runtime = try stream_connectivity.StreamConnectivityRuntime.init(
            self.allocator,
            stream_id,
            component_ids,
            self.retry_policy,
        );

        try self.entries.append(self.allocator, .{
            .stream_id = stream_id,
            .runtime = runtime,
        });

        return true;
    }

    pub fn detach_stream(self: *IceRuntime, stream_id: u32) bool {
        for (self.entries.items, 0..) |*entry, idx| {
            if (entry.stream_id != stream_id) continue;
            entry.runtime.deinit();
            _ = self.entries.swapRemove(idx);
            return true;
        }
        return false;
    }

    pub fn start_connecting_all(self: *IceRuntime) !void {
        for (self.entries.items) |*entry| {
            try entry.runtime.start_connecting_all();
        }
    }

    pub fn populate_stream_checklists(self: *IceRuntime, stream_id: u32, controlling: bool, start_pair_id: u64) !pair_builder.PairBuildSummary {
        const entry = self.find_entry(stream_id) orelse return error.NotFound;
        const stream = self.agent.get_stream(stream_id) orelse return error.NotFound;
        return pair_builder.populate_stream_checklists(stream, &entry.runtime, controlling, start_pair_id);
    }

    pub fn restart_stream(self: *IceRuntime, stream_id: u32, controlling: bool, start_pair_id: u64) !RestartSummary {
        const entry = self.find_entry(stream_id) orelse return error.NotFound;
        try entry.runtime.reset_for_restart();

        const pair_summary = try self.populate_stream_checklists(stream_id, controlling, start_pair_id);
        return .{
            .stream_id = stream_id,
            .pair_summary = pair_summary,
        };
    }

    pub fn add_remote_candidate_and_expand(
        self: *IceRuntime,
        stream_id: u32,
        remote_candidate: candidate.Candidate,
        controlling: bool,
        start_pair_id: u64,
    ) !struct {
        remote_added: bool,
        pair_summary: pair_builder.PairBuildSummary,
    } {
        const remote_added = try self.agent.add_remote_candidate(stream_id, remote_candidate);
        const pair_summary = try self.populate_stream_checklists(stream_id, controlling, start_pair_id);

        return .{
            .remote_added = remote_added,
            .pair_summary = pair_summary,
        };
    }

    pub fn start_next_check_any(self: *IceRuntime, random: std.Random, now_ms: u64) !?StartedCheck {
        for (self.entries.items) |*entry| {
            const started = try entry.runtime.start_next_check_any(random, now_ms);
            if (started) |value| {
                return .{
                    .stream_id = entry.stream_id,
                    .component_id = value.component_id,
                    .transaction_id = value.transaction_id,
                };
            }
        }
        return null;
    }

    pub fn on_response(
        self: *IceRuntime,
        stream_id: u32,
        component_id: u16,
        view: parser.MessageView,
        now_ms: u64,
    ) !conncheck.CompletedCheck {
        const entry = self.find_entry(stream_id) orelse return error.NotFound;
        return entry.runtime.on_response(component_id, view, now_ms);
    }

    pub fn expire_all(self: *IceRuntime, now_ms: u64, out: []TimedOutCheck) !usize {
        var written: usize = 0;

        for (self.entries.items) |*entry| {
            var local: [16]stream_connectivity.TimedOutWithComponent = undefined;
            const count = try entry.runtime.expire_timeouts_all(now_ms, &local);

            for (local[0..@min(local.len, count)]) |item| {
                if (written < out.len) {
                    out[written] = .{
                        .stream_id = entry.stream_id,
                        .component_id = item.component_id,
                        .timed_out = item.timed_out,
                    };
                }
                written += 1;
            }
        }

        return written;
    }
};

test "ice runtime attach populate and response flow" {
    var agent = agent_mod.Agent.init(std.testing.allocator);
    defer agent.deinit();

    const stream_id = try agent.add_stream(1);

    const local_addr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 50 }, .port = 5000 } };
    const remote_addr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 198, 51, 100, 50 }, .port = 6000 } };

    try std.testing.expect(try agent.add_local_candidate(stream_id, .{
        .id = 1,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .host, local_addr),
        .priority = candidate.compute_candidate_priority(.host, 100, 1),
        .address = local_addr,
    }));

    try std.testing.expect(try agent.add_remote_candidate(stream_id, .{
        .id = 2,
        .component_id = 1,
        .candidate_type = .srflx,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .srflx, remote_addr),
        .priority = candidate.compute_candidate_priority(.srflx, 90, 1),
        .address = remote_addr,
    }));

    var runtime = IceRuntime.init(std.testing.allocator, &agent, .{});
    defer runtime.deinit();

    try std.testing.expect(try runtime.attach_stream(stream_id));
    try std.testing.expect(!(try runtime.attach_stream(stream_id)));

    const pair_summary = try runtime.populate_stream_checklists(stream_id, true, 1000);
    try std.testing.expectEqual(@as(usize, 1), pair_summary.generated);
    try std.testing.expectEqual(@as(usize, 1), pair_summary.added);

    try runtime.start_connecting_all();

    var prng = std.Random.DefaultPrng.init(21);
    const started = (try runtime.start_next_check_any(prng.random(), 0)).?;
    try std.testing.expectEqual(stream_id, started.stream_id);

    var packet: [20]u8 = undefined;
    const header = @import("../protocol/stun/message.zig").Header.init(0x0101, 0, started.transaction_id);
    _ = try header.encode(&packet);
    const view = try parser.parse_message(&packet);

    const completed = try runtime.on_response(started.stream_id, started.component_id, view, 50);
    try std.testing.expectEqual(@as(u64, 1000), completed.meta.candidate_pair_id);
}

test "ice runtime trickle remote candidate expansion" {
    var agent = agent_mod.Agent.init(std.testing.allocator);
    defer agent.deinit();

    const stream_id = try agent.add_stream(1);
    const local_addr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 60 }, .port = 5000 } };
    try std.testing.expect(try agent.add_local_candidate(stream_id, .{
        .id = 10,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .host, local_addr),
        .priority = candidate.compute_candidate_priority(.host, 100, 1),
        .address = local_addr,
    }));

    var runtime = IceRuntime.init(std.testing.allocator, &agent, .{});
    defer runtime.deinit();
    try std.testing.expect(try runtime.attach_stream(stream_id));

    const remote_1_addr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 198, 51, 100, 61 }, .port = 6000 } };
    const first = try runtime.add_remote_candidate_and_expand(stream_id, .{
        .id = 20,
        .component_id = 1,
        .candidate_type = .srflx,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .srflx, remote_1_addr),
        .priority = candidate.compute_candidate_priority(.srflx, 90, 1),
        .address = remote_1_addr,
    }, true, 2000);

    try std.testing.expect(first.remote_added);
    try std.testing.expectEqual(@as(usize, 1), first.pair_summary.added);

    const remote_2_addr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 198, 51, 100, 62 }, .port = 6001 } };
    const second = try runtime.add_remote_candidate_and_expand(stream_id, .{
        .id = 21,
        .component_id = 1,
        .candidate_type = .relay,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .relay, remote_2_addr),
        .priority = candidate.compute_candidate_priority(.relay, 1, 1),
        .address = remote_2_addr,
    }, true, first.pair_summary.next_pair_id);

    try std.testing.expect(second.remote_added);
    try std.testing.expectEqual(@as(usize, 2), second.pair_summary.generated);
    try std.testing.expectEqual(@as(usize, 1), second.pair_summary.added);
}

test "ice runtime timeout aggregation across streams" {
    var agent = agent_mod.Agent.init(std.testing.allocator);
    defer agent.deinit();

    const s1 = try agent.add_stream(1);
    const s2 = try agent.add_stream(1);

    const local_1: candidate.Address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 70 }, .port = 5000 } };
    const remote_1: candidate.Address = .{ .ipv4 = .{ .ip = .{ 198, 51, 100, 70 }, .port = 6000 } };
    const local_2: candidate.Address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 71 }, .port = 5001 } };
    const remote_2: candidate.Address = .{ .ipv4 = .{ .ip = .{ 198, 51, 100, 71 }, .port = 6001 } };

    try std.testing.expect(try agent.add_local_candidate(s1, .{
        .id = 1,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .host, local_1),
        .priority = candidate.compute_candidate_priority(.host, 100, 1),
        .address = local_1,
    }));
    try std.testing.expect(try agent.add_remote_candidate(s1, .{
        .id = 2,
        .component_id = 1,
        .candidate_type = .srflx,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .srflx, remote_1),
        .priority = candidate.compute_candidate_priority(.srflx, 90, 1),
        .address = remote_1,
    }));

    try std.testing.expect(try agent.add_local_candidate(s2, .{
        .id = 3,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .host, local_2),
        .priority = candidate.compute_candidate_priority(.host, 100, 1),
        .address = local_2,
    }));
    try std.testing.expect(try agent.add_remote_candidate(s2, .{
        .id = 4,
        .component_id = 1,
        .candidate_type = .srflx,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .srflx, remote_2),
        .priority = candidate.compute_candidate_priority(.srflx, 90, 1),
        .address = remote_2,
    }));

    var runtime = IceRuntime.init(std.testing.allocator, &agent, .{ .base_rto_ms = 100, .max_retransmits = 1 });
    defer runtime.deinit();

    try std.testing.expect(try runtime.attach_stream(s1));
    try std.testing.expect(try runtime.attach_stream(s2));

    _ = try runtime.populate_stream_checklists(s1, true, 3000);
    _ = try runtime.populate_stream_checklists(s2, true, 4000);
    try runtime.start_connecting_all();

    var prng = std.Random.DefaultPrng.init(22);
    _ = try runtime.start_next_check_any(prng.random(), 0);
    _ = try runtime.start_next_check_any(prng.random(), 50);

    var out: [8]TimedOutCheck = undefined;
    const expired = try runtime.expire_all(349, &out);
    try std.testing.expectEqual(@as(usize, 1), expired);
}

test "ice runtime restart stream reinitializes pipeline" {
    var agent = agent_mod.Agent.init(std.testing.allocator);
    defer agent.deinit();

    const stream_id = try agent.add_stream(1);

    const local_addr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 90 }, .port = 5000 } };
    const remote_addr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 198, 51, 100, 90 }, .port = 6000 } };
    try std.testing.expect(try agent.add_local_candidate(stream_id, .{
        .id = 1,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .host, local_addr),
        .priority = candidate.compute_candidate_priority(.host, 100, 1),
        .address = local_addr,
    }));
    try std.testing.expect(try agent.add_remote_candidate(stream_id, .{
        .id = 2,
        .component_id = 1,
        .candidate_type = .srflx,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .srflx, remote_addr),
        .priority = candidate.compute_candidate_priority(.srflx, 90, 1),
        .address = remote_addr,
    }));

    var runtime = IceRuntime.init(std.testing.allocator, &agent, .{});
    defer runtime.deinit();
    try std.testing.expect(try runtime.attach_stream(stream_id));

    const first = try runtime.populate_stream_checklists(stream_id, true, 5000);
    try std.testing.expectEqual(@as(usize, 1), first.added);

    try runtime.start_connecting_all();
    var prng = std.Random.DefaultPrng.init(23);
    _ = try runtime.start_next_check_any(prng.random(), 0);

    const restarted = try runtime.restart_stream(stream_id, true, 6000);
    try std.testing.expectEqual(stream_id, restarted.stream_id);
    try std.testing.expectEqual(@as(usize, 1), restarted.pair_summary.added);
    try std.testing.expectEqual(@as(u64, 6001), restarted.pair_summary.next_pair_id);
}
