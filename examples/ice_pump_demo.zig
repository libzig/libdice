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
                "completed check stream={d} component={d} pair={d} rtt_ms={d}\n",
                .{ completed.meta.stream_id, completed.meta.component_id, completed.meta.candidate_pair_id, completed.rtt_ms },
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
        switch (event.event.event) {
            .check_started => |ev| {
                std.debug.print(
                    "event check_started stream={d} component={d} pair={d}\n",
                    .{ event.stream_id, event.component_id, ev.pair_id },
                );
            },
            .check_succeeded => |ev| {
                std.debug.print(
                    "event check_succeeded stream={d} component={d} pair={d} rtt_ms={d}\n",
                    .{ event.stream_id, event.component_id, ev.pair_id, ev.rtt_ms },
                );
            },
            .state_changed => |ev| {
                std.debug.print(
                    "event state_changed stream={d} component={d} {s}->{s}\n",
                    .{ event.stream_id, event.component_id, @tagName(ev.from), @tagName(ev.to) },
                );
            },
            else => {
                std.debug.print("event {s}\n", .{@tagName(event.event.event)});
            },
        }
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
    const local_addr: libdice.CandidateAddress = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 250 }, .port = 5000 } };

    var peer = try libdice.UdpSocket.bind(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer peer.deinit();
    const peer_addr = try peer.local_address();

    if (!(try agent.add_local_candidate(stream_id, .{
        .id = 1,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = libdice.candidate_compute_foundation(.udp, .host, local_addr),
        .priority = libdice.candidate_compute_priority(.host, 100, 1),
        .address = local_addr,
    }))) return error.UnexpectedDuplicateCandidate;
    if (!(try agent.add_remote_candidate(stream_id, .{
        .id = 2,
        .component_id = 1,
        .candidate_type = .srflx,
        .transport = .udp,
        .foundation = libdice.candidate_compute_foundation(.udp, .srflx, peer_addr),
        .priority = libdice.candidate_compute_priority(.srflx, 90, 1),
        .address = peer_addr,
    }))) return error.UnexpectedDuplicateCandidate;

    var runtime = libdice.IceRuntime.init(allocator, &agent, .{}, .{}, .regular);
    defer runtime.deinit();
    if (!(try runtime.attach_stream(stream_id))) return error.UnexpectedAttachFailure;
    _ = try runtime.populate_stream_checklists(stream_id, true, 1000);
    try runtime.start_connecting_all();

    var bridge = libdice.IceUdpRuntimeBridge.init(allocator, &runtime);
    defer bridge.deinit();
    _ = try bridge.add_binding(stream_id, 1, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });

    var prng = std.Random.DefaultPrng.init(12345);
    var callback_state = CallbackState{ .verbose = !summary };

    var outbound_buf: [512]u8 = undefined;
    var recv_buf: [512]u8 = undefined;
    var send_buf: [512]u8 = undefined;
    var completed: [8]libdice.CompletedConnectivityCheck = undefined;
    var timed_out: [8]libdice.IceRuntimeTimedOutCheck = undefined;
    var events: [32]libdice.IceRuntimeEvent = undefined;

    const first = try bridge.pump_once_with_handlers(
        prng.random(),
        0,
        &outbound_buf,
        &recv_buf,
        &send_buf,
        &completed,
        &timed_out,
        &events,
        &callback_state,
        .{
            .on_completed = callbacks.on_completed,
            .on_timed_out = callbacks.on_timed_out,
            .on_event = callbacks.on_event,
        },
        .{ .io_tick = .{ .max_starts_per_tick = 1, .outbound_options = .{ .username = "l:r", .priority = 100, .role = .{ .role = .controlling, .tie_breaker = 1 } } } },
    );

    var request_packet: [512]u8 = undefined;
    const request_recv = try peer.recv_from(&request_packet);
    const request_view = try libdice.parse_stun_message(request_packet[0..request_recv.bytes]);
    if (!libdice.stun_ice_is_connectivity_check_request(request_view)) return error.UnexpectedMessage;

    var response_packet: [256]u8 = undefined;
    const response = try libdice.stun_ice_build_connectivity_check_success_response(&response_packet, request_view.header.transaction_id, .{});
    _ = try peer.send_to(request_recv.from, response);

    const second = try bridge.pump_once_with_handlers(
        prng.random(),
        100,
        &outbound_buf,
        &recv_buf,
        &send_buf,
        &completed,
        &timed_out,
        &events,
        &callback_state,
        .{
            .on_completed = callbacks.on_completed,
            .on_timed_out = callbacks.on_timed_out,
            .on_event = callbacks.on_event,
        },
        .{ .io_tick = .{ .max_starts_per_tick = 0 } },
    );

    if (summary) {
        std.debug.print(
            "demo=pump first_started={d} first_events={d} second_completed={d} second_events={d} callbacks_completed={d} callbacks_timed_out={d} callbacks_events={d}\n",
            .{ first.started_checks, first.events_drained, second.completed_checks, second.events_drained, callback_state.completed_checks, callback_state.timed_out_checks, callback_state.events },
        );
        return;
    }

    std.debug.print(
        "first tick started={d} events={d}; second tick completed={d} events={d}\n",
        .{ first.started_checks, first.events_drained, second.completed_checks, second.events_drained },
    );
    std.debug.print(
        "callback counters completed={d} timed_out={d} events={d}\n",
        .{ callback_state.completed_checks, callback_state.timed_out_checks, callback_state.events },
    );
}

pub fn main() !void {
    try run();
}
