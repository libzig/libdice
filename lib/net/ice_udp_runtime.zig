const std = @import("std");
const candidate = @import("../core/candidate.zig");
const conncheck = @import("../core/conncheck.zig");
const ice_runtime = @import("../core/ice_runtime.zig");
const udp_dispatch = @import("udp_dispatch.zig");
const usage_ice = @import("../protocol/stun/usage_ice.zig");
const parser = @import("../protocol/stun/parser.zig");

pub const PollSummary = struct {
    packets_seen: usize,
    completed_checks: usize,
    ignored_packets: usize,
};

pub const AdvanceSummary = struct {
    poll: PollSummary,
    timed_out_checks: usize,
    failed_consents: usize,
};

pub const OutboundCheckOptions = usage_ice.ConnectivityCheckRequestOptions;

pub const SentCheck = struct {
    started: ice_runtime.StartedCheckDetailed,
    remote: candidate.Address,
    packet_len: usize,
};

pub const SentRetransmit = struct {
    due: ice_runtime.DueRetransmit,
    remote: candidate.Address,
    packet_len: usize,
};

pub const RequestHandlingSummary = struct {
    packets_seen: usize,
    requests_handled: usize,
    ignored_packets: usize,
};

pub const BidirectionalAdvanceOptions = struct {
    request_integrity_key: ?[]const u8 = null,
    response_options: usage_ice.ConnectivityCheckSuccessResponseOptions = .{},
};

pub const BidirectionalAdvanceSummary = struct {
    packets_seen: usize,
    completed_checks: usize,
    requests_handled: usize,
    ignored_packets: usize,
    timed_out_checks: usize,
    failed_consents: usize,
};

pub const IoTickOptions = struct {
    max_starts_per_tick: usize = 8,
    outbound_options: OutboundCheckOptions = .{},
    bidirectional_options: BidirectionalAdvanceOptions = .{},
};

pub const IoTickSummary = struct {
    started_checks: usize,
    retransmits_sent: usize,
    advance: BidirectionalAdvanceSummary,
};

pub const IoTickWithEventsSummary = struct {
    io: IoTickSummary,
    events_drained: usize,
};

pub const PumpOnceOptions = struct {
    io_tick: IoTickOptions = .{},
};

pub const PumpOnceSummary = struct {
    started_checks: usize,
    retransmits_sent: usize,
    packets_seen: usize,
    completed_checks: usize,
    requests_handled: usize,
    ignored_packets: usize,
    timed_out_checks: usize,
    failed_consents: usize,
    events_drained: usize,
};

pub const PumpHandlers = struct {
    on_completed: ?*const fn (ctx: *anyopaque, completed: conncheck.CompletedCheck) void = null,
    on_timed_out: ?*const fn (ctx: *anyopaque, timed_out: ice_runtime.TimedOutCheck) void = null,
    on_event: ?*const fn (ctx: *anyopaque, event: ice_runtime.IceEvent) void = null,
};

pub const DriveLoopStopReason = enum {
    quiescent,
    deadline_reached,
    max_ticks_reached,
};

pub const DriveLoopOptions = struct {
    io_tick: IoTickOptions = .{},
    stop_on_quiescent: bool = true,
    max_ticks: usize = 1024,
};

pub const DriveLoopSummary = struct {
    stop_reason: DriveLoopStopReason,
    ticks_run: usize,
    first_tick_ms: u64,
    last_tick_ms: u64,
    total_started_checks: usize,
    total_retransmits_sent: usize,
    total_packets_seen: usize,
    total_completed_checks: usize,
    total_requests_handled: usize,
    total_ignored_packets: usize,
    total_timed_out_checks: usize,
    total_failed_consents: usize,
    total_events_drained: usize,
    final_pending_transactions: usize,
    final_waiting_pairs: usize,
    final_in_progress_pairs: usize,
};

pub const IceUdpRuntimeBridge = struct {
    allocator: std.mem.Allocator,
    runtime: *ice_runtime.IceRuntime,
    dispatch: udp_dispatch.UdpDispatch,

    pub fn init(allocator: std.mem.Allocator, runtime: *ice_runtime.IceRuntime) IceUdpRuntimeBridge {
        return .{
            .allocator = allocator,
            .runtime = runtime,
            .dispatch = udp_dispatch.UdpDispatch.init(allocator),
        };
    }

    pub fn deinit(self: *IceUdpRuntimeBridge) void {
        self.dispatch.deinit();
    }

    pub fn add_binding(self: *IceUdpRuntimeBridge, stream_id: u32, component_id: u16, local: candidate.Address) !candidate.Address {
        return self.dispatch.add_binding(stream_id, component_id, local);
    }

    pub fn send(self: *IceUdpRuntimeBridge, stream_id: u32, component_id: u16, remote: candidate.Address, payload: []const u8) !usize {
        return self.dispatch.send(stream_id, component_id, remote, payload);
    }

    pub fn start_and_send_next_check(
        self: *IceUdpRuntimeBridge,
        random: std.Random,
        now_ms: u64,
        packet_buf: []u8,
        options: OutboundCheckOptions,
    ) !?SentCheck {
        const started = try self.runtime.start_next_check_any_detailed(random, now_ms) orelse return null;

        const remote_candidate = try self.runtime.agent.find_remote_candidate_by_id(started.stream_id, started.remote_candidate_id);
        const packet = try usage_ice.build_connectivity_check_request(packet_buf, started.transaction_id, options);
        _ = try self.dispatch.send(started.stream_id, started.component_id, remote_candidate.address, packet);

        return .{
            .started = started,
            .remote = remote_candidate.address,
            .packet_len = packet.len,
        };
    }

    pub fn poll_and_respond_connectivity_requests(
        self: *IceUdpRuntimeBridge,
        recv_buf: []u8,
        send_buf: []u8,
        request_integrity_key: ?[]const u8,
        response_options: usage_ice.ConnectivityCheckSuccessResponseOptions,
    ) !RequestHandlingSummary {
        var summary = RequestHandlingSummary{
            .packets_seen = 0,
            .requests_handled = 0,
            .ignored_packets = 0,
        };

        while (true) {
            const packet = try self.dispatch.recv_any(recv_buf) orelse break;
            summary.packets_seen += 1;

            const view = parser.parse_message(recv_buf[0..packet.bytes]) catch {
                summary.ignored_packets += 1;
                continue;
            };

            if (!usage_ice.is_connectivity_check_request(view)) {
                summary.ignored_packets += 1;
                continue;
            }

            _ = usage_ice.parse_connectivity_check_request(view, request_integrity_key) catch {
                summary.ignored_packets += 1;
                continue;
            };

            const response = try usage_ice.build_connectivity_check_success_response(send_buf, view.header.transaction_id, response_options);
            _ = try self.dispatch.send(packet.stream_id, packet.component_id, packet.from, response);
            summary.requests_handled += 1;
        }

        return summary;
    }

    pub fn poll_until_idle(
        self: *IceUdpRuntimeBridge,
        now_ms: u64,
        recv_buf: []u8,
        out_completed: []conncheck.CompletedCheck,
    ) !PollSummary {
        _ = self.allocator;

        var summary = PollSummary{
            .packets_seen = 0,
            .completed_checks = 0,
            .ignored_packets = 0,
        };

        while (true) {
            const packet = try self.dispatch.recv_any(recv_buf) orelse break;
            summary.packets_seen += 1;

            const view = parser.parse_message(recv_buf[0..packet.bytes]) catch {
                summary.ignored_packets += 1;
                continue;
            };

            const completed = self.runtime.on_response(packet.stream_id, packet.component_id, view, now_ms) catch |err| switch (err) {
                error.NotResponse,
                error.UnknownTransaction,
                error.NotFound,
                error.UnknownTransactionContext,
                => {
                    summary.ignored_packets += 1;
                    continue;
                },
                else => return err,
            };

            if (summary.completed_checks < out_completed.len) {
                out_completed[summary.completed_checks] = completed;
            }
            summary.completed_checks += 1;
        }

        return summary;
    }

    pub fn advance(
        self: *IceUdpRuntimeBridge,
        now_ms: u64,
        recv_buf: []u8,
        out_completed: []conncheck.CompletedCheck,
        out_timed_out: []ice_runtime.TimedOutCheck,
    ) !AdvanceSummary {
        const poll = try self.poll_until_idle(now_ms, recv_buf, out_completed);
        const timed_out_checks = try self.runtime.expire_all(now_ms, out_timed_out);
        const consent_tick = self.runtime.tick_consent_all(now_ms);

        return .{
            .poll = poll,
            .timed_out_checks = timed_out_checks,
            .failed_consents = consent_tick.failed_components,
        };
    }

    pub fn advance_bidirectional(
        self: *IceUdpRuntimeBridge,
        now_ms: u64,
        recv_buf: []u8,
        send_buf: []u8,
        out_completed: []conncheck.CompletedCheck,
        out_timed_out: []ice_runtime.TimedOutCheck,
        options: BidirectionalAdvanceOptions,
    ) !BidirectionalAdvanceSummary {
        var summary = BidirectionalAdvanceSummary{
            .packets_seen = 0,
            .completed_checks = 0,
            .requests_handled = 0,
            .ignored_packets = 0,
            .timed_out_checks = 0,
            .failed_consents = 0,
        };

        while (true) {
            const packet = try self.dispatch.recv_any(recv_buf) orelse break;
            summary.packets_seen += 1;

            const view = parser.parse_message(recv_buf[0..packet.bytes]) catch {
                summary.ignored_packets += 1;
                continue;
            };

            if (usage_ice.is_connectivity_check_request(view)) {
                _ = usage_ice.parse_connectivity_check_request(view, options.request_integrity_key) catch {
                    summary.ignored_packets += 1;
                    continue;
                };

                const response = try usage_ice.build_connectivity_check_success_response(send_buf, view.header.transaction_id, options.response_options);
                _ = try self.dispatch.send(packet.stream_id, packet.component_id, packet.from, response);
                summary.requests_handled += 1;
                continue;
            }

            const completed = self.runtime.on_response(packet.stream_id, packet.component_id, view, now_ms) catch |err| switch (err) {
                error.NotResponse,
                error.UnknownTransaction,
                error.NotFound,
                error.UnknownTransactionContext,
                => {
                    summary.ignored_packets += 1;
                    continue;
                },
                else => return err,
            };

            if (summary.completed_checks < out_completed.len) {
                out_completed[summary.completed_checks] = completed;
            }
            summary.completed_checks += 1;
        }

        summary.timed_out_checks = try self.runtime.expire_all(now_ms, out_timed_out);
        summary.failed_consents = self.runtime.tick_consent_all(now_ms).failed_components;
        return summary;
    }

    pub fn run_io_tick(
        self: *IceUdpRuntimeBridge,
        random: std.Random,
        now_ms: u64,
        outbound_packet_buf: []u8,
        recv_buf: []u8,
        send_buf: []u8,
        out_completed: []conncheck.CompletedCheck,
        out_timed_out: []ice_runtime.TimedOutCheck,
        options: IoTickOptions,
    ) !IoTickSummary {
        var started_checks: usize = 0;
        while (started_checks < options.max_starts_per_tick) {
            const maybe_sent = try self.start_and_send_next_check(
                random,
                now_ms,
                outbound_packet_buf,
                options.outbound_options,
            );
            if (maybe_sent == null) break;
            started_checks += 1;
        }

        var retransmit_sink: [0]SentRetransmit = .{};
        const retransmits_sent = try self.send_due_retransmits(
            now_ms,
            outbound_packet_buf,
            options.outbound_options,
            retransmit_sink[0..],
        );

        const advance_summary = try self.advance_bidirectional(
            now_ms,
            recv_buf,
            send_buf,
            out_completed,
            out_timed_out,
            options.bidirectional_options,
        );

        return .{
            .started_checks = started_checks,
            .retransmits_sent = retransmits_sent,
            .advance = advance_summary,
        };
    }

    pub fn run_until_quiescent_or_deadline(
        self: *IceUdpRuntimeBridge,
        random: std.Random,
        start_ms: u64,
        deadline_ms: u64,
        tick_step_ms: u64,
        outbound_packet_buf: []u8,
        recv_buf: []u8,
        send_buf: []u8,
        out_completed: []conncheck.CompletedCheck,
        out_timed_out: []ice_runtime.TimedOutCheck,
        out_events: []ice_runtime.IceEvent,
        options: DriveLoopOptions,
    ) !DriveLoopSummary {
        var now_ms = start_ms;
        var ticks_run: usize = 0;

        var total_started_checks: usize = 0;
        var total_retransmits_sent: usize = 0;
        var total_packets_seen: usize = 0;
        var total_completed_checks: usize = 0;
        var total_requests_handled: usize = 0;
        var total_ignored_packets: usize = 0;
        var total_timed_out_checks: usize = 0;
        var total_failed_consents: usize = 0;
        var total_events_drained: usize = 0;

        var stop_reason: DriveLoopStopReason = .deadline_reached;
        var last_tick_ms = start_ms;

        while (now_ms <= deadline_ms and ticks_run < options.max_ticks) {
            const tick = try self.run_io_tick(
                random,
                now_ms,
                outbound_packet_buf,
                recv_buf,
                send_buf,
                out_completed,
                out_timed_out,
                options.io_tick,
            );
            const events_drained = self.runtime.drain_events(out_events);

            ticks_run += 1;
            last_tick_ms = now_ms;
            total_started_checks += tick.started_checks;
            total_retransmits_sent += tick.retransmits_sent;
            total_packets_seen += tick.advance.packets_seen;
            total_completed_checks += tick.advance.completed_checks;
            total_requests_handled += tick.advance.requests_handled;
            total_ignored_packets += tick.advance.ignored_packets;
            total_timed_out_checks += tick.advance.timed_out_checks;
            total_failed_consents += tick.advance.failed_consents;
            total_events_drained += events_drained;

            const stats = self.runtime.stats();
            const progress_this_tick = tick.started_checks + tick.retransmits_sent + tick.advance.packets_seen + tick.advance.timed_out_checks + tick.advance.failed_consents;
            const runtime_pending = stats.pending_transactions + stats.waiting_pairs + stats.in_progress_pairs;

            if (options.stop_on_quiescent and progress_this_tick == 0 and runtime_pending == 0) {
                stop_reason = .quiescent;
                return .{
                    .stop_reason = stop_reason,
                    .ticks_run = ticks_run,
                    .first_tick_ms = start_ms,
                    .last_tick_ms = last_tick_ms,
                    .total_started_checks = total_started_checks,
                    .total_retransmits_sent = total_retransmits_sent,
                    .total_packets_seen = total_packets_seen,
                    .total_completed_checks = total_completed_checks,
                    .total_requests_handled = total_requests_handled,
                    .total_ignored_packets = total_ignored_packets,
                    .total_timed_out_checks = total_timed_out_checks,
                    .total_failed_consents = total_failed_consents,
                    .total_events_drained = total_events_drained,
                    .final_pending_transactions = stats.pending_transactions,
                    .final_waiting_pairs = stats.waiting_pairs,
                    .final_in_progress_pairs = stats.in_progress_pairs,
                };
            }

            now_ms +|= tick_step_ms;
        }

        if (ticks_run >= options.max_ticks and now_ms <= deadline_ms) {
            stop_reason = .max_ticks_reached;
        }

        const final_stats = self.runtime.stats();
        return .{
            .stop_reason = stop_reason,
            .ticks_run = ticks_run,
            .first_tick_ms = start_ms,
            .last_tick_ms = last_tick_ms,
            .total_started_checks = total_started_checks,
            .total_retransmits_sent = total_retransmits_sent,
            .total_packets_seen = total_packets_seen,
            .total_completed_checks = total_completed_checks,
            .total_requests_handled = total_requests_handled,
            .total_ignored_packets = total_ignored_packets,
            .total_timed_out_checks = total_timed_out_checks,
            .total_failed_consents = total_failed_consents,
            .total_events_drained = total_events_drained,
            .final_pending_transactions = final_stats.pending_transactions,
            .final_waiting_pairs = final_stats.waiting_pairs,
            .final_in_progress_pairs = final_stats.in_progress_pairs,
        };
    }

    pub fn run_io_tick_with_events(
        self: *IceUdpRuntimeBridge,
        random: std.Random,
        now_ms: u64,
        outbound_packet_buf: []u8,
        recv_buf: []u8,
        send_buf: []u8,
        out_completed: []conncheck.CompletedCheck,
        out_timed_out: []ice_runtime.TimedOutCheck,
        out_events: []ice_runtime.IceEvent,
        options: IoTickOptions,
    ) !IoTickWithEventsSummary {
        const io = try self.run_io_tick(
            random,
            now_ms,
            outbound_packet_buf,
            recv_buf,
            send_buf,
            out_completed,
            out_timed_out,
            options,
        );
        const events_drained = self.runtime.drain_events(out_events);
        return .{
            .io = io,
            .events_drained = events_drained,
        };
    }

    pub fn pump_once(
        self: *IceUdpRuntimeBridge,
        random: std.Random,
        now_ms: u64,
        outbound_packet_buf: []u8,
        recv_buf: []u8,
        send_buf: []u8,
        out_completed: []conncheck.CompletedCheck,
        out_timed_out: []ice_runtime.TimedOutCheck,
        out_events: []ice_runtime.IceEvent,
        options: PumpOnceOptions,
    ) !PumpOnceSummary {
        const tick = try self.run_io_tick_with_events(
            random,
            now_ms,
            outbound_packet_buf,
            recv_buf,
            send_buf,
            out_completed,
            out_timed_out,
            out_events,
            options.io_tick,
        );

        return .{
            .started_checks = tick.io.started_checks,
            .retransmits_sent = tick.io.retransmits_sent,
            .packets_seen = tick.io.advance.packets_seen,
            .completed_checks = tick.io.advance.completed_checks,
            .requests_handled = tick.io.advance.requests_handled,
            .ignored_packets = tick.io.advance.ignored_packets,
            .timed_out_checks = tick.io.advance.timed_out_checks,
            .failed_consents = tick.io.advance.failed_consents,
            .events_drained = tick.events_drained,
        };
    }

    pub fn pump_once_with_handlers(
        self: *IceUdpRuntimeBridge,
        random: std.Random,
        now_ms: u64,
        outbound_packet_buf: []u8,
        recv_buf: []u8,
        send_buf: []u8,
        out_completed: []conncheck.CompletedCheck,
        out_timed_out: []ice_runtime.TimedOutCheck,
        out_events: []ice_runtime.IceEvent,
        callback_ctx: *anyopaque,
        handlers: PumpHandlers,
        options: PumpOnceOptions,
    ) !PumpOnceSummary {
        const summary = try self.pump_once(
            random,
            now_ms,
            outbound_packet_buf,
            recv_buf,
            send_buf,
            out_completed,
            out_timed_out,
            out_events,
            options,
        );

        const completed_count = @min(summary.completed_checks, out_completed.len);
        const timed_out_count = @min(summary.timed_out_checks, out_timed_out.len);
        const event_count = @min(summary.events_drained, out_events.len);

        if (handlers.on_completed) |callback| {
            for (out_completed[0..completed_count]) |completed| {
                callback(callback_ctx, completed);
            }
        }

        if (handlers.on_timed_out) |callback| {
            for (out_timed_out[0..timed_out_count]) |timed_out| {
                callback(callback_ctx, timed_out);
            }
        }

        if (handlers.on_event) |callback| {
            for (out_events[0..event_count]) |event| {
                callback(callback_ctx, event);
            }
        }

        return summary;
    }

    pub fn send_due_retransmits(
        self: *IceUdpRuntimeBridge,
        now_ms: u64,
        packet_buf: []u8,
        options: OutboundCheckOptions,
        out_sent: []SentRetransmit,
    ) !usize {
        const max_due = if (out_sent.len > 0) out_sent.len else 16;
        var due = try self.allocator.alloc(ice_runtime.DueRetransmit, max_due);
        defer self.allocator.free(due);

        const count = try self.runtime.collect_due_retransmits_all(now_ms, due);
        var written: usize = 0;

        for (due[0..@min(due.len, count)]) |item| {
            const remote_candidate = try self.runtime.agent.find_remote_candidate_by_id(item.stream_id, item.remote_candidate_id);
            const packet = try usage_ice.build_connectivity_check_request(packet_buf, item.transaction_id, options);
            _ = try self.dispatch.send(item.stream_id, item.component_id, remote_candidate.address, packet);
            try self.runtime.mark_retransmitted(item.stream_id, item.component_id, item.transaction_id, now_ms);

            if (written < out_sent.len) {
                out_sent[written] = .{
                    .due = item,
                    .remote = remote_candidate.address,
                    .packet_len = packet.len,
                };
            }
            written += 1;
        }

        return written;
    }
};

test "udp bridge routes stun response into ice runtime" {
    var agent = @import("../core/agent.zig").Agent.init(std.testing.allocator);
    defer agent.deinit();

    const stream_id = try agent.add_stream(1);
    const local_addr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 200 }, .port = 5000 } };
    const remote_addr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 198, 51, 100, 200 }, .port = 6000 } };

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

    var runtime = ice_runtime.IceRuntime.init(std.testing.allocator, &agent, .{}, .{}, .aggressive);
    defer runtime.deinit();
    try std.testing.expect(try runtime.attach_stream(stream_id));
    _ = try runtime.populate_stream_checklists(stream_id, true, 1000);
    try runtime.start_connecting_all();

    var bridge = IceUdpRuntimeBridge.init(std.testing.allocator, &runtime);
    defer bridge.deinit();

    const bound = try bridge.add_binding(stream_id, 1, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });

    var prng = std.Random.DefaultPrng.init(30);
    const started = (try runtime.start_next_check_any(prng.random(), 0)).?;

    var peer = @import("udp_socket.zig").UdpSocket.bind(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } }) catch unreachable;
    defer peer.deinit();

    var packet: [20]u8 = undefined;
    const header = @import("../protocol/stun/message.zig").Header.init(0x0101, 0, started.transaction_id);
    _ = try header.encode(&packet);
    _ = try peer.send_to(bound, &packet);

    var recv_buf: [256]u8 = undefined;
    var completed: [4]conncheck.CompletedCheck = undefined;
    const summary = try bridge.poll_until_idle(20, &recv_buf, &completed);

    try std.testing.expectEqual(@as(usize, 1), summary.completed_checks);
    try std.testing.expectEqual(@as(u64, 1000), completed[0].meta.candidate_pair_id);
}

test "udp bridge ignores malformed packets" {
    var agent = @import("../core/agent.zig").Agent.init(std.testing.allocator);
    defer agent.deinit();

    const stream_id = try agent.add_stream(1);
    var runtime = ice_runtime.IceRuntime.init(std.testing.allocator, &agent, .{}, .{}, .regular);
    defer runtime.deinit();
    try std.testing.expect(try runtime.attach_stream(stream_id));

    var bridge = IceUdpRuntimeBridge.init(std.testing.allocator, &runtime);
    defer bridge.deinit();

    const bound = try bridge.add_binding(stream_id, 1, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    var peer = try @import("udp_socket.zig").UdpSocket.bind(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer peer.deinit();

    _ = try peer.send_to(bound, "not-a-stun-packet");

    var recv_buf: [256]u8 = undefined;
    var completed: [2]conncheck.CompletedCheck = undefined;
    const summary = try bridge.poll_until_idle(10, &recv_buf, &completed);
    try std.testing.expectEqual(@as(usize, 0), summary.completed_checks);
    try std.testing.expect(summary.ignored_packets >= 1);
}

test "udp bridge advance reports timed out check" {
    var agent = @import("../core/agent.zig").Agent.init(std.testing.allocator);
    defer agent.deinit();

    const stream_id = try agent.add_stream(1);
    const local_addr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 201 }, .port = 5000 } };
    const remote_addr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 198, 51, 100, 201 }, .port = 6000 } };

    try std.testing.expect(try agent.add_local_candidate(stream_id, .{
        .id = 10,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .host, local_addr),
        .priority = candidate.compute_candidate_priority(.host, 100, 1),
        .address = local_addr,
    }));
    try std.testing.expect(try agent.add_remote_candidate(stream_id, .{
        .id = 11,
        .component_id = 1,
        .candidate_type = .srflx,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .srflx, remote_addr),
        .priority = candidate.compute_candidate_priority(.srflx, 90, 1),
        .address = remote_addr,
    }));

    var runtime = ice_runtime.IceRuntime.init(std.testing.allocator, &agent, .{ .base_rto_ms = 100, .max_retransmits = 1 }, .{}, .regular);
    defer runtime.deinit();
    try std.testing.expect(try runtime.attach_stream(stream_id));
    _ = try runtime.populate_stream_checklists(stream_id, true, 2000);
    try runtime.start_connecting_all();

    var prng = std.Random.DefaultPrng.init(31);
    _ = try runtime.start_next_check_any(prng.random(), 0);

    var bridge = IceUdpRuntimeBridge.init(std.testing.allocator, &runtime);
    defer bridge.deinit();

    var recv_buf: [256]u8 = undefined;
    var completed: [2]conncheck.CompletedCheck = undefined;
    var timed_out: [2]ice_runtime.TimedOutCheck = undefined;
    const summary = try bridge.advance(10_000, &recv_buf, &completed, &timed_out);

    try std.testing.expectEqual(@as(usize, 0), summary.poll.completed_checks);
    try std.testing.expect(summary.timed_out_checks >= 1);
}

test "udp bridge start_and_send_next_check sends connectivity request" {
    var agent = @import("../core/agent.zig").Agent.init(std.testing.allocator);
    defer agent.deinit();

    const stream_id = try agent.add_stream(1);
    const local_addr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 202 }, .port = 5000 } };
    var peer = try @import("udp_socket.zig").UdpSocket.bind(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer peer.deinit();
    const peer_addr = try peer.local_address();

    try std.testing.expect(try agent.add_local_candidate(stream_id, .{
        .id = 21,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .host, local_addr),
        .priority = candidate.compute_candidate_priority(.host, 100, 1),
        .address = local_addr,
    }));
    try std.testing.expect(try agent.add_remote_candidate(stream_id, .{
        .id = 22,
        .component_id = 1,
        .candidate_type = .srflx,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .srflx, peer_addr),
        .priority = candidate.compute_candidate_priority(.srflx, 90, 1),
        .address = peer_addr,
    }));

    var runtime = ice_runtime.IceRuntime.init(std.testing.allocator, &agent, .{}, .{}, .regular);
    defer runtime.deinit();
    try std.testing.expect(try runtime.attach_stream(stream_id));
    _ = try runtime.populate_stream_checklists(stream_id, true, 3000);
    try runtime.start_connecting_all();

    var bridge = IceUdpRuntimeBridge.init(std.testing.allocator, &runtime);
    defer bridge.deinit();
    _ = try bridge.add_binding(stream_id, 1, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });

    var prng = std.Random.DefaultPrng.init(32);
    var packet_buf: [256]u8 = undefined;
    const sent = (try bridge.start_and_send_next_check(prng.random(), 0, &packet_buf, .{
        .username = "local:remote",
        .priority = 1234,
        .role = .{ .role = .controlling, .tie_breaker = 42 },
        .use_candidate = true,
    })).?;

    var recv_buf: [256]u8 = undefined;
    const recv = try peer.recv_from(&recv_buf);
    try std.testing.expectEqual(sent.packet_len, recv.bytes);
    const view = try parser.parse_message(recv_buf[0..recv.bytes]);
    try std.testing.expect(usage_ice.is_connectivity_check_request(view));
    try std.testing.expectEqualSlices(u8, &sent.started.transaction_id, &view.header.transaction_id);
}

test "udp bridge responds to inbound connectivity check request" {
    var agent = @import("../core/agent.zig").Agent.init(std.testing.allocator);
    defer agent.deinit();

    const stream_id = try agent.add_stream(1);
    var runtime = ice_runtime.IceRuntime.init(std.testing.allocator, &agent, .{}, .{}, .regular);
    defer runtime.deinit();
    try std.testing.expect(try runtime.attach_stream(stream_id));

    var bridge = IceUdpRuntimeBridge.init(std.testing.allocator, &runtime);
    defer bridge.deinit();
    const bound = try bridge.add_binding(stream_id, 1, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });

    var peer = try @import("udp_socket.zig").UdpSocket.bind(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer peer.deinit();

    const tx_id = [_]u8{ 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 };
    var req_buf: [256]u8 = undefined;
    const request = try usage_ice.build_connectivity_check_request(&req_buf, tx_id, .{
        .username = "r:l",
        .priority = 99,
        .role = .{ .role = .controlling, .tie_breaker = 777 },
        .use_candidate = true,
    });
    _ = try peer.send_to(bound, request);

    var recv_buf: [256]u8 = undefined;
    var send_buf: [256]u8 = undefined;
    const handled = try bridge.poll_and_respond_connectivity_requests(&recv_buf, &send_buf, null, .{});
    try std.testing.expectEqual(@as(usize, 1), handled.requests_handled);

    var response_buf: [256]u8 = undefined;
    const response_recv = try peer.recv_from(&response_buf);
    const response_view = try parser.parse_message(response_buf[0..response_recv.bytes]);
    try std.testing.expect(usage_ice.is_connectivity_check_success_response(response_view));
    try std.testing.expectEqualSlices(u8, &tx_id, &response_view.header.transaction_id);
}

test "udp bridge full check lifecycle with outbound send and inbound response" {
    var agent = @import("../core/agent.zig").Agent.init(std.testing.allocator);
    defer agent.deinit();

    const stream_id = try agent.add_stream(1);
    const local_addr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 203 }, .port = 5000 } };
    var peer = try @import("udp_socket.zig").UdpSocket.bind(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer peer.deinit();
    const peer_addr = try peer.local_address();

    try std.testing.expect(try agent.add_local_candidate(stream_id, .{
        .id = 31,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .host, local_addr),
        .priority = candidate.compute_candidate_priority(.host, 100, 1),
        .address = local_addr,
    }));
    try std.testing.expect(try agent.add_remote_candidate(stream_id, .{
        .id = 32,
        .component_id = 1,
        .candidate_type = .srflx,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .srflx, peer_addr),
        .priority = candidate.compute_candidate_priority(.srflx, 90, 1),
        .address = peer_addr,
    }));

    var runtime = ice_runtime.IceRuntime.init(std.testing.allocator, &agent, .{}, .{}, .aggressive);
    defer runtime.deinit();
    try std.testing.expect(try runtime.attach_stream(stream_id));
    _ = try runtime.populate_stream_checklists(stream_id, true, 4000);
    try runtime.start_connecting_all();

    var bridge = IceUdpRuntimeBridge.init(std.testing.allocator, &runtime);
    defer bridge.deinit();
    _ = try bridge.add_binding(stream_id, 1, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });

    var prng = std.Random.DefaultPrng.init(33);
    var packet_buf: [256]u8 = undefined;
    const sent = (try bridge.start_and_send_next_check(prng.random(), 0, &packet_buf, .{
        .username = "l:r",
        .priority = 123,
        .role = .{ .role = .controlling, .tie_breaker = 1 },
        .use_candidate = true,
    })).?;

    var request_buf: [256]u8 = undefined;
    const request_recv = try peer.recv_from(&request_buf);
    const request_view = try parser.parse_message(request_buf[0..request_recv.bytes]);
    try std.testing.expect(usage_ice.is_connectivity_check_request(request_view));

    var response_buf: [256]u8 = undefined;
    const response = try usage_ice.build_connectivity_check_success_response(&response_buf, sent.started.transaction_id, .{});
    _ = try peer.send_to(request_recv.from, response);

    var bridge_recv: [256]u8 = undefined;
    var completed: [2]conncheck.CompletedCheck = undefined;
    var timed_out: [2]ice_runtime.TimedOutCheck = undefined;
    const summary = try bridge.advance(100, &bridge_recv, &completed, &timed_out);

    try std.testing.expectEqual(@as(usize, 1), summary.poll.completed_checks);
    try std.testing.expectEqual(@as(u64, 4000), completed[0].meta.candidate_pair_id);
}

test "udp bridge bidirectional advance handles request and response" {
    var agent = @import("../core/agent.zig").Agent.init(std.testing.allocator);
    defer agent.deinit();

    const stream_id = try agent.add_stream(1);
    const local_addr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 204 }, .port = 5000 } };
    var peer = try @import("udp_socket.zig").UdpSocket.bind(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer peer.deinit();
    const peer_addr = try peer.local_address();

    try std.testing.expect(try agent.add_local_candidate(stream_id, .{
        .id = 41,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .host, local_addr),
        .priority = candidate.compute_candidate_priority(.host, 100, 1),
        .address = local_addr,
    }));
    try std.testing.expect(try agent.add_remote_candidate(stream_id, .{
        .id = 42,
        .component_id = 1,
        .candidate_type = .srflx,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .srflx, peer_addr),
        .priority = candidate.compute_candidate_priority(.srflx, 90, 1),
        .address = peer_addr,
    }));

    var runtime = ice_runtime.IceRuntime.init(std.testing.allocator, &agent, .{}, .{}, .regular);
    defer runtime.deinit();
    try std.testing.expect(try runtime.attach_stream(stream_id));
    _ = try runtime.populate_stream_checklists(stream_id, true, 5000);
    try runtime.start_connecting_all();

    var bridge = IceUdpRuntimeBridge.init(std.testing.allocator, &runtime);
    defer bridge.deinit();
    _ = try bridge.add_binding(stream_id, 1, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });

    var prng = std.Random.DefaultPrng.init(34);
    var tx_buf: [256]u8 = undefined;
    const sent = (try bridge.start_and_send_next_check(prng.random(), 0, &tx_buf, .{
        .username = "l:r",
        .priority = 321,
        .role = .{ .role = .controlling, .tie_breaker = 2 },
    })).?;

    var request_from_bridge: [256]u8 = undefined;
    const recv1 = try peer.recv_from(&request_from_bridge);
    const request_view = try parser.parse_message(request_from_bridge[0..recv1.bytes]);
    try std.testing.expect(usage_ice.is_connectivity_check_request(request_view));

    var success_buf: [256]u8 = undefined;
    const success = try usage_ice.build_connectivity_check_success_response(&success_buf, sent.started.transaction_id, .{});
    _ = try peer.send_to(recv1.from, success);

    const inbound_tx = [_]u8{ 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 100, 101 };
    var inbound_req_buf: [256]u8 = undefined;
    const inbound_req = try usage_ice.build_connectivity_check_request(&inbound_req_buf, inbound_tx, .{
        .username = "p:q",
        .priority = 777,
        .role = .{ .role = .controlling, .tie_breaker = 5 },
    });
    _ = try peer.send_to(recv1.from, inbound_req);

    var recv_buf: [256]u8 = undefined;
    var send_buf: [256]u8 = undefined;
    var completed: [4]conncheck.CompletedCheck = undefined;
    var timed_out: [2]ice_runtime.TimedOutCheck = undefined;
    const summary = try bridge.advance_bidirectional(120, &recv_buf, &send_buf, &completed, &timed_out, .{});

    try std.testing.expectEqual(@as(usize, 1), summary.completed_checks);
    try std.testing.expectEqual(@as(usize, 1), summary.requests_handled);
    try std.testing.expectEqual(@as(u64, 5000), completed[0].meta.candidate_pair_id);

    var response_to_inbound_buf: [256]u8 = undefined;
    const recv2 = try peer.recv_from(&response_to_inbound_buf);
    const response_to_inbound = try parser.parse_message(response_to_inbound_buf[0..recv2.bytes]);
    try std.testing.expect(usage_ice.is_connectivity_check_success_response(response_to_inbound));
    try std.testing.expectEqualSlices(u8, &inbound_tx, &response_to_inbound.header.transaction_id);
}

test "udp bridge io tick starts outbound checks and drains inbound traffic" {
    var agent = @import("../core/agent.zig").Agent.init(std.testing.allocator);
    defer agent.deinit();

    const stream_id = try agent.add_stream(1);
    const local_addr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 205 }, .port = 5000 } };
    var peer = try @import("udp_socket.zig").UdpSocket.bind(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer peer.deinit();
    const peer_addr = try peer.local_address();

    try std.testing.expect(try agent.add_local_candidate(stream_id, .{
        .id = 51,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .host, local_addr),
        .priority = candidate.compute_candidate_priority(.host, 100, 1),
        .address = local_addr,
    }));
    try std.testing.expect(try agent.add_remote_candidate(stream_id, .{
        .id = 52,
        .component_id = 1,
        .candidate_type = .srflx,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .srflx, peer_addr),
        .priority = candidate.compute_candidate_priority(.srflx, 90, 1),
        .address = peer_addr,
    }));

    var runtime = ice_runtime.IceRuntime.init(std.testing.allocator, &agent, .{}, .{}, .regular);
    defer runtime.deinit();
    try std.testing.expect(try runtime.attach_stream(stream_id));
    _ = try runtime.populate_stream_checklists(stream_id, true, 6000);
    try runtime.start_connecting_all();

    var bridge = IceUdpRuntimeBridge.init(std.testing.allocator, &runtime);
    defer bridge.deinit();
    _ = try bridge.add_binding(stream_id, 1, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });

    var prng = std.Random.DefaultPrng.init(35);
    var outbound_packet_buf: [256]u8 = undefined;
    var recv_buf: [256]u8 = undefined;
    var send_buf: [256]u8 = undefined;
    var completed: [4]conncheck.CompletedCheck = undefined;
    var timed_out: [2]ice_runtime.TimedOutCheck = undefined;

    const tick = try bridge.run_io_tick(
        prng.random(),
        0,
        &outbound_packet_buf,
        &recv_buf,
        &send_buf,
        &completed,
        &timed_out,
        .{
            .max_starts_per_tick = 4,
            .outbound_options = .{
                .username = "l:r",
                .priority = 456,
                .role = .{ .role = .controlling, .tie_breaker = 3 },
            },
        },
    );
    try std.testing.expectEqual(@as(usize, 1), tick.started_checks);
    try std.testing.expectEqual(@as(usize, 0), tick.retransmits_sent);

    var request_buf: [256]u8 = undefined;
    const request_recv = try peer.recv_from(&request_buf);
    const request_view = try parser.parse_message(request_buf[0..request_recv.bytes]);
    try std.testing.expect(usage_ice.is_connectivity_check_request(request_view));

    var response_buf: [256]u8 = undefined;
    const response = try usage_ice.build_connectivity_check_success_response(&response_buf, request_view.header.transaction_id, .{});
    _ = try peer.send_to(request_recv.from, response);

    const advanced = try bridge.advance_bidirectional(100, &recv_buf, &send_buf, &completed, &timed_out, .{});
    try std.testing.expectEqual(@as(usize, 1), advanced.completed_checks);
    try std.testing.expectEqual(@as(u64, 6000), completed[0].meta.candidate_pair_id);
}

test "udp bridge sends due retransmits" {
    var agent = @import("../core/agent.zig").Agent.init(std.testing.allocator);
    defer agent.deinit();

    const stream_id = try agent.add_stream(1);
    const local_addr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 206 }, .port = 5000 } };
    var peer = try @import("udp_socket.zig").UdpSocket.bind(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer peer.deinit();
    const peer_addr = try peer.local_address();

    try std.testing.expect(try agent.add_local_candidate(stream_id, .{
        .id = 61,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .host, local_addr),
        .priority = candidate.compute_candidate_priority(.host, 100, 1),
        .address = local_addr,
    }));
    try std.testing.expect(try agent.add_remote_candidate(stream_id, .{
        .id = 62,
        .component_id = 1,
        .candidate_type = .srflx,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .srflx, peer_addr),
        .priority = candidate.compute_candidate_priority(.srflx, 90, 1),
        .address = peer_addr,
    }));

    var runtime = ice_runtime.IceRuntime.init(std.testing.allocator, &agent, .{ .base_rto_ms = 100, .max_retransmits = 2 }, .{}, .regular);
    defer runtime.deinit();
    try std.testing.expect(try runtime.attach_stream(stream_id));
    _ = try runtime.populate_stream_checklists(stream_id, true, 7000);
    try runtime.start_connecting_all();

    var bridge = IceUdpRuntimeBridge.init(std.testing.allocator, &runtime);
    defer bridge.deinit();
    _ = try bridge.add_binding(stream_id, 1, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });

    var prng = std.Random.DefaultPrng.init(39);
    var out_packet_buf: [256]u8 = undefined;
    _ = (try bridge.start_and_send_next_check(prng.random(), 0, &out_packet_buf, .{
        .username = "l:r",
        .priority = 1,
        .role = .{ .role = .controlling, .tie_breaker = 9 },
    })).?;

    var first_request: [256]u8 = undefined;
    _ = try peer.recv_from(&first_request);

    var sent: [2]SentRetransmit = undefined;
    const retransmits = try bridge.send_due_retransmits(100, &out_packet_buf, .{
        .username = "l:r",
        .priority = 1,
        .role = .{ .role = .controlling, .tie_breaker = 9 },
    }, &sent);
    try std.testing.expectEqual(@as(usize, 1), retransmits);

    var second_request: [256]u8 = undefined;
    const recv2 = try peer.recv_from(&second_request);
    const view2 = try parser.parse_message(second_request[0..recv2.bytes]);
    try std.testing.expect(usage_ice.is_connectivity_check_request(view2));
}

test "udp bridge drive loop stops on quiescent runtime" {
    var agent = @import("../core/agent.zig").Agent.init(std.testing.allocator);
    defer agent.deinit();

    const stream_id = try agent.add_stream(1);
    var runtime = ice_runtime.IceRuntime.init(std.testing.allocator, &agent, .{}, .{}, .regular);
    defer runtime.deinit();
    try std.testing.expect(try runtime.attach_stream(stream_id));

    var bridge = IceUdpRuntimeBridge.init(std.testing.allocator, &runtime);
    defer bridge.deinit();

    var prng = std.Random.DefaultPrng.init(40);
    var outbound_buf: [256]u8 = undefined;
    var recv_buf: [256]u8 = undefined;
    var send_buf: [256]u8 = undefined;
    var completed: [2]conncheck.CompletedCheck = undefined;
    var timed_out: [2]ice_runtime.TimedOutCheck = undefined;
    var events: [8]ice_runtime.IceEvent = undefined;

    const loop = try bridge.run_until_quiescent_or_deadline(
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

    try std.testing.expectEqual(DriveLoopStopReason.quiescent, loop.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), loop.ticks_run);
    try std.testing.expectEqual(@as(usize, 0), loop.final_pending_transactions);
}

test "udp bridge drive loop reaches deadline when checks remain pending" {
    var agent = @import("../core/agent.zig").Agent.init(std.testing.allocator);
    defer agent.deinit();

    const stream_id = try agent.add_stream(1);
    const local_addr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 207 }, .port = 5000 } };
    const remote_addr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 198, 51, 100, 207 }, .port = 6000 } };
    try std.testing.expect(try agent.add_local_candidate(stream_id, .{
        .id = 71,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .host, local_addr),
        .priority = candidate.compute_candidate_priority(.host, 100, 1),
        .address = local_addr,
    }));
    try std.testing.expect(try agent.add_remote_candidate(stream_id, .{
        .id = 72,
        .component_id = 1,
        .candidate_type = .srflx,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .srflx, remote_addr),
        .priority = candidate.compute_candidate_priority(.srflx, 90, 1),
        .address = remote_addr,
    }));

    var runtime = ice_runtime.IceRuntime.init(std.testing.allocator, &agent, .{ .base_rto_ms = 500, .max_retransmits = 3 }, .{}, .regular);
    defer runtime.deinit();
    try std.testing.expect(try runtime.attach_stream(stream_id));
    _ = try runtime.populate_stream_checklists(stream_id, true, 8000);
    try runtime.start_connecting_all();

    var prng = std.Random.DefaultPrng.init(41);
    _ = try runtime.start_next_check_any(prng.random(), 0);

    var bridge = IceUdpRuntimeBridge.init(std.testing.allocator, &runtime);
    defer bridge.deinit();

    var outbound_buf: [256]u8 = undefined;
    var recv_buf: [256]u8 = undefined;
    var send_buf: [256]u8 = undefined;
    var completed: [2]conncheck.CompletedCheck = undefined;
    var timed_out: [2]ice_runtime.TimedOutCheck = undefined;
    var events: [16]ice_runtime.IceEvent = undefined;

    const loop = try bridge.run_until_quiescent_or_deadline(
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

    try std.testing.expectEqual(DriveLoopStopReason.deadline_reached, loop.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), loop.ticks_run);
    try std.testing.expect(loop.final_pending_transactions > 0);
}

test "udp bridge io tick with events drains started-check event" {
    var agent = @import("../core/agent.zig").Agent.init(std.testing.allocator);
    defer agent.deinit();

    const stream_id = try agent.add_stream(1);
    const local_addr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 208 }, .port = 5000 } };
    var peer = try @import("udp_socket.zig").UdpSocket.bind(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer peer.deinit();
    const peer_addr = try peer.local_address();

    try std.testing.expect(try agent.add_local_candidate(stream_id, .{
        .id = 81,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .host, local_addr),
        .priority = candidate.compute_candidate_priority(.host, 100, 1),
        .address = local_addr,
    }));
    try std.testing.expect(try agent.add_remote_candidate(stream_id, .{
        .id = 82,
        .component_id = 1,
        .candidate_type = .srflx,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .srflx, peer_addr),
        .priority = candidate.compute_candidate_priority(.srflx, 90, 1),
        .address = peer_addr,
    }));

    var runtime = ice_runtime.IceRuntime.init(std.testing.allocator, &agent, .{}, .{}, .regular);
    defer runtime.deinit();
    try std.testing.expect(try runtime.attach_stream(stream_id));
    _ = try runtime.populate_stream_checklists(stream_id, true, 9000);
    try runtime.start_connecting_all();

    var bridge = IceUdpRuntimeBridge.init(std.testing.allocator, &runtime);
    defer bridge.deinit();
    _ = try bridge.add_binding(stream_id, 1, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });

    var prng = std.Random.DefaultPrng.init(42);
    var outbound_buf: [256]u8 = undefined;
    var recv_buf: [256]u8 = undefined;
    var send_buf: [256]u8 = undefined;
    var completed: [2]conncheck.CompletedCheck = undefined;
    var timed_out: [2]ice_runtime.TimedOutCheck = undefined;
    var events: [16]ice_runtime.IceEvent = undefined;

    const tick = try bridge.run_io_tick_with_events(
        prng.random(),
        0,
        &outbound_buf,
        &recv_buf,
        &send_buf,
        &completed,
        &timed_out,
        &events,
        .{
            .max_starts_per_tick = 1,
            .outbound_options = .{
                .username = "l:r",
                .priority = 88,
                .role = .{ .role = .controlling, .tie_breaker = 11 },
            },
        },
    );

    try std.testing.expectEqual(@as(usize, 1), tick.io.started_checks);
    try std.testing.expect(tick.events_drained >= 1);
}

test "udp bridge pump once returns flattened counts" {
    var agent = @import("../core/agent.zig").Agent.init(std.testing.allocator);
    defer agent.deinit();

    const stream_id = try agent.add_stream(1);
    const local_addr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 209 }, .port = 5000 } };
    var peer = try @import("udp_socket.zig").UdpSocket.bind(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer peer.deinit();
    const peer_addr = try peer.local_address();

    try std.testing.expect(try agent.add_local_candidate(stream_id, .{
        .id = 91,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .host, local_addr),
        .priority = candidate.compute_candidate_priority(.host, 100, 1),
        .address = local_addr,
    }));
    try std.testing.expect(try agent.add_remote_candidate(stream_id, .{
        .id = 92,
        .component_id = 1,
        .candidate_type = .srflx,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .srflx, peer_addr),
        .priority = candidate.compute_candidate_priority(.srflx, 90, 1),
        .address = peer_addr,
    }));

    var runtime = ice_runtime.IceRuntime.init(std.testing.allocator, &agent, .{}, .{}, .regular);
    defer runtime.deinit();
    try std.testing.expect(try runtime.attach_stream(stream_id));
    _ = try runtime.populate_stream_checklists(stream_id, true, 10_000);
    try runtime.start_connecting_all();

    var bridge = IceUdpRuntimeBridge.init(std.testing.allocator, &runtime);
    defer bridge.deinit();
    _ = try bridge.add_binding(stream_id, 1, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });

    var prng = std.Random.DefaultPrng.init(43);
    var outbound_buf: [256]u8 = undefined;
    var recv_buf: [256]u8 = undefined;
    var send_buf: [256]u8 = undefined;
    var completed: [2]conncheck.CompletedCheck = undefined;
    var timed_out: [2]ice_runtime.TimedOutCheck = undefined;
    var events: [16]ice_runtime.IceEvent = undefined;

    const first = try bridge.pump_once(
        prng.random(),
        0,
        &outbound_buf,
        &recv_buf,
        &send_buf,
        &completed,
        &timed_out,
        &events,
        .{ .io_tick = .{ .max_starts_per_tick = 1, .outbound_options = .{ .username = "l:r", .priority = 22, .role = .{ .role = .controlling, .tie_breaker = 8 } } } },
    );
    try std.testing.expectEqual(@as(usize, 1), first.started_checks);
    try std.testing.expect(first.events_drained >= 1);

    var request_buf: [256]u8 = undefined;
    const request_recv = try peer.recv_from(&request_buf);
    const request_view = try parser.parse_message(request_buf[0..request_recv.bytes]);

    var response_buf: [256]u8 = undefined;
    const response = try usage_ice.build_connectivity_check_success_response(&response_buf, request_view.header.transaction_id, .{});
    _ = try peer.send_to(request_recv.from, response);

    const second = try bridge.pump_once(
        prng.random(),
        100,
        &outbound_buf,
        &recv_buf,
        &send_buf,
        &completed,
        &timed_out,
        &events,
        .{ .io_tick = .{ .max_starts_per_tick = 0 } },
    );
    try std.testing.expectEqual(@as(usize, 1), second.completed_checks);
}

test "udp bridge pump once with handlers invokes callbacks" {
    const CallbackState = struct {
        completed: usize = 0,
        timed_out: usize = 0,
        events: usize = 0,
    };

    const callbacks = struct {
        fn on_completed(ctx: *anyopaque, _: conncheck.CompletedCheck) void {
            const state: *CallbackState = @ptrCast(@alignCast(ctx));
            state.completed += 1;
        }

        fn on_timed_out(ctx: *anyopaque, _: ice_runtime.TimedOutCheck) void {
            const state: *CallbackState = @ptrCast(@alignCast(ctx));
            state.timed_out += 1;
        }

        fn on_event(ctx: *anyopaque, _: ice_runtime.IceEvent) void {
            const state: *CallbackState = @ptrCast(@alignCast(ctx));
            state.events += 1;
        }
    };

    var agent = @import("../core/agent.zig").Agent.init(std.testing.allocator);
    defer agent.deinit();

    const stream_id = try agent.add_stream(1);
    const local_addr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 210 }, .port = 5000 } };
    var peer = try @import("udp_socket.zig").UdpSocket.bind(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer peer.deinit();
    const peer_addr = try peer.local_address();

    try std.testing.expect(try agent.add_local_candidate(stream_id, .{
        .id = 101,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .host, local_addr),
        .priority = candidate.compute_candidate_priority(.host, 100, 1),
        .address = local_addr,
    }));
    try std.testing.expect(try agent.add_remote_candidate(stream_id, .{
        .id = 102,
        .component_id = 1,
        .candidate_type = .srflx,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .srflx, peer_addr),
        .priority = candidate.compute_candidate_priority(.srflx, 90, 1),
        .address = peer_addr,
    }));

    var runtime = ice_runtime.IceRuntime.init(std.testing.allocator, &agent, .{}, .{}, .regular);
    defer runtime.deinit();
    try std.testing.expect(try runtime.attach_stream(stream_id));
    _ = try runtime.populate_stream_checklists(stream_id, true, 11_000);
    try runtime.start_connecting_all();

    var bridge = IceUdpRuntimeBridge.init(std.testing.allocator, &runtime);
    defer bridge.deinit();
    _ = try bridge.add_binding(stream_id, 1, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });

    var state = CallbackState{};
    var prng = std.Random.DefaultPrng.init(44);
    var outbound_buf: [256]u8 = undefined;
    var recv_buf: [256]u8 = undefined;
    var send_buf: [256]u8 = undefined;
    var completed: [2]conncheck.CompletedCheck = undefined;
    var timed_out: [2]ice_runtime.TimedOutCheck = undefined;
    var events: [16]ice_runtime.IceEvent = undefined;

    _ = try bridge.pump_once_with_handlers(
        prng.random(),
        0,
        &outbound_buf,
        &recv_buf,
        &send_buf,
        &completed,
        &timed_out,
        &events,
        &state,
        .{
            .on_completed = callbacks.on_completed,
            .on_timed_out = callbacks.on_timed_out,
            .on_event = callbacks.on_event,
        },
        .{ .io_tick = .{ .max_starts_per_tick = 1, .outbound_options = .{ .username = "l:r", .priority = 7, .role = .{ .role = .controlling, .tie_breaker = 9 } } } },
    );

    var request_buf: [256]u8 = undefined;
    const request_recv = try peer.recv_from(&request_buf);
    const request_view = try parser.parse_message(request_buf[0..request_recv.bytes]);

    var response_buf: [256]u8 = undefined;
    const response = try usage_ice.build_connectivity_check_success_response(&response_buf, request_view.header.transaction_id, .{});
    _ = try peer.send_to(request_recv.from, response);

    _ = try bridge.pump_once_with_handlers(
        prng.random(),
        100,
        &outbound_buf,
        &recv_buf,
        &send_buf,
        &completed,
        &timed_out,
        &events,
        &state,
        .{
            .on_completed = callbacks.on_completed,
            .on_timed_out = callbacks.on_timed_out,
            .on_event = callbacks.on_event,
        },
        .{ .io_tick = .{ .max_starts_per_tick = 0 } },
    );

    try std.testing.expect(state.completed >= 1);
    try std.testing.expect(state.events >= 1);
}
