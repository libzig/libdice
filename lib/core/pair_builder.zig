const std = @import("std");
const stream_mod = @import("stream.zig");
const stream_connectivity = @import("stream_connectivity.zig");
const checklist = @import("checklist.zig");
const connectivity_engine = @import("connectivity_engine.zig");

pub const PairBuildSummary = struct {
    generated: usize,
    added: usize,
    next_pair_id: u64,
};

pub const PairBuildPolicy = enum {
    all,
    force_relay,
};

pub fn populate_stream_checklists(
    stream: *stream_mod.Stream,
    runtime: *stream_connectivity.StreamConnectivityRuntime,
    controlling: bool,
    start_pair_id: u64,
) !PairBuildSummary {
    return populate_stream_checklists_with_policy(stream, runtime, controlling, start_pair_id, .all);
}

pub fn populate_stream_checklists_with_policy(
    stream: *stream_mod.Stream,
    runtime: *stream_connectivity.StreamConnectivityRuntime,
    controlling: bool,
    start_pair_id: u64,
    policy: PairBuildPolicy,
) !PairBuildSummary {
    var pair_id = start_pair_id;
    var generated: usize = 0;
    var added: usize = 0;

    for (stream.components.items) |component| {
        const engine = runtime.get_engine(component.id) orelse return error.ComponentRuntimeNotFound;

        for (stream.local_candidates.items.items) |local| {
            if (local.component_id != component.id) continue;

            for (stream.remote_candidates.items.items) |remote| {
                if (remote.component_id != component.id) continue;
                if (local.transport != remote.transport) continue;
                if (policy == .force_relay and local.candidate_type != .relay and remote.candidate_type != .relay) continue;

                generated += 1;

                const pair_priority = checklist.compute_pair_priority(controlling, local.priority, remote.priority);
                const pair = checklist.Pair{
                    .id = pair_id,
                    .local_candidate_id = local.id,
                    .remote_candidate_id = remote.id,
                    .priority = pair_priority,
                    .component_id = component.id,
                    .state = .waiting,
                };

                const inserted = try engine.add_pair_unique(pair, .{
                    .local_candidate_id = local.id,
                    .remote_candidate_id = remote.id,
                    .nominated = false,
                });
                if (inserted) {
                    added += 1;
                    pair_id += 1;
                }
            }
        }
    }

    return .{
        .generated = generated,
        .added = added,
        .next_pair_id = pair_id,
    };
}

test "pair builder creates cross product per component" {
    var stream = stream_mod.Stream.init(std.testing.allocator, 1);
    defer stream.deinit();
    try stream.add_component(1);
    try stream.add_component(2);

    const component_ids = [_]u16{ 1, 2 };
    var runtime = try stream_connectivity.StreamConnectivityRuntime.init(std.testing.allocator, 1, &component_ids, .{}, .{}, .regular);
    defer runtime.deinit();

    const a1: stream_mod.candidate.Address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 1 }, .port = 5000 } };
    const a2: stream_mod.candidate.Address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 2 }, .port = 5001 } };
    const r1: stream_mod.candidate.Address = .{ .ipv4 = .{ .ip = .{ 198, 51, 100, 1 }, .port = 6000 } };
    const r2: stream_mod.candidate.Address = .{ .ipv4 = .{ .ip = .{ 198, 51, 100, 2 }, .port = 6001 } };

    try std.testing.expect(try stream.add_local_candidate(.{
        .id = 1,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = stream_mod.candidate.compute_foundation(.udp, .host, a1),
        .priority = stream_mod.candidate.compute_candidate_priority(.host, 100, 1),
        .address = a1,
    }));
    try std.testing.expect(try stream.add_local_candidate(.{
        .id = 2,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = stream_mod.candidate.compute_foundation(.udp, .host, a2),
        .priority = stream_mod.candidate.compute_candidate_priority(.host, 101, 1),
        .address = a2,
    }));

    try std.testing.expect(try stream.add_remote_candidate(.{
        .id = 10,
        .component_id = 1,
        .candidate_type = .srflx,
        .transport = .udp,
        .foundation = stream_mod.candidate.compute_foundation(.udp, .srflx, r1),
        .priority = stream_mod.candidate.compute_candidate_priority(.srflx, 99, 1),
        .address = r1,
    }));
    try std.testing.expect(try stream.add_remote_candidate(.{
        .id = 11,
        .component_id = 1,
        .candidate_type = .srflx,
        .transport = .udp,
        .foundation = stream_mod.candidate.compute_foundation(.udp, .srflx, r2),
        .priority = stream_mod.candidate.compute_candidate_priority(.srflx, 98, 1),
        .address = r2,
    }));

    // Component 2 gets one local and one remote candidate => 1 pair there.
    try std.testing.expect(try stream.add_local_candidate(.{
        .id = 3,
        .component_id = 2,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = stream_mod.candidate.compute_foundation(.udp, .host, a1),
        .priority = stream_mod.candidate.compute_candidate_priority(.host, 50, 2),
        .address = a1,
    }));
    try std.testing.expect(try stream.add_remote_candidate(.{
        .id = 12,
        .component_id = 2,
        .candidate_type = .relay,
        .transport = .udp,
        .foundation = stream_mod.candidate.compute_foundation(.udp, .relay, r1),
        .priority = stream_mod.candidate.compute_candidate_priority(.relay, 1, 2),
        .address = r1,
    }));

    const summary = try populate_stream_checklists(&stream, &runtime, true, 1000);
    try std.testing.expectEqual(@as(usize, 5), summary.generated);
    try std.testing.expectEqual(@as(usize, 5), summary.added);
    try std.testing.expectEqual(@as(u64, 1005), summary.next_pair_id);

    try std.testing.expectEqual(@as(usize, 4), runtime.get_engine(1).?.checklist.pair_count());
    try std.testing.expectEqual(@as(usize, 1), runtime.get_engine(2).?.checklist.pair_count());
}

test "pair builder is idempotent with same candidate sets" {
    var stream = stream_mod.Stream.init(std.testing.allocator, 2);
    defer stream.deinit();
    try stream.add_component(1);

    const component_ids = [_]u16{1};
    var runtime = try stream_connectivity.StreamConnectivityRuntime.init(std.testing.allocator, 2, &component_ids, .{}, .{}, .regular);
    defer runtime.deinit();

    const addr_l: stream_mod.candidate.Address = .{ .ipv4 = .{ .ip = .{ 203, 0, 113, 1 }, .port = 5000 } };
    const addr_r: stream_mod.candidate.Address = .{ .ipv4 = .{ .ip = .{ 203, 0, 113, 2 }, .port = 6000 } };

    try std.testing.expect(try stream.add_local_candidate(.{
        .id = 1,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = stream_mod.candidate.compute_foundation(.udp, .host, addr_l),
        .priority = stream_mod.candidate.compute_candidate_priority(.host, 100, 1),
        .address = addr_l,
    }));
    try std.testing.expect(try stream.add_remote_candidate(.{
        .id = 2,
        .component_id = 1,
        .candidate_type = .srflx,
        .transport = .udp,
        .foundation = stream_mod.candidate.compute_foundation(.udp, .srflx, addr_r),
        .priority = stream_mod.candidate.compute_candidate_priority(.srflx, 100, 1),
        .address = addr_r,
    }));

    const first = try populate_stream_checklists(&stream, &runtime, true, 10);
    try std.testing.expectEqual(@as(usize, 1), first.generated);
    try std.testing.expectEqual(@as(usize, 1), first.added);

    const second = try populate_stream_checklists(&stream, &runtime, true, first.next_pair_id);
    try std.testing.expectEqual(@as(usize, 1), second.generated);
    try std.testing.expectEqual(@as(usize, 0), second.added);
    try std.testing.expectEqual(@as(usize, 1), runtime.get_engine(1).?.checklist.pair_count());
}

test "pair builder force_relay policy filters non-relay pairs" {
    var stream = stream_mod.Stream.init(std.testing.allocator, 3);
    defer stream.deinit();
    try stream.add_component(1);

    const component_ids = [_]u16{1};
    var runtime = try stream_connectivity.StreamConnectivityRuntime.init(std.testing.allocator, 3, &component_ids, .{}, .{}, .regular);
    defer runtime.deinit();

    const host_local: stream_mod.candidate.Address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 30 }, .port = 5000 } };
    const relay_local: stream_mod.candidate.Address = .{ .ipv4 = .{ .ip = .{ 10, 0, 0, 30 }, .port = 5300 } };
    const srflx_remote: stream_mod.candidate.Address = .{ .ipv4 = .{ .ip = .{ 198, 51, 100, 30 }, .port = 6000 } };
    const relay_remote: stream_mod.candidate.Address = .{ .ipv4 = .{ .ip = .{ 203, 0, 113, 30 }, .port = 6100 } };

    try std.testing.expect(try stream.add_local_candidate(.{
        .id = 1,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = stream_mod.candidate.compute_foundation(.udp, .host, host_local),
        .priority = stream_mod.candidate.compute_candidate_priority(.host, 100, 1),
        .address = host_local,
    }));
    try std.testing.expect(try stream.add_local_candidate(.{
        .id = 2,
        .component_id = 1,
        .candidate_type = .relay,
        .transport = .udp,
        .foundation = stream_mod.candidate.compute_foundation(.udp, .relay, relay_local),
        .priority = stream_mod.candidate.compute_candidate_priority(.relay, 10, 1),
        .address = relay_local,
    }));
    try std.testing.expect(try stream.add_remote_candidate(.{
        .id = 10,
        .component_id = 1,
        .candidate_type = .srflx,
        .transport = .udp,
        .foundation = stream_mod.candidate.compute_foundation(.udp, .srflx, srflx_remote),
        .priority = stream_mod.candidate.compute_candidate_priority(.srflx, 90, 1),
        .address = srflx_remote,
    }));
    try std.testing.expect(try stream.add_remote_candidate(.{
        .id = 11,
        .component_id = 1,
        .candidate_type = .relay,
        .transport = .udp,
        .foundation = stream_mod.candidate.compute_foundation(.udp, .relay, relay_remote),
        .priority = stream_mod.candidate.compute_candidate_priority(.relay, 11, 1),
        .address = relay_remote,
    }));

    const summary = try populate_stream_checklists_with_policy(&stream, &runtime, true, 100, .force_relay);
    try std.testing.expectEqual(@as(usize, 3), summary.generated);
    try std.testing.expectEqual(@as(usize, 3), summary.added);
    try std.testing.expectEqual(@as(usize, 3), runtime.get_engine(1).?.checklist.pair_count());
}
