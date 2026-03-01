const std = @import("std");
const libdice = @import("libdice");

const CallbackState = struct {
    completed_checks: usize = 0,
    timed_out_checks: usize = 0,
    events: usize = 0,
    verbose: bool = true,
};

const callbacks = struct {
    fn on_completed(ctx: *anyopaque, completed: libdice.CompletedConnectivityCheck) void {
        const state: *CallbackState = @ptrCast(@alignCast(ctx));
        state.completed_checks += 1;
        if (state.verbose) {
            std.debug.print(
                "completed check stream={d} component={d} pair={d}\n",
                .{ completed.meta.stream_id, completed.meta.component_id, completed.meta.candidate_pair_id },
            );
        }
    }

    fn on_timed_out(ctx: *anyopaque, timed_out: libdice.IceRuntimeTimedOutCheck) void {
        const state: *CallbackState = @ptrCast(@alignCast(ctx));
        state.timed_out_checks += 1;
        if (state.verbose) {
            std.debug.print(
                "timed out check stream={d} component={d} pair={d}\n",
                .{ timed_out.stream_id, timed_out.component_id, timed_out.timed_out.meta.candidate_pair_id },
            );
        }
    }

    fn on_event(ctx: *anyopaque, event: libdice.IceRuntimeEvent) void {
        const state: *CallbackState = @ptrCast(@alignCast(ctx));
        state.events += 1;
        if (!state.verbose) return;
        std.debug.print("event {s} stream={d} component={d}\n", .{
            @tagName(event.event.event),
            event.stream_id,
            event.component_id,
        });
    }
};

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

    var agent = libdice.Agent.init(allocator);
    defer agent.deinit();

    const stream_id = try agent.add_stream(1);

    const local_addr: libdice.CandidateAddress = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 251 }, .port = 5100 } };
    const unreachable_remote: libdice.CandidateAddress = .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 65000 } };

    if (!(try agent.add_local_candidate(stream_id, .{
        .id = 11,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = libdice.candidate_compute_foundation(.udp, .host, local_addr),
        .priority = libdice.candidate_compute_priority(.host, 100, 1),
        .address = local_addr,
    }))) return error.UnexpectedDuplicateCandidate;
    if (!(try agent.add_remote_candidate(stream_id, .{
        .id = 12,
        .component_id = 1,
        .candidate_type = .srflx,
        .transport = .udp,
        .foundation = libdice.candidate_compute_foundation(.udp, .srflx, unreachable_remote),
        .priority = libdice.candidate_compute_priority(.srflx, 90, 1),
        .address = unreachable_remote,
    }))) return error.UnexpectedDuplicateCandidate;

    var runtime = libdice.IceRuntime.init(
        allocator,
        &agent,
        .{ .base_rto_ms = 50, .max_retransmits = 1 },
        .{},
        .regular,
    );
    defer runtime.deinit();

    if (!(try runtime.attach_stream(stream_id))) return error.UnexpectedAttachFailure;
    _ = try runtime.populate_stream_checklists(stream_id, true, 2000);
    try runtime.start_connecting_all();

    var bridge = libdice.IceUdpRuntimeBridge.init(allocator, &runtime);
    defer bridge.deinit();
    _ = try bridge.add_binding(stream_id, 1, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });

    var prng = std.Random.DefaultPrng.init(6789);
    var callback_state = CallbackState{ .verbose = !summary };
    var outbound_buf: [512]u8 = undefined;
    var recv_buf: [512]u8 = undefined;
    var send_buf: [512]u8 = undefined;
    var completed: [8]libdice.CompletedConnectivityCheck = undefined;
    var timed_out: [8]libdice.IceRuntimeTimedOutCheck = undefined;
    var events: [32]libdice.IceRuntimeEvent = undefined;

    const tick0 = try bridge.pump_once_with_handlers(
        prng.random(),
        0,
        &outbound_buf,
        &recv_buf,
        &send_buf,
        &completed,
        &timed_out,
        &events,
        &callback_state,
        .{ .on_completed = callbacks.on_completed, .on_timed_out = callbacks.on_timed_out, .on_event = callbacks.on_event },
        .{ .io_tick = .{ .max_starts_per_tick = 1, .outbound_options = .{ .username = "l:r", .priority = 100, .role = .{ .role = .controlling, .tie_breaker = 1 } } } },
    );

    const tick1 = try bridge.pump_once_with_handlers(
        prng.random(),
        50,
        &outbound_buf,
        &recv_buf,
        &send_buf,
        &completed,
        &timed_out,
        &events,
        &callback_state,
        .{ .on_completed = callbacks.on_completed, .on_timed_out = callbacks.on_timed_out, .on_event = callbacks.on_event },
        .{ .io_tick = .{ .max_starts_per_tick = 0, .outbound_options = .{ .username = "l:r", .priority = 100, .role = .{ .role = .controlling, .tie_breaker = 1 } } } },
    );

    const tick2 = try bridge.pump_once_with_handlers(
        prng.random(),
        150,
        &outbound_buf,
        &recv_buf,
        &send_buf,
        &completed,
        &timed_out,
        &events,
        &callback_state,
        .{ .on_completed = callbacks.on_completed, .on_timed_out = callbacks.on_timed_out, .on_event = callbacks.on_event },
        .{ .io_tick = .{ .max_starts_per_tick = 0 } },
    );

    if (summary) {
        std.debug.print(
            "demo=timeout tick0_started={d} tick0_retx={d} tick1_started={d} tick1_retx={d} tick2_timed_out={d} callbacks_completed={d} callbacks_timed_out={d} callbacks_events={d}\n",
            .{ tick0.started_checks, tick0.retransmits_sent, tick1.started_checks, tick1.retransmits_sent, tick2.timed_out_checks, callback_state.completed_checks, callback_state.timed_out_checks, callback_state.events },
        );
        return;
    }

    std.debug.print(
        "tick0 started={d} retransmits={d}; tick1 started={d} retransmits={d}; tick2 timed_out={d}\n",
        .{ tick0.started_checks, tick0.retransmits_sent, tick1.started_checks, tick1.retransmits_sent, tick2.timed_out_checks },
    );
    std.debug.print(
        "callback counters completed={d} timed_out={d} events={d}\n",
        .{ callback_state.completed_checks, callback_state.timed_out_checks, callback_state.events },
    );
}

pub fn main() !void {
    try run();
}
