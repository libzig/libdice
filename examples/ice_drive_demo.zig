const std = @import("std");
const libdice = @import("libdice");

fn run_quiescent_scenario(allocator: std.mem.Allocator) !libdice.IceUdpDriveLoopSummary {
    var agent = libdice.Agent.init(allocator);
    defer agent.deinit();

    const stream_id = try agent.add_stream(1);

    var runtime = libdice.IceRuntime.init(allocator, &agent, .{}, .{}, .regular);
    defer runtime.deinit();
    if (!(try runtime.attach_stream(stream_id))) return error.UnexpectedAttachFailure;

    var bridge = libdice.IceUdpRuntimeBridge.init(allocator, &runtime);
    defer bridge.deinit();

    var prng = std.Random.DefaultPrng.init(9001);
    var outbound_buf: [256]u8 = undefined;
    var recv_buf: [256]u8 = undefined;
    var send_buf: [256]u8 = undefined;
    var completed: [4]libdice.CompletedConnectivityCheck = undefined;
    var timed_out: [4]libdice.IceRuntimeTimedOutCheck = undefined;
    var events: [16]libdice.IceRuntimeEvent = undefined;

    return bridge.run_until_quiescent_or_deadline(
        prng.random(),
        0,
        1000,
        10,
        &outbound_buf,
        &recv_buf,
        &send_buf,
        &completed,
        &timed_out,
        &events,
        .{},
    );
}

fn run_deadline_scenario(allocator: std.mem.Allocator) !libdice.IceUdpDriveLoopSummary {
    var agent = libdice.Agent.init(allocator);
    defer agent.deinit();

    const stream_id = try agent.add_stream(1);
    const local_addr: libdice.CandidateAddress = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 252 }, .port = 5100 } };
    const remote_addr: libdice.CandidateAddress = .{ .ipv4 = .{ .ip = .{ 198, 51, 100, 252 }, .port = 6100 } };

    if (!(try agent.add_local_candidate(stream_id, .{
        .id = 21,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = libdice.candidate_compute_foundation(.udp, .host, local_addr),
        .priority = libdice.candidate_compute_priority(.host, 100, 1),
        .address = local_addr,
    }))) return error.UnexpectedDuplicateCandidate;
    if (!(try agent.add_remote_candidate(stream_id, .{
        .id = 22,
        .component_id = 1,
        .candidate_type = .srflx,
        .transport = .udp,
        .foundation = libdice.candidate_compute_foundation(.udp, .srflx, remote_addr),
        .priority = libdice.candidate_compute_priority(.srflx, 90, 1),
        .address = remote_addr,
    }))) return error.UnexpectedDuplicateCandidate;

    var runtime = libdice.IceRuntime.init(allocator, &agent, .{ .base_rto_ms = 500, .max_retransmits = 3 }, .{}, .regular);
    defer runtime.deinit();
    if (!(try runtime.attach_stream(stream_id))) return error.UnexpectedAttachFailure;

    _ = try runtime.populate_stream_checklists(stream_id, true, 3000);
    try runtime.start_connecting_all();
    var prng = std.Random.DefaultPrng.init(9002);
    _ = try runtime.start_next_check_any(prng.random(), 0);

    var bridge = libdice.IceUdpRuntimeBridge.init(allocator, &runtime);
    defer bridge.deinit();

    var outbound_buf: [256]u8 = undefined;
    var recv_buf: [256]u8 = undefined;
    var send_buf: [256]u8 = undefined;
    var completed: [4]libdice.CompletedConnectivityCheck = undefined;
    var timed_out: [4]libdice.IceRuntimeTimedOutCheck = undefined;
    var events: [16]libdice.IceRuntimeEvent = undefined;

    return bridge.run_until_quiescent_or_deadline(
        prng.random(),
        0,
        0,
        10,
        &outbound_buf,
        &recv_buf,
        &send_buf,
        &completed,
        &timed_out,
        &events,
        .{ .io_tick = .{ .max_starts_per_tick = 0 } },
    );
}

pub fn run() !void {
    try run_with_summary(false);
}

pub fn run_summary() !void {
    try run_with_summary(true);
}

fn run_with_summary(summary: bool) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        _ = gpa.deinit();
    }
    const allocator = gpa.allocator();

    const quiescent = try run_quiescent_scenario(allocator);
    const deadline = try run_deadline_scenario(allocator);
    if (summary) {
        std.debug.print(
            "demo=drive quiescent_stop={s} quiescent_ticks={d} quiescent_pending={d} deadline_stop={s} deadline_ticks={d} deadline_pending={d}\n",
            .{ @tagName(quiescent.stop_reason), quiescent.ticks_run, quiescent.final_pending_transactions, @tagName(deadline.stop_reason), deadline.ticks_run, deadline.final_pending_transactions },
        );
        return;
    }

    std.debug.print(
        "quiescent scenario stop={s} ticks={d} pending={d}\n",
        .{ @tagName(quiescent.stop_reason), quiescent.ticks_run, quiescent.final_pending_transactions },
    );
    std.debug.print(
        "deadline scenario stop={s} ticks={d} pending={d}\n",
        .{ @tagName(deadline.stop_reason), deadline.ticks_run, deadline.final_pending_transactions },
    );
}

pub fn main() !void {
    try run();
}
