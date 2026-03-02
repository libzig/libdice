const std = @import("std");
const agent_mod = @import("agent.zig");
const signaling = @import("signaling.zig");
const candidate_exchange = @import("candidate_exchange.zig");
const ice_runtime = @import("ice_runtime.zig");

pub const TextExchangeSummary = struct {
    left_encoded_bytes: usize,
    right_encoded_bytes: usize,
    left_apply: signaling.ApplySummary,
    right_apply: signaling.ApplySummary,
};

pub const PairPopulateSummary = struct {
    left: @import("pair_builder.zig").PairBuildSummary,
    right: @import("pair_builder.zig").PairBuildSummary,
};

pub fn exchange_descriptions_via_text(
    allocator: std.mem.Allocator,
    left_agent: *agent_mod.Agent,
    left_stream_id: u32,
    right_agent: *agent_mod.Agent,
    right_stream_id: u32,
    component_filter: ?u16,
) !TextExchangeSummary {
    var left_local = try left_agent.build_local_description(allocator, left_stream_id, component_filter);
    defer left_local.deinit(allocator);

    var right_local = try right_agent.build_local_description(allocator, right_stream_id, component_filter);
    defer right_local.deinit(allocator);

    const left_text = try candidate_exchange.encode_description(allocator, left_local.credentials, left_local.candidates);
    defer allocator.free(left_text);
    const right_text = try candidate_exchange.encode_description(allocator, right_local.credentials, right_local.candidates);
    defer allocator.free(right_text);

    var parsed_left = try candidate_exchange.parse_description(allocator, left_text);
    defer parsed_left.deinit(allocator);
    var parsed_right = try candidate_exchange.parse_description(allocator, right_text);
    defer parsed_right.deinit(allocator);

    const left_apply = try right_agent.apply_remote_description(right_stream_id, .{
        .credentials = parsed_left.credentials,
        .candidates = parsed_left.candidates,
    });
    const right_apply = try left_agent.apply_remote_description(left_stream_id, .{
        .credentials = parsed_right.credentials,
        .candidates = parsed_right.candidates,
    });

    return .{
        .left_encoded_bytes = left_text.len,
        .right_encoded_bytes = right_text.len,
        .left_apply = left_apply,
        .right_apply = right_apply,
    };
}

pub fn populate_checklists_both(
    left_runtime: *ice_runtime.IceRuntime,
    left_stream_id: u32,
    left_controlling: bool,
    left_start_pair_id: u64,
    left_options: ice_runtime.ChecklistPopulateOptions,
    right_runtime: *ice_runtime.IceRuntime,
    right_stream_id: u32,
    right_controlling: bool,
    right_start_pair_id: u64,
    right_options: ice_runtime.ChecklistPopulateOptions,
) !PairPopulateSummary {
    return .{
        .left = try left_runtime.populate_stream_checklists_with_options(left_stream_id, left_controlling, left_start_pair_id, left_options),
        .right = try right_runtime.populate_stream_checklists_with_options(right_stream_id, right_controlling, right_start_pair_id, right_options),
    };
}

test "loopback harness exchanges descriptions via text codec" {
    const candidate = @import("candidate.zig");

    var left = agent_mod.Agent.init(std.testing.allocator);
    defer left.deinit();
    var right = agent_mod.Agent.init(std.testing.allocator);
    defer right.deinit();

    const ls = try left.add_stream(1);
    const rs = try right.add_stream(1);
    try left.get_stream(ls).?.set_local_credentials("leftU", "leftP");
    try right.get_stream(rs).?.set_local_credentials("rightU", "rightP");

    const laddr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 80 }, .port = 5000 } };
    const raddr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 198, 51, 100, 80 }, .port = 6000 } };
    try std.testing.expect(try left.add_local_candidate(ls, .{
        .id = 1,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .host, laddr),
        .priority = candidate.compute_candidate_priority(.host, 100, 1),
        .address = laddr,
    }));
    try std.testing.expect(try right.add_local_candidate(rs, .{
        .id = 2,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .host, raddr),
        .priority = candidate.compute_candidate_priority(.host, 100, 1),
        .address = raddr,
    }));

    const summary = try exchange_descriptions_via_text(std.testing.allocator, &left, ls, &right, rs, null);
    try std.testing.expect(summary.left_encoded_bytes > 0);
    try std.testing.expect(summary.right_encoded_bytes > 0);
    try std.testing.expectEqual(@as(usize, 1), summary.left_apply.candidates_added);
    try std.testing.expectEqual(@as(usize, 1), summary.right_apply.candidates_added);
}

test "loopback harness populates both runtimes with independent policies" {
    const candidate = @import("candidate.zig");

    var left = agent_mod.Agent.init(std.testing.allocator);
    defer left.deinit();
    var right = agent_mod.Agent.init(std.testing.allocator);
    defer right.deinit();

    const ls = try left.add_stream(1);
    const rs = try right.add_stream(1);

    const left_host: candidate.Address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 81 }, .port = 5000 } };
    const left_relay: candidate.Address = .{ .ipv4 = .{ .ip = .{ 10, 0, 0, 81 }, .port = 5100 } };
    const right_host: candidate.Address = .{ .ipv4 = .{ .ip = .{ 198, 51, 100, 81 }, .port = 6000 } };

    try std.testing.expect(try left.add_local_candidate(ls, .{
        .id = 1,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .host, left_host),
        .priority = candidate.compute_candidate_priority(.host, 100, 1),
        .address = left_host,
    }));
    try std.testing.expect(try left.add_local_candidate(ls, .{
        .id = 2,
        .component_id = 1,
        .candidate_type = .relay,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .relay, left_relay),
        .priority = candidate.compute_candidate_priority(.relay, 10, 1),
        .address = left_relay,
    }));
    try std.testing.expect(try right.add_local_candidate(rs, .{
        .id = 3,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .host, right_host),
        .priority = candidate.compute_candidate_priority(.host, 100, 1),
        .address = right_host,
    }));

    _ = try exchange_descriptions_via_text(std.testing.allocator, &left, ls, &right, rs, null);

    var left_runtime = ice_runtime.IceRuntime.init(std.testing.allocator, &left, .{}, .{}, .regular);
    defer left_runtime.deinit();
    var right_runtime = ice_runtime.IceRuntime.init(std.testing.allocator, &right, .{}, .{}, .regular);
    defer right_runtime.deinit();

    try std.testing.expect(try left_runtime.attach_stream(ls));
    try std.testing.expect(try right_runtime.attach_stream(rs));

    const pairs = try populate_checklists_both(
        &left_runtime,
        ls,
        true,
        2000,
        .{ .policy = .force_relay },
        &right_runtime,
        rs,
        false,
        3000,
        .{},
    );

    try std.testing.expectEqual(@as(usize, 1), pairs.left.added);
    try std.testing.expectEqual(@as(usize, 2), pairs.right.added);
}
