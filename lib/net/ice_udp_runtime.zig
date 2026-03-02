const std = @import("std");
const candidate = @import("../core/candidate.zig");
const conncheck = @import("../core/conncheck.zig");
const ice_runtime = @import("../core/ice_runtime.zig");
const udp_dispatch = @import("udp_dispatch.zig");
const turn_socket_udp = @import("turn_socket_udp.zig");
const turn_socket_tcp_client = @import("turn_socket_tcp_client.zig");
const usage_ice = @import("../protocol/stun/usage_ice.zig");
const usage_turn = @import("../protocol/stun/usage_turn.zig");
const integrity = @import("../protocol/stun/integrity.zig");
const address_attrs = @import("../protocol/stun/address_attrs.zig");
const parser = @import("../protocol/stun/parser.zig");

const TURN_BACKOFF_BASE_MS: u64 = 1_000;
const TURN_BACKOFF_MAX_MS: u64 = 60_000;

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
    turn_control_handled: usize,
    turn_auth_challenges: usize,
    turn_non_retryable_errors: usize,
    timed_out_checks: usize,
    failed_consents: usize,
};

pub const TurnMaintenanceOptions = struct {
    allocate_if_missing: bool = false,
    allocate_options: usage_turn.AllocateRequestOptions = .{},
    allocation_refresh_margin_ms: u64 = 60_000,
    permission_refresh_margin_ms: u64 = 60_000,
    channel_refresh_margin_ms: u64 = 60_000,
    refresh_lifetime_seconds: ?u32 = null,
    username: ?[]const u8 = null,
    realm: ?[]const u8 = null,
    nonce: ?[]const u8 = null,
    prefer_server_auth_challenge: bool = true,
    integrity_key: ?[]const u8 = null,
    include_fingerprint: bool = false,
};

pub const TurnMaintenanceSummary = struct {
    allocations_requested: usize,
    allocation_refreshes_sent: usize,
    permission_refreshes_sent: usize,
    channel_refreshes_sent: usize,
    backoff_skipped_bindings: usize,
    max_backoff_until_ms: u64,
    max_error_streak: u8,
    last_error_code_seen: ?u16,
    permissions_pruned: usize,
    channels_pruned: usize,

    pub fn total_sent(self: TurnMaintenanceSummary) usize {
        return self.allocations_requested + self.allocation_refreshes_sent + self.permission_refreshes_sent + self.channel_refreshes_sent;
    }
};

pub const TurnBindingDiagnostic = struct {
    stream_id: u32,
    component_id: u16,
    auth_retry_required: bool,
    last_error_code: ?u16,
    non_retryable_error_streak: u8,
    maintenance_backoff_until_ms: u64,
};

pub const TurnMaintenanceStatus = struct {
    stream_id: u32,
    component_id: u16,
    has_allocation: bool,
    allocation_expires_at_ms: u64,
    permission_count: usize,
    channel_count: usize,
    auth_retry_required: bool,
    last_error_code: ?u16,
    non_retryable_error_streak: u8,
    maintenance_backoff_until_ms: u64,
};

pub const IoTickOptions = struct {
    max_starts_per_tick: usize = 8,
    outbound_options: OutboundCheckOptions = .{},
    bidirectional_options: BidirectionalAdvanceOptions = .{},
    turn_maintenance: ?TurnMaintenanceOptions = null,
};

pub const IoTickSummary = struct {
    started_checks: usize,
    retransmits_sent: usize,
    turn_maintenance_sent: usize,
    turn_backoff_skipped_bindings: usize,
    turn_last_error_code_seen: ?u16,
    turn_max_error_streak: u8,
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
    turn_maintenance_sent: usize,
    turn_backoff_skipped_bindings: usize,
    turn_last_error_code_seen: ?u16,
    turn_max_error_streak: u8,
    packets_seen: usize,
    completed_checks: usize,
    requests_handled: usize,
    ignored_packets: usize,
    turn_control_handled: usize,
    turn_auth_challenges: usize,
    turn_non_retryable_errors: usize,
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
    total_turn_backoff_skipped_bindings: usize,
    total_packets_seen: usize,
    total_completed_checks: usize,
    total_requests_handled: usize,
    total_ignored_packets: usize,
    total_turn_control_handled: usize,
    total_turn_auth_challenges: usize,
    total_turn_non_retryable_errors: usize,
    max_turn_error_streak: u8,
    last_turn_error_code_seen: ?u16,
    total_timed_out_checks: usize,
    total_failed_consents: usize,
    total_events_drained: usize,
    final_pending_transactions: usize,
    final_waiting_pairs: usize,
    final_in_progress_pairs: usize,
};

pub const IceUdpRuntimeBridge = struct {
    const TurnBinding = struct {
        stream_id: u32,
        component_id: u16,
        socket: turn_socket_udp.TurnUdpSocket,
        non_retryable_error_streak: u8 = 0,
        maintenance_backoff_until_ms: u64 = 0,
    };

    const TurnTcpBinding = struct {
        stream_id: u32,
        component_id: u16,
        client: turn_socket_tcp_client.TurnTcpClient,
    };

    allocator: std.mem.Allocator,
    runtime: *ice_runtime.IceRuntime,
    dispatch: udp_dispatch.UdpDispatch,
    turn_bindings: std.ArrayList(TurnBinding),
    turn_tcp_bindings: std.ArrayList(TurnTcpBinding),

    pub fn init(allocator: std.mem.Allocator, runtime: *ice_runtime.IceRuntime) IceUdpRuntimeBridge {
        return .{
            .allocator = allocator,
            .runtime = runtime,
            .dispatch = udp_dispatch.UdpDispatch.init(allocator),
            .turn_bindings = .empty,
            .turn_tcp_bindings = .empty,
        };
    }

    pub fn deinit(self: *IceUdpRuntimeBridge) void {
        for (self.turn_tcp_bindings.items) |*binding| {
            binding.client.deinit();
        }
        self.turn_tcp_bindings.deinit(self.allocator);
        for (self.turn_bindings.items) |*binding| {
            binding.socket.deinit();
        }
        self.turn_bindings.deinit(self.allocator);
        self.dispatch.deinit();
    }

    pub fn add_binding(self: *IceUdpRuntimeBridge, stream_id: u32, component_id: u16, local: candidate.Address) !candidate.Address {
        return self.dispatch.add_binding(stream_id, component_id, local);
    }

    pub fn add_turn_binding(
        self: *IceUdpRuntimeBridge,
        stream_id: u32,
        component_id: u16,
        local_bind: candidate.Address,
        turn_server: candidate.Address,
    ) !candidate.Address {
        var socket = try turn_socket_udp.TurnUdpSocket.init_nonblocking(self.allocator, local_bind, turn_server);
        const bound = try socket.local_address();
        try self.turn_bindings.append(self.allocator, .{
            .stream_id = stream_id,
            .component_id = component_id,
            .socket = socket,
        });
        return bound;
    }

    pub fn add_turn_tcp_binding(
        self: *IceUdpRuntimeBridge,
        stream_id: u32,
        component_id: u16,
        turn_server: candidate.Address,
    ) !candidate.Address {
        var client = try turn_socket_tcp_client.TurnTcpClient.connect_nonblocking(self.allocator, turn_server);
        const local = client.local_address();
        try self.turn_tcp_bindings.append(self.allocator, .{
            .stream_id = stream_id,
            .component_id = component_id,
            .client = client,
        });
        return local;
    }

    pub fn send(self: *IceUdpRuntimeBridge, stream_id: u32, component_id: u16, remote: candidate.Address, payload: []const u8) !usize {
        return self.dispatch.send(stream_id, component_id, remote, payload);
    }

    pub fn send_via_pair(
        self: *IceUdpRuntimeBridge,
        stream_id: u32,
        component_id: u16,
        local_candidate_id: u64,
        remote: candidate.Address,
        payload: []const u8,
        now_ms: u64,
        relay_packet_buf: []u8,
        relay_transaction_id: [12]u8,
    ) !usize {
        const local_candidate = try self.runtime.agent.find_local_candidate_by_id(stream_id, local_candidate_id);
        if (local_candidate.candidate_type == .relay) {
            if (self.find_turn_binding(stream_id, component_id)) |binding| {
                return binding.socket.send_to_peer(relay_packet_buf, relay_transaction_id, remote, payload, now_ms);
            }
            if (self.find_turn_tcp_binding(stream_id, component_id)) |binding| {
                const frame_buf = try self.allocator.alloc(u8, relay_packet_buf.len + 2);
                defer self.allocator.free(frame_buf);
                return binding.client.send_to_peer(frame_buf, relay_packet_buf, relay_transaction_id, remote, payload);
            }
            return error.NotFound;
        }

        return self.dispatch.send(stream_id, component_id, remote, payload);
    }

    fn find_turn_binding(self: *IceUdpRuntimeBridge, stream_id: u32, component_id: u16) ?*TurnBinding {
        for (self.turn_bindings.items) |*binding| {
            if (binding.stream_id == stream_id and binding.component_id == component_id) return binding;
        }
        return null;
    }

    fn find_turn_tcp_binding(self: *IceUdpRuntimeBridge, stream_id: u32, component_id: u16) ?*TurnTcpBinding {
        for (self.turn_tcp_bindings.items) |*binding| {
            if (binding.stream_id == stream_id and binding.component_id == component_id) return binding;
        }
        return null;
    }

    fn send_check_packet(
        self: *IceUdpRuntimeBridge,
        stream_id: u32,
        component_id: u16,
        local_candidate_id: u64,
        remote: candidate.Address,
        transaction_id: [12]u8,
        packet: []const u8,
        now_ms: u64,
    ) !usize {
        const local_candidate = try self.runtime.agent.find_local_candidate_by_id(stream_id, local_candidate_id);
        if (local_candidate.candidate_type == .relay) {
            if (self.find_turn_binding(stream_id, component_id)) |binding| {
                return binding.socket.send_to_peer(@constCast(packet), transaction_id, remote, packet, now_ms);
            }
            if (self.find_turn_tcp_binding(stream_id, component_id)) |binding| {
                const packet_buf = try self.allocator.alloc(u8, packet.len + 256);
                defer self.allocator.free(packet_buf);
                const frame_buf = try self.allocator.alloc(u8, packet_buf.len + 2);
                defer self.allocator.free(frame_buf);
                return binding.client.send_to_peer(frame_buf, packet_buf, transaction_id, remote, packet);
            }
            return error.NotFound;
        }

        return self.dispatch.send(stream_id, component_id, remote, packet);
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
        _ = try self.send_check_packet(
            started.stream_id,
            started.component_id,
            started.local_candidate_id,
            remote_candidate.address,
            started.transaction_id,
            packet,
            now_ms,
        );

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

        const turn_result = try self.drain_turn_packets(
            0,
            recv_buf,
            send_buf,
            &[_]conncheck.CompletedCheck{},
            .{ .request_integrity_key = request_integrity_key, .response_options = response_options },
            true,
        );
        summary.packets_seen += turn_result.packets_seen;
        summary.requests_handled += turn_result.requests_handled;
        summary.ignored_packets += turn_result.ignored_packets;

        const turn_tcp = try self.drain_turn_tcp_packets(0, recv_buf, send_buf, &[_]conncheck.CompletedCheck{}, .{ .request_integrity_key = request_integrity_key, .response_options = response_options }, true);
        summary.packets_seen += turn_tcp.packets_seen;
        summary.requests_handled += turn_tcp.requests_handled;
        summary.ignored_packets += turn_tcp.ignored_packets;

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

        const turn_out = if (summary.completed_checks < out_completed.len)
            out_completed[summary.completed_checks..]
        else
            out_completed[out_completed.len..];
        const turn_result = try self.drain_turn_packets(now_ms, recv_buf, recv_buf, turn_out, .{}, false);
        summary.packets_seen += turn_result.packets_seen;
        summary.ignored_packets += turn_result.ignored_packets;
        summary.completed_checks += turn_result.completed_checks;

        const turn_tcp = try self.drain_turn_tcp_packets(now_ms, recv_buf, recv_buf, turn_out, .{}, false);
        summary.packets_seen += turn_tcp.packets_seen;
        summary.ignored_packets += turn_tcp.ignored_packets;
        summary.completed_checks += turn_tcp.completed_checks;

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
            .turn_control_handled = 0,
            .turn_auth_challenges = 0,
            .turn_non_retryable_errors = 0,
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

        const turn_out = if (summary.completed_checks < out_completed.len)
            out_completed[summary.completed_checks..]
        else
            out_completed[out_completed.len..];
        const turn_result = try self.drain_turn_packets(now_ms, recv_buf, send_buf, turn_out, options, true);
        summary.packets_seen += turn_result.packets_seen;
        summary.completed_checks += turn_result.completed_checks;
        summary.requests_handled += turn_result.requests_handled;
        summary.ignored_packets += turn_result.ignored_packets;
        summary.turn_control_handled += turn_result.control_handled;
        summary.turn_auth_challenges += turn_result.auth_challenges;
        summary.turn_non_retryable_errors += turn_result.non_retryable_errors;

        const turn_tcp = try self.drain_turn_tcp_packets(now_ms, recv_buf, send_buf, turn_out, options, true);
        summary.packets_seen += turn_tcp.packets_seen;
        summary.completed_checks += turn_tcp.completed_checks;
        summary.requests_handled += turn_tcp.requests_handled;
        summary.ignored_packets += turn_tcp.ignored_packets;

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

        var turn_maintenance_sent: usize = 0;
        var turn_backoff_skipped_bindings: usize = 0;
        var turn_last_error_code_seen: ?u16 = null;
        var turn_max_error_streak: u8 = 0;
        if (options.turn_maintenance) |maintenance| {
            const turn_summary = try self.run_turn_maintenance(random, now_ms, outbound_packet_buf, maintenance);
            turn_maintenance_sent = turn_summary.total_sent();
            turn_backoff_skipped_bindings = turn_summary.backoff_skipped_bindings;
            turn_last_error_code_seen = turn_summary.last_error_code_seen;
            turn_max_error_streak = turn_summary.max_error_streak;
        }

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
            .turn_maintenance_sent = turn_maintenance_sent,
            .turn_backoff_skipped_bindings = turn_backoff_skipped_bindings,
            .turn_last_error_code_seen = turn_last_error_code_seen,
            .turn_max_error_streak = turn_max_error_streak,
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
        var total_turn_backoff_skipped_bindings: usize = 0;
        var total_packets_seen: usize = 0;
        var total_completed_checks: usize = 0;
        var total_requests_handled: usize = 0;
        var total_ignored_packets: usize = 0;
        var total_turn_control_handled: usize = 0;
        var total_turn_auth_challenges: usize = 0;
        var total_turn_non_retryable_errors: usize = 0;
        var max_turn_error_streak: u8 = 0;
        var last_turn_error_code_seen: ?u16 = null;
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
            total_turn_backoff_skipped_bindings += tick.turn_backoff_skipped_bindings;
            total_packets_seen += tick.advance.packets_seen;
            total_completed_checks += tick.advance.completed_checks;
            total_requests_handled += tick.advance.requests_handled;
            total_ignored_packets += tick.advance.ignored_packets;
            total_turn_control_handled += tick.advance.turn_control_handled;
            total_turn_auth_challenges += tick.advance.turn_auth_challenges;
            total_turn_non_retryable_errors += tick.advance.turn_non_retryable_errors;
            max_turn_error_streak = @max(max_turn_error_streak, tick.turn_max_error_streak);
            if (tick.turn_last_error_code_seen) |code| last_turn_error_code_seen = code;
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
                    .total_turn_backoff_skipped_bindings = total_turn_backoff_skipped_bindings,
                    .total_packets_seen = total_packets_seen,
                    .total_completed_checks = total_completed_checks,
                    .total_requests_handled = total_requests_handled,
                    .total_ignored_packets = total_ignored_packets,
                    .total_turn_control_handled = total_turn_control_handled,
                    .total_turn_auth_challenges = total_turn_auth_challenges,
                    .total_turn_non_retryable_errors = total_turn_non_retryable_errors,
                    .max_turn_error_streak = max_turn_error_streak,
                    .last_turn_error_code_seen = last_turn_error_code_seen,
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
            .total_turn_backoff_skipped_bindings = total_turn_backoff_skipped_bindings,
            .total_packets_seen = total_packets_seen,
            .total_completed_checks = total_completed_checks,
            .total_requests_handled = total_requests_handled,
            .total_ignored_packets = total_ignored_packets,
            .total_turn_control_handled = total_turn_control_handled,
            .total_turn_auth_challenges = total_turn_auth_challenges,
            .total_turn_non_retryable_errors = total_turn_non_retryable_errors,
            .max_turn_error_streak = max_turn_error_streak,
            .last_turn_error_code_seen = last_turn_error_code_seen,
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
            .turn_maintenance_sent = tick.io.turn_maintenance_sent,
            .turn_backoff_skipped_bindings = tick.io.turn_backoff_skipped_bindings,
            .turn_last_error_code_seen = tick.io.turn_last_error_code_seen,
            .turn_max_error_streak = tick.io.turn_max_error_streak,
            .packets_seen = tick.io.advance.packets_seen,
            .completed_checks = tick.io.advance.completed_checks,
            .requests_handled = tick.io.advance.requests_handled,
            .ignored_packets = tick.io.advance.ignored_packets,
            .turn_control_handled = tick.io.advance.turn_control_handled,
            .turn_auth_challenges = tick.io.advance.turn_auth_challenges,
            .turn_non_retryable_errors = tick.io.advance.turn_non_retryable_errors,
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
            _ = try self.send_check_packet(
                item.stream_id,
                item.component_id,
                item.local_candidate_id,
                remote_candidate.address,
                item.transaction_id,
                packet,
                now_ms,
            );
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

    pub fn run_turn_maintenance(
        self: *IceUdpRuntimeBridge,
        random: std.Random,
        now_ms: u64,
        packet_buf: []u8,
        options: TurnMaintenanceOptions,
    ) !TurnMaintenanceSummary {
        var summary = TurnMaintenanceSummary{
            .allocations_requested = 0,
            .allocation_refreshes_sent = 0,
            .permission_refreshes_sent = 0,
            .channel_refreshes_sent = 0,
            .backoff_skipped_bindings = 0,
            .max_backoff_until_ms = 0,
            .max_error_streak = 0,
            .last_error_code_seen = null,
            .permissions_pruned = 0,
            .channels_pruned = 0,
        };

        for (self.turn_bindings.items) |*binding| {
            summary.max_backoff_until_ms = @max(summary.max_backoff_until_ms, binding.maintenance_backoff_until_ms);
            summary.max_error_streak = @max(summary.max_error_streak, binding.non_retryable_error_streak);
            if (binding.socket.latest_error_code()) |code| summary.last_error_code_seen = code;

            if (now_ms < binding.maintenance_backoff_until_ms) {
                summary.backoff_skipped_bindings += 1;
                continue;
            }

            const auth_retry = binding.socket.has_auth_retry_required();
            const realm = if (options.prefer_server_auth_challenge)
                (binding.socket.auth_realm_value() orelse options.realm)
            else
                options.realm;
            const nonce = if (options.prefer_server_auth_challenge)
                (binding.socket.auth_nonce_value() orelse options.nonce)
            else
                options.nonce;
            var sent_for_binding: usize = 0;

            if (binding.socket.allocation == null and options.allocate_if_missing) {
                const tx_id = stun_tx_from_rng(random);
                var allocate_options = options.allocate_options;
                if (options.username != null) allocate_options.username = options.username;
                if (realm != null) allocate_options.realm = realm;
                if (nonce != null) allocate_options.nonce = nonce;
                _ = try binding.socket.send_allocate_request(packet_buf, tx_id, allocate_options);
                summary.allocations_requested += 1;
                sent_for_binding += 1;
            }

            if (binding.socket.allocation) |lease| {
                if (auth_retry or now_ms >= lease.refresh_due_at_ms(options.allocation_refresh_margin_ms)) {
                    const tx_id = stun_tx_from_rng(random);
                    _ = try binding.socket.send_refresh_request(packet_buf, tx_id, .{
                        .lifetime_seconds = options.refresh_lifetime_seconds,
                        .nonce = nonce,
                        .realm = realm,
                        .username = options.username,
                        .integrity_key = options.integrity_key,
                        .include_fingerprint = options.include_fingerprint,
                    });
                    summary.allocation_refreshes_sent += 1;
                    sent_for_binding += 1;
                }
            }

            var due_permissions: [16]candidate.Address = undefined;
            const permission_margin = if (auth_retry) std.math.maxInt(u64) else options.permission_refresh_margin_ms;
            const due_permission_count = binding.socket.collect_due_permission_refreshes(now_ms, permission_margin, &due_permissions);
            for (due_permissions[0..@min(due_permissions.len, due_permission_count)]) |peer| {
                const tx_id = stun_tx_from_rng(random);
                const peers = [_]address_attrs.StunAddress{candidate_to_stun_address(peer)};
                _ = try binding.socket.send_create_permission_request(packet_buf, tx_id, .{
                    .peer_addresses = &peers,
                    .username = options.username,
                    .realm = realm,
                    .nonce = nonce,
                    .integrity_key = options.integrity_key,
                    .include_fingerprint = options.include_fingerprint,
                });
                try binding.socket.note_permission_refresh_request(tx_id, peer, turn_socket_udp.TurnUdpSocket.permission_default_lifetime_seconds);
                summary.permission_refreshes_sent += 1;
                sent_for_binding += 1;
            }

            var due_channels: [16]turn_socket_udp.ChannelBinding = undefined;
            const channel_margin = if (auth_retry) std.math.maxInt(u64) else options.channel_refresh_margin_ms;
            const due_channel_count = binding.socket.collect_due_channel_refreshes(now_ms, channel_margin, &due_channels);
            for (due_channels[0..@min(due_channels.len, due_channel_count)]) |entry| {
                const tx_id = stun_tx_from_rng(random);
                _ = try binding.socket.send_channel_bind_request(packet_buf, tx_id, .{
                    .channel_number = entry.channel_number,
                    .peer_address = candidate_to_stun_address(entry.peer),
                    .username = options.username,
                    .realm = realm,
                    .nonce = nonce,
                    .integrity_key = options.integrity_key,
                    .include_fingerprint = options.include_fingerprint,
                });
                try binding.socket.note_channel_refresh_request(tx_id, entry.channel_number, entry.peer, turn_socket_udp.TurnUdpSocket.channel_default_lifetime_seconds);
                summary.channel_refreshes_sent += 1;
                sent_for_binding += 1;
            }

            if (auth_retry and sent_for_binding > 0) {
                binding.socket.clear_auth_retry_required();
            }

            summary.permissions_pruned += binding.socket.prune_expired_permissions(now_ms);
            summary.channels_pruned += binding.socket.prune_expired_channel_bindings(now_ms);
        }

        return summary;
    }

    pub fn collect_turn_binding_diagnostics(self: *IceUdpRuntimeBridge, out: []TurnBindingDiagnostic) usize {
        var count: usize = 0;
        for (self.turn_bindings.items) |binding| {
            if (count < out.len) {
                out[count] = .{
                    .stream_id = binding.stream_id,
                    .component_id = binding.component_id,
                    .auth_retry_required = binding.socket.has_auth_retry_required(),
                    .last_error_code = binding.socket.latest_error_code(),
                    .non_retryable_error_streak = binding.non_retryable_error_streak,
                    .maintenance_backoff_until_ms = binding.maintenance_backoff_until_ms,
                };
            }
            count += 1;
        }
        return count;
    }

    pub fn collect_turn_maintenance_status(self: *IceUdpRuntimeBridge, out: []TurnMaintenanceStatus) usize {
        var count: usize = 0;
        for (self.turn_bindings.items) |binding| {
            if (count < out.len) {
                out[count] = .{
                    .stream_id = binding.stream_id,
                    .component_id = binding.component_id,
                    .has_allocation = binding.socket.allocation != null,
                    .allocation_expires_at_ms = if (binding.socket.allocation) |lease| lease.expires_at_ms else 0,
                    .permission_count = binding.socket.permission_count(),
                    .channel_count = binding.socket.channel_binding_count(),
                    .auth_retry_required = binding.socket.has_auth_retry_required(),
                    .last_error_code = binding.socket.latest_error_code(),
                    .non_retryable_error_streak = binding.non_retryable_error_streak,
                    .maintenance_backoff_until_ms = binding.maintenance_backoff_until_ms,
                };
            }
            count += 1;
        }
        return count;
    }

    const TurnDrainSummary = struct {
        packets_seen: usize,
        completed_checks: usize,
        requests_handled: usize,
        ignored_packets: usize,
        control_handled: usize,
        auth_challenges: usize,
        non_retryable_errors: usize,
    };

    fn drain_turn_packets(
        self: *IceUdpRuntimeBridge,
        now_ms: u64,
        recv_buf: []u8,
        send_buf: []u8,
        out_completed: []conncheck.CompletedCheck,
        options: BidirectionalAdvanceOptions,
        handle_requests: bool,
    ) !TurnDrainSummary {
        var summary = TurnDrainSummary{
            .packets_seen = 0,
            .completed_checks = 0,
            .requests_handled = 0,
            .ignored_packets = 0,
            .control_handled = 0,
            .auth_challenges = 0,
            .non_retryable_errors = 0,
        };

        for (self.turn_bindings.items) |*binding| {
            while (true) {
                const maybe_packet = try binding.socket.recv_from_server(recv_buf);
                const packet = maybe_packet orelse break;
                summary.packets_seen += 1;

                switch (packet) {
                    .relayed_data => |relayed| {
                        const view = parser.parse_message(relayed.payload) catch {
                            summary.ignored_packets += 1;
                            continue;
                        };

                        if (handle_requests and usage_ice.is_connectivity_check_request(view)) {
                            _ = usage_ice.parse_connectivity_check_request(view, options.request_integrity_key) catch {
                                summary.ignored_packets += 1;
                                continue;
                            };

                            const response = try usage_ice.build_connectivity_check_success_response(send_buf, view.header.transaction_id, options.response_options);
                            _ = try binding.socket.send_to_peer(send_buf, view.header.transaction_id, relayed.peer, response, now_ms);
                            summary.requests_handled += 1;
                            continue;
                        }

                        const completed = self.runtime.on_response(binding.stream_id, binding.component_id, view, now_ms) catch |err| switch (err) {
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
                    },
                    .stun => |view| {
                        const outcome = try binding.socket.on_server_stun(view, now_ms, null);
                        switch (outcome) {
                            .ignored => summary.ignored_packets += 1,
                            .handled => {
                                binding.non_retryable_error_streak = 0;
                                binding.maintenance_backoff_until_ms = 0;
                                summary.control_handled += 1;
                            },
                            .auth_challenge_required => {
                                binding.non_retryable_error_streak = 0;
                                binding.maintenance_backoff_until_ms = 0;
                                summary.control_handled += 1;
                                summary.auth_challenges += 1;
                            },
                            .error_non_retryable => {
                                binding.non_retryable_error_streak = @min(@as(u8, 30), binding.non_retryable_error_streak + 1);
                                const backoff_ms = compute_turn_backoff_ms(binding.non_retryable_error_streak);
                                binding.maintenance_backoff_until_ms = now_ms +| backoff_ms;
                                summary.control_handled += 1;
                                summary.non_retryable_errors += 1;
                            },
                        }
                    },
                    else => {
                        summary.ignored_packets += 1;
                    },
                }
            }
        }

        return summary;
    }

    fn drain_turn_tcp_packets(
        self: *IceUdpRuntimeBridge,
        now_ms: u64,
        recv_buf: []u8,
        send_buf: []u8,
        out_completed: []conncheck.CompletedCheck,
        options: BidirectionalAdvanceOptions,
        handle_requests: bool,
    ) !TurnDrainSummary {
        var summary = TurnDrainSummary{
            .packets_seen = 0,
            .completed_checks = 0,
            .requests_handled = 0,
            .ignored_packets = 0,
            .control_handled = 0,
            .auth_challenges = 0,
            .non_retryable_errors = 0,
        };

        for (self.turn_tcp_bindings.items) |*binding| {
            _ = try binding.client.pump_read(recv_buf);

            while (true) {
                const packet = try binding.client.pop_packet(recv_buf) orelse break;
                summary.packets_seen += 1;

                switch (packet) {
                    .stun => |view| {
                        if (!usage_turn.is_data_indication(view)) {
                            summary.ignored_packets += 1;
                            continue;
                        }

                        const data_ind = usage_turn.parse_data_indication(view) catch {
                            summary.ignored_packets += 1;
                            continue;
                        };

                        const inner = parser.parse_message(data_ind.data) catch {
                            summary.ignored_packets += 1;
                            continue;
                        };

                        const remote = stun_to_candidate_address(data_ind.peer_address);
                        if (handle_requests and usage_ice.is_connectivity_check_request(inner)) {
                            _ = usage_ice.parse_connectivity_check_request(inner, options.request_integrity_key) catch {
                                summary.ignored_packets += 1;
                                continue;
                            };

                            const response = try usage_ice.build_connectivity_check_success_response(send_buf, inner.header.transaction_id, options.response_options);
                            const frame_buf = try self.allocator.alloc(u8, send_buf.len + 2);
                            defer self.allocator.free(frame_buf);
                            _ = try binding.client.send_to_peer(frame_buf, send_buf, inner.header.transaction_id, remote, response);
                            summary.requests_handled += 1;
                            continue;
                        }

                        const completed = self.runtime.on_response(binding.stream_id, binding.component_id, inner, now_ms) catch |err| switch (err) {
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
                    },
                    .channel_data => {
                        summary.ignored_packets += 1;
                    },
                }
            }
        }

        return summary;
    }
};

fn compute_turn_backoff_ms(streak: u8) u64 {
    if (streak == 0) return 0;
    const shift: u6 = @intCast(@min(@as(u8, 15), streak - 1));
    const scaled = TURN_BACKOFF_BASE_MS << shift;
    return @min(TURN_BACKOFF_MAX_MS, scaled);
}

fn candidate_to_stun_address(address: candidate.Address) address_attrs.StunAddress {
    return switch (address) {
        .ipv4 => |v4| .{ .ipv4 = .{ .port = v4.port, .ip = v4.ip } },
        .ipv6 => |v6| .{ .ipv6 = .{ .port = v6.port, .ip = v6.ip } },
    };
}

fn stun_to_candidate_address(address: address_attrs.StunAddress) candidate.Address {
    return switch (address) {
        .ipv4 => |v4| .{ .ipv4 = .{ .port = v4.port, .ip = v4.ip } },
        .ipv6 => |v6| .{ .ipv6 = .{ .port = v6.port, .ip = v6.ip } },
    };
}

fn stun_tx_from_rng(random: std.Random) [12]u8 {
    var tx_id: [12]u8 = undefined;
    random.bytes(&tx_id);
    return tx_id;
}

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

test "udp bridge routes relay local candidate checks through TURN send indication" {
    var turn_server = try @import("udp_socket.zig").UdpSocket.bind(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer turn_server.deinit();
    const turn_server_addr = try turn_server.local_address();

    var agent = @import("../core/agent.zig").Agent.init(std.testing.allocator);
    defer agent.deinit();

    const stream_id = try agent.add_stream(1);
    const relay_local: candidate.Address = .{ .ipv4 = .{ .ip = .{ 10, 0, 0, 2 }, .port = 60000 } };
    const remote_addr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 198, 51, 100, 44 }, .port = 5000 } };

    try std.testing.expect(try agent.add_local_candidate(stream_id, .{
        .id = 301,
        .component_id = 1,
        .candidate_type = .relay,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .relay, relay_local),
        .priority = candidate.compute_candidate_priority(.relay, 50, 1),
        .address = relay_local,
    }));
    try std.testing.expect(try agent.add_remote_candidate(stream_id, .{
        .id = 302,
        .component_id = 1,
        .candidate_type = .srflx,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .srflx, remote_addr),
        .priority = candidate.compute_candidate_priority(.srflx, 100, 1),
        .address = remote_addr,
    }));

    var runtime = ice_runtime.IceRuntime.init(std.testing.allocator, &agent, .{}, .{}, .regular);
    defer runtime.deinit();
    try std.testing.expect(try runtime.attach_stream(stream_id));
    _ = try runtime.populate_stream_checklists(stream_id, true, 12_000);
    try runtime.start_connecting_all();

    var bridge = IceUdpRuntimeBridge.init(std.testing.allocator, &runtime);
    defer bridge.deinit();
    _ = try bridge.add_turn_binding(stream_id, 1, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } }, turn_server_addr);

    var prng = std.Random.DefaultPrng.init(45);
    var out_packet: [512]u8 = undefined;
    _ = (try bridge.start_and_send_next_check(prng.random(), 0, &out_packet, .{
        .username = "l:r",
        .priority = 777,
        .role = .{ .role = .controlling, .tie_breaker = 42 },
    })).?;

    var recv_buf: [512]u8 = undefined;
    const got = try turn_server.recv_from(&recv_buf);
    const outer = try parser.parse_message(recv_buf[0..got.bytes]);
    try std.testing.expectEqual(@as(u16, usage_turn.send_indication_type), outer.header.message_type);
    const inner_payload = (try usage_turn.read_data_attr(outer)).?;
    const inner = try parser.parse_message(inner_payload);
    try std.testing.expect(usage_ice.is_connectivity_check_request(inner));
}

test "udp bridge completes relay connectivity check from TURN data indication" {
    const encoder = @import("../protocol/stun/encoder.zig");

    var turn_server = try @import("udp_socket.zig").UdpSocket.bind(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer turn_server.deinit();
    const turn_server_addr = try turn_server.local_address();

    var agent = @import("../core/agent.zig").Agent.init(std.testing.allocator);
    defer agent.deinit();

    const stream_id = try agent.add_stream(1);
    const relay_local: candidate.Address = .{ .ipv4 = .{ .ip = .{ 10, 0, 0, 3 }, .port = 60001 } };
    const remote_addr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 198, 51, 100, 45 }, .port = 5001 } };

    try std.testing.expect(try agent.add_local_candidate(stream_id, .{
        .id = 401,
        .component_id = 1,
        .candidate_type = .relay,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .relay, relay_local),
        .priority = candidate.compute_candidate_priority(.relay, 50, 1),
        .address = relay_local,
    }));
    try std.testing.expect(try agent.add_remote_candidate(stream_id, .{
        .id = 402,
        .component_id = 1,
        .candidate_type = .srflx,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .srflx, remote_addr),
        .priority = candidate.compute_candidate_priority(.srflx, 100, 1),
        .address = remote_addr,
    }));

    var runtime = ice_runtime.IceRuntime.init(std.testing.allocator, &agent, .{}, .{}, .regular);
    defer runtime.deinit();
    try std.testing.expect(try runtime.attach_stream(stream_id));
    _ = try runtime.populate_stream_checklists(stream_id, true, 13_000);
    try runtime.start_connecting_all();

    var bridge = IceUdpRuntimeBridge.init(std.testing.allocator, &runtime);
    defer bridge.deinit();
    _ = try bridge.add_turn_binding(stream_id, 1, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } }, turn_server_addr);

    var prng = std.Random.DefaultPrng.init(46);
    var out_packet: [512]u8 = undefined;
    _ = (try bridge.start_and_send_next_check(prng.random(), 0, &out_packet, .{
        .username = "l:r",
        .priority = 555,
        .role = .{ .role = .controlling, .tie_breaker = 99 },
    })).?;

    var recv_buf_server: [512]u8 = undefined;
    const received = try turn_server.recv_from(&recv_buf_server);
    const send_ind = try parser.parse_message(recv_buf_server[0..received.bytes]);
    const inner_req = try parser.parse_message((try usage_turn.read_data_attr(send_ind)).?);

    var success_buf: [256]u8 = undefined;
    const success = try usage_ice.build_connectivity_check_success_response(&success_buf, inner_req.header.transaction_id, .{});

    var indication_buf: [512]u8 = undefined;
    const indication_tx = [_]u8{ 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21 };
    var builder = try encoder.Builder.init(&indication_buf, usage_turn.data_indication_type, indication_tx);
    try address_attrs.add_xor_peer_address(&builder, .{ .ipv4 = .{ .ip = remote_addr.ipv4.ip, .port = remote_addr.ipv4.port } }, indication_tx);
    try builder.add_attr(usage_turn.data_attr_type, success);
    const indication = try builder.finish();
    _ = try turn_server.send_to(received.from, indication);

    var recv_buf: [512]u8 = undefined;
    var send_buf: [512]u8 = undefined;
    var completed: [2]conncheck.CompletedCheck = undefined;
    var timed_out: [2]ice_runtime.TimedOutCheck = undefined;
    const summary = try bridge.advance_bidirectional(100, &recv_buf, &send_buf, &completed, &timed_out, .{});

    try std.testing.expectEqual(@as(usize, 1), summary.completed_checks);
    try std.testing.expectEqual(@as(u64, 13_000), completed[0].meta.candidate_pair_id);
}

test "udp bridge send_via_pair sends direct payload for non-relay local candidate" {
    var peer = try @import("udp_socket.zig").UdpSocket.bind(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer peer.deinit();
    const peer_addr = try peer.local_address();

    var agent = @import("../core/agent.zig").Agent.init(std.testing.allocator);
    defer agent.deinit();
    const stream_id = try agent.add_stream(1);
    const local_addr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 211 }, .port = 5100 } };

    try std.testing.expect(try agent.add_local_candidate(stream_id, .{
        .id = 501,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .host, local_addr),
        .priority = candidate.compute_candidate_priority(.host, 100, 1),
        .address = local_addr,
    }));

    var runtime = ice_runtime.IceRuntime.init(std.testing.allocator, &agent, .{}, .{}, .regular);
    defer runtime.deinit();
    try std.testing.expect(try runtime.attach_stream(stream_id));

    var bridge = IceUdpRuntimeBridge.init(std.testing.allocator, &runtime);
    defer bridge.deinit();
    _ = try bridge.add_binding(stream_id, 1, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });

    var relay_buf: [128]u8 = undefined;
    const tx = [_]u8{ 1, 3, 3, 7, 0, 1, 0, 1, 4, 2, 0, 0 };
    _ = try bridge.send_via_pair(stream_id, 1, 501, peer_addr, "payload-direct", 0, &relay_buf, tx);

    var recv: [128]u8 = undefined;
    const got = try peer.recv_from(&recv);
    try std.testing.expectEqualStrings("payload-direct", recv[0..got.bytes]);
}

test "udp bridge send_via_pair sends relayed payload for relay local candidate" {
    var turn_server = try @import("udp_socket.zig").UdpSocket.bind(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer turn_server.deinit();
    const turn_server_addr = try turn_server.local_address();

    var agent = @import("../core/agent.zig").Agent.init(std.testing.allocator);
    defer agent.deinit();
    const stream_id = try agent.add_stream(1);
    const relay_local: candidate.Address = .{ .ipv4 = .{ .ip = .{ 10, 0, 0, 4 }, .port = 62000 } };
    const remote_addr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 198, 51, 100, 46 }, .port = 5002 } };

    try std.testing.expect(try agent.add_local_candidate(stream_id, .{
        .id = 502,
        .component_id = 1,
        .candidate_type = .relay,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .relay, relay_local),
        .priority = candidate.compute_candidate_priority(.relay, 50, 1),
        .address = relay_local,
    }));

    var runtime = ice_runtime.IceRuntime.init(std.testing.allocator, &agent, .{}, .{}, .regular);
    defer runtime.deinit();
    try std.testing.expect(try runtime.attach_stream(stream_id));

    var bridge = IceUdpRuntimeBridge.init(std.testing.allocator, &runtime);
    defer bridge.deinit();
    _ = try bridge.add_turn_binding(stream_id, 1, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } }, turn_server_addr);

    var relay_buf: [256]u8 = undefined;
    const tx = [_]u8{ 9, 9, 0, 0, 4, 4, 1, 1, 2, 2, 3, 3 };
    _ = try bridge.send_via_pair(stream_id, 1, 502, remote_addr, "relay-data", 10, &relay_buf, tx);

    var recv: [256]u8 = undefined;
    const got = try turn_server.recv_from(&recv);
    const view = try parser.parse_message(recv[0..got.bytes]);
    try std.testing.expectEqual(@as(u16, usage_turn.send_indication_type), view.header.message_type);
    try std.testing.expectEqualStrings("relay-data", (try usage_turn.read_data_attr(view)).?);
}

test "udp bridge turn maintenance sends refresh requests and prunes expired entries" {
    var turn_server = try @import("udp_socket.zig").UdpSocket.bind_nonblocking(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer turn_server.deinit();
    const turn_server_addr = try turn_server.local_address();

    var agent = @import("../core/agent.zig").Agent.init(std.testing.allocator);
    defer agent.deinit();
    const stream_id = try agent.add_stream(1);

    var runtime = ice_runtime.IceRuntime.init(std.testing.allocator, &agent, .{}, .{}, .regular);
    defer runtime.deinit();
    try std.testing.expect(try runtime.attach_stream(stream_id));

    var bridge = IceUdpRuntimeBridge.init(std.testing.allocator, &runtime);
    defer bridge.deinit();
    _ = try bridge.add_turn_binding(stream_id, 1, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } }, turn_server_addr);

    const binding = bridge.find_turn_binding(stream_id, 1).?;
    binding.socket.allocation = .{
        .relayed_address = null,
        .mapped_address = null,
        .lifetime_seconds = 600,
        .expires_at_ms = 10_000,
    };

    const due_peer: candidate.Address = .{ .ipv4 = .{ .ip = .{ 203, 0, 113, 100 }, .port = 5000 } };
    const expired_peer: candidate.Address = .{ .ipv4 = .{ .ip = .{ 203, 0, 113, 101 }, .port = 5001 } };
    try binding.socket.set_permission(due_peer, 4_000, 6);
    try binding.socket.set_permission(expired_peer, 0, 1);

    try binding.socket.set_channel_binding(0x4011, due_peer, 4_000, 6);
    try binding.socket.set_channel_binding(0x4012, expired_peer, 0, 1);

    var prng = std.Random.DefaultPrng.init(47);
    var packet_buf: [512]u8 = undefined;
    const summary = try bridge.run_turn_maintenance(prng.random(), 9_500, &packet_buf, .{
        .allocation_refresh_margin_ms = 1_000,
        .permission_refresh_margin_ms = 1_000,
        .channel_refresh_margin_ms = 1_000,
        .username = "u",
        .realm = "r",
        .nonce = "n",
        .integrity_key = "turn-key",
        .include_fingerprint = true,
    });

    try std.testing.expectEqual(@as(usize, 0), summary.allocations_requested);
    try std.testing.expectEqual(@as(usize, 1), summary.allocation_refreshes_sent);
    try std.testing.expectEqual(@as(usize, 1), summary.permission_refreshes_sent);
    try std.testing.expectEqual(@as(usize, 1), summary.channel_refreshes_sent);
    try std.testing.expectEqual(@as(usize, 1), summary.permissions_pruned);
    try std.testing.expectEqual(@as(usize, 1), summary.channels_pruned);

    var refresh_count: usize = 0;
    var permission_count: usize = 0;
    var channel_bind_count: usize = 0;
    var recv: [512]u8 = undefined;
    while (true) {
        const got = turn_server.recv_from(&recv) catch |err| switch (err) {
            error.WouldBlock => break,
            else => return err,
        };
        const view = try parser.parse_message(recv[0..got.bytes]);
        switch (view.header.message_type) {
            usage_turn.refresh_request_type => {
                refresh_count += 1;
                try std.testing.expect(try integrity.verify_embedded_message_integrity(view, "turn-key"));
                try std.testing.expect(try integrity.verify_embedded_fingerprint(view));
            },
            usage_turn.create_permission_request_type => {
                permission_count += 1;
                try std.testing.expect(try integrity.verify_embedded_message_integrity(view, "turn-key"));
                try std.testing.expect(try integrity.verify_embedded_fingerprint(view));
            },
            0x0009 => {
                channel_bind_count += 1;
                try std.testing.expect(try integrity.verify_embedded_message_integrity(view, "turn-key"));
                try std.testing.expect(try integrity.verify_embedded_fingerprint(view));
            },
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 1), refresh_count);
    try std.testing.expectEqual(@as(usize, 1), permission_count);
    try std.testing.expectEqual(@as(usize, 1), channel_bind_count);
}

test "udp bridge turn maintenance can request allocate when missing" {
    var turn_server = try @import("udp_socket.zig").UdpSocket.bind_nonblocking(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer turn_server.deinit();
    const turn_server_addr = try turn_server.local_address();

    var agent = @import("../core/agent.zig").Agent.init(std.testing.allocator);
    defer agent.deinit();
    const stream_id = try agent.add_stream(1);

    var runtime = ice_runtime.IceRuntime.init(std.testing.allocator, &agent, .{}, .{}, .regular);
    defer runtime.deinit();
    try std.testing.expect(try runtime.attach_stream(stream_id));

    var bridge = IceUdpRuntimeBridge.init(std.testing.allocator, &runtime);
    defer bridge.deinit();
    _ = try bridge.add_turn_binding(stream_id, 1, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } }, turn_server_addr);

    var prng = std.Random.DefaultPrng.init(50);
    var packet_buf: [512]u8 = undefined;
    const summary = try bridge.run_turn_maintenance(prng.random(), 0, &packet_buf, .{
        .allocate_if_missing = true,
        .allocate_options = .{ .username = "u", .realm = "r", .nonce = "n" },
    });
    try std.testing.expectEqual(@as(usize, 1), summary.allocations_requested);

    var recv: [512]u8 = undefined;
    const got = turn_server.recv_from(&recv) catch |err| switch (err) {
        error.WouldBlock => return error.ExpectedAllocateRequest,
        else => return err,
    };
    const view = try parser.parse_message(recv[0..got.bytes]);
    try std.testing.expectEqual(@as(u16, usage_turn.allocate_request_type), view.header.message_type);
}

test "udp bridge io tick reports turn maintenance sends" {
    var turn_server = try @import("udp_socket.zig").UdpSocket.bind_nonblocking(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer turn_server.deinit();
    const turn_server_addr = try turn_server.local_address();

    var agent = @import("../core/agent.zig").Agent.init(std.testing.allocator);
    defer agent.deinit();
    const stream_id = try agent.add_stream(1);

    var runtime = ice_runtime.IceRuntime.init(std.testing.allocator, &agent, .{}, .{}, .regular);
    defer runtime.deinit();
    try std.testing.expect(try runtime.attach_stream(stream_id));

    var bridge = IceUdpRuntimeBridge.init(std.testing.allocator, &runtime);
    defer bridge.deinit();
    _ = try bridge.add_turn_binding(stream_id, 1, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } }, turn_server_addr);

    const binding = bridge.find_turn_binding(stream_id, 1).?;
    binding.socket.allocation = .{
        .relayed_address = null,
        .mapped_address = null,
        .lifetime_seconds = 600,
        .expires_at_ms = 10_000,
    };

    var prng = std.Random.DefaultPrng.init(48);
    var outbound_buf: [256]u8 = undefined;
    var recv_buf: [256]u8 = undefined;
    var send_buf: [256]u8 = undefined;
    var completed: [1]conncheck.CompletedCheck = undefined;
    var timed_out: [1]ice_runtime.TimedOutCheck = undefined;
    const tick = try bridge.run_io_tick(
        prng.random(),
        9_500,
        &outbound_buf,
        &recv_buf,
        &send_buf,
        &completed,
        &timed_out,
        .{ .turn_maintenance = .{ .allocation_refresh_margin_ms = 1_000 } },
    );

    try std.testing.expectEqual(@as(usize, 1), tick.turn_maintenance_sent);
    try std.testing.expectEqual(@as(usize, 0), tick.turn_backoff_skipped_bindings);
    try std.testing.expectEqual(@as(?u16, null), tick.turn_last_error_code_seen);
}

test "udp bridge applies TURN refresh success to allocation lease" {
    const encoder = @import("../protocol/stun/encoder.zig");

    var turn_server = try @import("udp_socket.zig").UdpSocket.bind(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer turn_server.deinit();
    const turn_server_addr = try turn_server.local_address();

    var agent = @import("../core/agent.zig").Agent.init(std.testing.allocator);
    defer agent.deinit();
    const stream_id = try agent.add_stream(1);

    var runtime = ice_runtime.IceRuntime.init(std.testing.allocator, &agent, .{}, .{}, .regular);
    defer runtime.deinit();
    try std.testing.expect(try runtime.attach_stream(stream_id));

    var bridge = IceUdpRuntimeBridge.init(std.testing.allocator, &runtime);
    defer bridge.deinit();
    _ = try bridge.add_turn_binding(stream_id, 1, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } }, turn_server_addr);

    const binding = bridge.find_turn_binding(stream_id, 1).?;
    binding.socket.allocation = .{
        .relayed_address = null,
        .mapped_address = null,
        .lifetime_seconds = 120,
        .expires_at_ms = 10_000,
    };

    var prng = std.Random.DefaultPrng.init(49);
    var packet_buf: [512]u8 = undefined;
    const maintenance = try bridge.run_turn_maintenance(prng.random(), 9_500, &packet_buf, .{
        .allocation_refresh_margin_ms = 1_000,
    });
    try std.testing.expectEqual(@as(usize, 1), maintenance.allocation_refreshes_sent);

    var recv_from_client: [512]u8 = undefined;
    const client_pkt = try turn_server.recv_from(&recv_from_client);
    const refresh_req = try parser.parse_message(recv_from_client[0..client_pkt.bytes]);
    try std.testing.expectEqual(@as(u16, usage_turn.refresh_request_type), refresh_req.header.message_type);

    var response_buf: [256]u8 = undefined;
    var builder = try encoder.Builder.init(&response_buf, usage_turn.refresh_success_response_type, refresh_req.header.transaction_id);
    var lifetime: [4]u8 = undefined;
    std.mem.writeInt(u32, &lifetime, 300, .big);
    try builder.add_attr(usage_turn.lifetime_attr_type, &lifetime);
    const response = try builder.finish();
    _ = try turn_server.send_to(client_pkt.from, response);

    var recv_buf: [512]u8 = undefined;
    var completed: [1]conncheck.CompletedCheck = undefined;
    _ = try bridge.poll_until_idle(9_600, &recv_buf, &completed);

    try std.testing.expect(binding.socket.allocation != null);
    try std.testing.expectEqual(@as(u32, 300), binding.socket.allocation.?.lifetime_seconds);
    try std.testing.expectEqual(@as(u64, 309_600), binding.socket.allocation.?.expires_at_ms);
}

test "udp bridge applies TURN permission and channel success responses" {
    const message = @import("../protocol/stun/message.zig");

    var turn_server = try @import("udp_socket.zig").UdpSocket.bind(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer turn_server.deinit();
    const turn_server_addr = try turn_server.local_address();

    var agent = @import("../core/agent.zig").Agent.init(std.testing.allocator);
    defer agent.deinit();
    const stream_id = try agent.add_stream(1);

    var runtime = ice_runtime.IceRuntime.init(std.testing.allocator, &agent, .{}, .{}, .regular);
    defer runtime.deinit();
    try std.testing.expect(try runtime.attach_stream(stream_id));

    var bridge = IceUdpRuntimeBridge.init(std.testing.allocator, &runtime);
    defer bridge.deinit();
    _ = try bridge.add_turn_binding(stream_id, 1, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } }, turn_server_addr);

    const binding = bridge.find_turn_binding(stream_id, 1).?;
    const turn_client_addr = try binding.socket.local_address();
    const peer: candidate.Address = .{ .ipv4 = .{ .ip = .{ 203, 0, 113, 77 }, .port = 5000 } };
    try binding.socket.set_permission(peer, 0, 10);
    try binding.socket.set_channel_binding(0x4019, peer, 0, 10);

    var prng = std.Random.DefaultPrng.init(51);
    var packet_buf: [512]u8 = undefined;
    const maintenance = try bridge.run_turn_maintenance(prng.random(), 9_500, &packet_buf, .{
        .permission_refresh_margin_ms = 1_000,
        .channel_refresh_margin_ms = 1_000,
    });
    try std.testing.expectEqual(@as(usize, 1), maintenance.permission_refreshes_sent);
    try std.testing.expectEqual(@as(usize, 1), maintenance.channel_refreshes_sent);

    var received_permission_tx: ?[12]u8 = null;
    var received_channel_tx: ?[12]u8 = null;
    var recv: [512]u8 = undefined;
    var recv_count: usize = 0;
    while (recv_count < 2) {
        const got = try turn_server.recv_from(&recv);
        const view = try parser.parse_message(recv[0..got.bytes]);
        if (view.header.message_type == usage_turn.create_permission_request_type) {
            received_permission_tx = view.header.transaction_id;
            recv_count += 1;
        } else if (view.header.message_type == usage_turn.channel_bind_request_type) {
            received_channel_tx = view.header.transaction_id;
            recv_count += 1;
        }
    }

    var perm_ok: [20]u8 = undefined;
    _ = try message.Header.init(usage_turn.create_permission_success_response_type, 0, received_permission_tx.?).encode(&perm_ok);
    _ = try turn_server.send_to(turn_client_addr, &perm_ok);

    var chan_ok: [20]u8 = undefined;
    _ = try message.Header.init(usage_turn.channel_bind_success_response_type, 0, received_channel_tx.?).encode(&chan_ok);
    _ = try turn_server.send_to(turn_client_addr, &chan_ok);

    var recv_buf: [256]u8 = undefined;
    var completed: [1]conncheck.CompletedCheck = undefined;
    _ = try bridge.poll_until_idle(10_000, &recv_buf, &completed);

    try std.testing.expectEqual(@as(usize, 1), binding.socket.permission_count());
    try std.testing.expect(binding.socket.permissions.items[0].expires_at_ms > 10_000);
    try std.testing.expectEqual(@as(usize, 1), binding.socket.channel_binding_count());
    try std.testing.expect(binding.socket.channels.items[0].expires_at_ms > 10_000);
}

test "udp bridge retries TURN maintenance with server auth challenge" {
    const encoder = @import("../protocol/stun/encoder.zig");

    var turn_server = try @import("udp_socket.zig").UdpSocket.bind_nonblocking(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer turn_server.deinit();
    const turn_server_addr = try turn_server.local_address();

    var agent = @import("../core/agent.zig").Agent.init(std.testing.allocator);
    defer agent.deinit();
    const stream_id = try agent.add_stream(1);

    var runtime = ice_runtime.IceRuntime.init(std.testing.allocator, &agent, .{}, .{}, .regular);
    defer runtime.deinit();
    try std.testing.expect(try runtime.attach_stream(stream_id));

    var bridge = IceUdpRuntimeBridge.init(std.testing.allocator, &runtime);
    defer bridge.deinit();
    _ = try bridge.add_turn_binding(stream_id, 1, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } }, turn_server_addr);

    const binding = bridge.find_turn_binding(stream_id, 1).?;
    binding.socket.allocation = .{
        .relayed_address = null,
        .mapped_address = null,
        .lifetime_seconds = 120,
        .expires_at_ms = 10_000,
    };

    var prng = std.Random.DefaultPrng.init(52);
    var packet_buf: [512]u8 = undefined;
    _ = try bridge.run_turn_maintenance(prng.random(), 9_500, &packet_buf, .{
        .allocation_refresh_margin_ms = 1_000,
        .username = "u",
    });

    var recv: [512]u8 = undefined;
    const first_req = try turn_server.recv_from(&recv);
    const first_view = try parser.parse_message(recv[0..first_req.bytes]);
    try std.testing.expectEqual(@as(u16, usage_turn.refresh_request_type), first_view.header.message_type);

    var stale_buf: [256]u8 = undefined;
    var stale = try encoder.Builder.init(&stale_buf, usage_turn.refresh_error_response_type, first_view.header.transaction_id);
    const err_438 = [_]u8{ 0x00, 0x00, 0x04, 0x26 };
    try stale.add_attr(usage_turn.error_code_attr_type, &err_438);
    try stale.add_attr(usage_turn.realm_attr_type, "example.org");
    try stale.add_attr(usage_turn.nonce_attr_type, "new-nonce");
    const stale_packet = try stale.finish();
    _ = try turn_server.send_to(first_req.from, stale_packet);

    var recv_buf: [256]u8 = undefined;
    var completed: [1]conncheck.CompletedCheck = undefined;
    _ = try bridge.poll_until_idle(9_600, &recv_buf, &completed);
    try std.testing.expect(binding.socket.has_auth_retry_required());

    _ = try bridge.run_turn_maintenance(prng.random(), 9_700, &packet_buf, .{
        .allocation_refresh_margin_ms = 1_000,
        .username = "u",
    });
    const retry_req = try turn_server.recv_from(&recv);
    const retry_view = try parser.parse_message(recv[0..retry_req.bytes]);
    try std.testing.expectEqual(@as(u16, usage_turn.refresh_request_type), retry_view.header.message_type);
    try std.testing.expectEqualStrings("example.org", (try usage_turn.read_realm(retry_view)).?);
    try std.testing.expectEqualStrings("new-nonce", (try usage_turn.read_nonce(retry_view)).?);
    try std.testing.expect(!binding.socket.has_auth_retry_required());
}

test "udp bridge retries TURN allocate bootstrap with auth challenge" {
    const encoder = @import("../protocol/stun/encoder.zig");

    var turn_server = try @import("udp_socket.zig").UdpSocket.bind_nonblocking(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer turn_server.deinit();
    const turn_server_addr = try turn_server.local_address();

    var agent = @import("../core/agent.zig").Agent.init(std.testing.allocator);
    defer agent.deinit();
    const stream_id = try agent.add_stream(1);

    var runtime = ice_runtime.IceRuntime.init(std.testing.allocator, &agent, .{}, .{}, .regular);
    defer runtime.deinit();
    try std.testing.expect(try runtime.attach_stream(stream_id));

    var bridge = IceUdpRuntimeBridge.init(std.testing.allocator, &runtime);
    defer bridge.deinit();
    _ = try bridge.add_turn_binding(stream_id, 1, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } }, turn_server_addr);

    const binding = bridge.find_turn_binding(stream_id, 1).?;

    var prng = std.Random.DefaultPrng.init(53);
    var packet_buf: [512]u8 = undefined;
    const first = try bridge.run_turn_maintenance(prng.random(), 0, &packet_buf, .{
        .allocate_if_missing = true,
        .allocate_options = .{ .username = "u" },
    });
    try std.testing.expectEqual(@as(usize, 1), first.allocations_requested);

    var recv: [512]u8 = undefined;
    const req1 = try turn_server.recv_from(&recv);
    const req1_view = try parser.parse_message(recv[0..req1.bytes]);
    try std.testing.expectEqual(@as(u16, usage_turn.allocate_request_type), req1_view.header.message_type);

    var err_buf: [256]u8 = undefined;
    var err_builder = try encoder.Builder.init(&err_buf, usage_turn.allocate_error_response_type, req1_view.header.transaction_id);
    const err_401 = [_]u8{ 0x00, 0x00, 0x04, 0x01 };
    try err_builder.add_attr(usage_turn.error_code_attr_type, &err_401);
    try err_builder.add_attr(usage_turn.realm_attr_type, "example.org");
    try err_builder.add_attr(usage_turn.nonce_attr_type, "nonce-2");
    const err_packet = try err_builder.finish();
    _ = try turn_server.send_to(req1.from, err_packet);

    var recv_buf: [256]u8 = undefined;
    var send_buf: [256]u8 = undefined;
    var completed: [1]conncheck.CompletedCheck = undefined;
    var timed_out: [1]ice_runtime.TimedOutCheck = undefined;
    const advanced = try bridge.advance_bidirectional(10, &recv_buf, &send_buf, &completed, &timed_out, .{});
    try std.testing.expectEqual(@as(usize, 1), advanced.turn_auth_challenges);
    try std.testing.expect(binding.socket.has_auth_retry_required());

    _ = try bridge.run_turn_maintenance(prng.random(), 20, &packet_buf, .{
        .allocate_if_missing = true,
        .allocate_options = .{ .username = "u" },
    });
    const req2 = try turn_server.recv_from(&recv);
    const req2_view = try parser.parse_message(recv[0..req2.bytes]);
    try std.testing.expectEqual(@as(u16, usage_turn.allocate_request_type), req2_view.header.message_type);
    try std.testing.expectEqualStrings("example.org", (try usage_turn.read_realm(req2_view)).?);
    try std.testing.expectEqualStrings("nonce-2", (try usage_turn.read_nonce(req2_view)).?);
    try std.testing.expect(!binding.socket.has_auth_retry_required());
}

test "udp bridge reports non-retryable TURN errors" {
    const encoder = @import("../protocol/stun/encoder.zig");

    var turn_server = try @import("udp_socket.zig").UdpSocket.bind_nonblocking(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer turn_server.deinit();
    const turn_server_addr = try turn_server.local_address();

    var agent = @import("../core/agent.zig").Agent.init(std.testing.allocator);
    defer agent.deinit();
    const stream_id = try agent.add_stream(1);

    var runtime = ice_runtime.IceRuntime.init(std.testing.allocator, &agent, .{}, .{}, .regular);
    defer runtime.deinit();
    try std.testing.expect(try runtime.attach_stream(stream_id));

    var bridge = IceUdpRuntimeBridge.init(std.testing.allocator, &runtime);
    defer bridge.deinit();
    _ = try bridge.add_turn_binding(stream_id, 1, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } }, turn_server_addr);

    var prng = std.Random.DefaultPrng.init(54);
    var packet_buf: [512]u8 = undefined;
    _ = try bridge.run_turn_maintenance(prng.random(), 0, &packet_buf, .{
        .allocate_if_missing = true,
        .allocate_options = .{ .username = "u" },
    });

    var recv: [512]u8 = undefined;
    const req = try turn_server.recv_from(&recv);
    const req_view = try parser.parse_message(recv[0..req.bytes]);

    var err_buf: [256]u8 = undefined;
    var err_builder = try encoder.Builder.init(&err_buf, usage_turn.allocate_error_response_type, req_view.header.transaction_id);
    const err_500 = [_]u8{ 0x00, 0x00, 0x05, 0x00 };
    try err_builder.add_attr(usage_turn.error_code_attr_type, &err_500);
    const err_packet = try err_builder.finish();
    _ = try turn_server.send_to(req.from, err_packet);

    var recv_buf: [256]u8 = undefined;
    var send_buf: [256]u8 = undefined;
    var completed: [1]conncheck.CompletedCheck = undefined;
    var timed_out: [1]ice_runtime.TimedOutCheck = undefined;
    const advanced = try bridge.advance_bidirectional(10, &recv_buf, &send_buf, &completed, &timed_out, .{});

    try std.testing.expectEqual(@as(usize, 1), advanced.turn_non_retryable_errors);
    try std.testing.expectEqual(@as(usize, 0), advanced.turn_auth_challenges);
}

test "udp bridge applies bounded backoff after non-retryable TURN errors" {
    const encoder = @import("../protocol/stun/encoder.zig");

    var turn_server = try @import("udp_socket.zig").UdpSocket.bind_nonblocking(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer turn_server.deinit();
    const turn_server_addr = try turn_server.local_address();

    var agent = @import("../core/agent.zig").Agent.init(std.testing.allocator);
    defer agent.deinit();
    const stream_id = try agent.add_stream(1);

    var runtime = ice_runtime.IceRuntime.init(std.testing.allocator, &agent, .{}, .{}, .regular);
    defer runtime.deinit();
    try std.testing.expect(try runtime.attach_stream(stream_id));

    var bridge = IceUdpRuntimeBridge.init(std.testing.allocator, &runtime);
    defer bridge.deinit();
    _ = try bridge.add_turn_binding(stream_id, 1, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } }, turn_server_addr);

    var prng = std.Random.DefaultPrng.init(55);
    var packet_buf: [512]u8 = undefined;
    _ = try bridge.run_turn_maintenance(prng.random(), 0, &packet_buf, .{
        .allocate_if_missing = true,
        .allocate_options = .{ .username = "u" },
    });

    var recv: [512]u8 = undefined;
    const req1 = try turn_server.recv_from(&recv);
    const req1_view = try parser.parse_message(recv[0..req1.bytes]);

    var err_buf: [256]u8 = undefined;
    var err_builder = try encoder.Builder.init(&err_buf, usage_turn.allocate_error_response_type, req1_view.header.transaction_id);
    const err_500 = [_]u8{ 0x00, 0x00, 0x05, 0x00 };
    try err_builder.add_attr(usage_turn.error_code_attr_type, &err_500);
    const err_packet = try err_builder.finish();
    _ = try turn_server.send_to(req1.from, err_packet);

    var recv_buf: [256]u8 = undefined;
    var send_buf: [256]u8 = undefined;
    var completed: [1]conncheck.CompletedCheck = undefined;
    var timed_out: [1]ice_runtime.TimedOutCheck = undefined;
    _ = try bridge.advance_bidirectional(10, &recv_buf, &send_buf, &completed, &timed_out, .{});

    const early = try bridge.run_turn_maintenance(prng.random(), 500, &packet_buf, .{
        .allocate_if_missing = true,
        .allocate_options = .{ .username = "u" },
    });
    try std.testing.expectEqual(@as(usize, 0), early.allocations_requested);
    try std.testing.expectEqual(@as(usize, 1), early.backoff_skipped_bindings);
    try std.testing.expect(early.max_backoff_until_ms > 500);
    try std.testing.expectEqual(@as(u8, 1), early.max_error_streak);
    try std.testing.expectEqual(@as(?u16, 500), early.last_error_code_seen);

    const late = try bridge.run_turn_maintenance(prng.random(), 1_020, &packet_buf, .{
        .allocate_if_missing = true,
        .allocate_options = .{ .username = "u" },
    });
    try std.testing.expectEqual(@as(usize, 1), late.allocations_requested);

    var diags: [2]TurnBindingDiagnostic = undefined;
    const diag_count = bridge.collect_turn_binding_diagnostics(&diags);
    try std.testing.expectEqual(@as(usize, 1), diag_count);
    try std.testing.expectEqual(stream_id, diags[0].stream_id);
    try std.testing.expectEqual(@as(u16, 1), diags[0].component_id);
    try std.testing.expectEqual(@as(?u16, 500), diags[0].last_error_code);
    try std.testing.expect(diags[0].non_retryable_error_streak >= 1);
}

test "udp bridge snapshots TURN maintenance status without ticking" {
    var agent = @import("../core/agent.zig").Agent.init(std.testing.allocator);
    defer agent.deinit();
    const stream_id = try agent.add_stream(1);

    var runtime = ice_runtime.IceRuntime.init(std.testing.allocator, &agent, .{}, .{}, .regular);
    defer runtime.deinit();
    try std.testing.expect(try runtime.attach_stream(stream_id));

    var bridge = IceUdpRuntimeBridge.init(std.testing.allocator, &runtime);
    defer bridge.deinit();
    _ = try bridge.add_turn_binding(
        stream_id,
        1,
        .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } },
        .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 3478 } },
    );

    const binding = bridge.find_turn_binding(stream_id, 1).?;
    binding.socket.allocation = .{
        .relayed_address = null,
        .mapped_address = null,
        .lifetime_seconds = 120,
        .expires_at_ms = 55_000,
    };
    const peer: candidate.Address = .{ .ipv4 = .{ .ip = .{ 203, 0, 113, 120 }, .port = 4000 } };
    try binding.socket.set_permission(peer, 1_000, 300);
    try binding.socket.set_channel_binding(0x4011, peer, 1_000, 600);
    binding.non_retryable_error_streak = 2;
    binding.maintenance_backoff_until_ms = 9_000;

    var status: [2]TurnMaintenanceStatus = undefined;
    const count = bridge.collect_turn_maintenance_status(&status);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(stream_id, status[0].stream_id);
    try std.testing.expectEqual(@as(u16, 1), status[0].component_id);
    try std.testing.expect(status[0].has_allocation);
    try std.testing.expectEqual(@as(u64, 55_000), status[0].allocation_expires_at_ms);
    try std.testing.expectEqual(@as(usize, 1), status[0].permission_count);
    try std.testing.expectEqual(@as(usize, 1), status[0].channel_count);
    try std.testing.expectEqual(@as(u8, 2), status[0].non_retryable_error_streak);
    try std.testing.expectEqual(@as(u64, 9_000), status[0].maintenance_backoff_until_ms);
}

test "udp bridge routes relay checks over TURN TCP and completes response" {
    const tcp_socket = @import("tcp_candidate_socket.zig");
    const turn_tcp = @import("turn_socket_tcp.zig");
    const encoder = @import("../protocol/stun/encoder.zig");

    var turn_listener = try tcp_socket.TcpListener.bind_nonblocking(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } }, 8);
    defer turn_listener.deinit();

    var agent = @import("../core/agent.zig").Agent.init(std.testing.allocator);
    defer agent.deinit();

    const stream_id = try agent.add_stream(1);
    const relay_local: candidate.Address = .{ .ipv4 = .{ .ip = .{ 10, 0, 0, 5 }, .port = 62001 } };
    const remote_addr: candidate.Address = .{ .ipv4 = .{ .ip = .{ 198, 51, 100, 47 }, .port = 5003 } };

    try std.testing.expect(try agent.add_local_candidate(stream_id, .{
        .id = 601,
        .component_id = 1,
        .candidate_type = .relay,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .relay, relay_local),
        .priority = candidate.compute_candidate_priority(.relay, 50, 1),
        .address = relay_local,
    }));
    try std.testing.expect(try agent.add_remote_candidate(stream_id, .{
        .id = 602,
        .component_id = 1,
        .candidate_type = .srflx,
        .transport = .udp,
        .foundation = candidate.compute_foundation(.udp, .srflx, remote_addr),
        .priority = candidate.compute_candidate_priority(.srflx, 90, 1),
        .address = remote_addr,
    }));

    var runtime = ice_runtime.IceRuntime.init(std.testing.allocator, &agent, .{}, .{}, .regular);
    defer runtime.deinit();
    try std.testing.expect(try runtime.attach_stream(stream_id));
    _ = try runtime.populate_stream_checklists(stream_id, true, 14_000);
    try runtime.start_connecting_all();

    var bridge = IceUdpRuntimeBridge.init(std.testing.allocator, &runtime);
    defer bridge.deinit();
    _ = try bridge.add_turn_tcp_binding(stream_id, 1, turn_listener.local_address());

    var server_stream: ?tcp_socket.TcpStream = null;
    var tries: usize = 0;
    while (tries < 500 and server_stream == null) : (tries += 1) {
        server_stream = try turn_listener.accept_nonblocking();
    }
    try std.testing.expect(server_stream != null);
    var server = server_stream.?;
    defer server.deinit();

    var prng = std.Random.DefaultPrng.init(56);
    var packet_buf: [512]u8 = undefined;
    _ = (try bridge.start_and_send_next_check(prng.random(), 0, &packet_buf, .{
        .username = "l:r",
        .priority = 700,
        .role = .{ .role = .controlling, .tie_breaker = 101 },
    })).?;

    var server_framer = turn_tcp.TurnTcpFramer.init(std.testing.allocator);
    defer server_framer.deinit();
    var recv: [1024]u8 = undefined;
    var payload: [1024]u8 = undefined;
    var outbound: ?turn_tcp.TurnTcpPacket = null;
    tries = 0;
    while (tries < 500 and outbound == null) : (tries += 1) {
        const n = server.recv(&recv) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) continue;
        try server_framer.push(recv[0..n]);
        outbound = try server_framer.pop_packet(&payload);
    }
    try std.testing.expect(outbound != null);

    const send_ind = switch (outbound.?) {
        .stun => |view| view,
        else => return error.UnexpectedPacketType,
    };
    try std.testing.expectEqual(@as(u16, usage_turn.send_indication_type), send_ind.header.message_type);
    const inner_request = try parser.parse_message((try usage_turn.read_data_attr(send_ind)).?);
    try std.testing.expect(usage_ice.is_connectivity_check_request(inner_request));

    var success_buf: [256]u8 = undefined;
    const success = try usage_ice.build_connectivity_check_success_response(&success_buf, inner_request.header.transaction_id, .{});

    var indication_buf: [512]u8 = undefined;
    const indication_tx = [_]u8{ 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41 };
    var builder = try encoder.Builder.init(&indication_buf, usage_turn.data_indication_type, indication_tx);
    try address_attrs.add_xor_peer_address(&builder, .{ .ipv4 = .{ .ip = remote_addr.ipv4.ip, .port = remote_addr.ipv4.port } }, indication_tx);
    try builder.add_attr(usage_turn.data_attr_type, success);
    const indication = try builder.finish();

    var framed: [1024]u8 = undefined;
    const framed_packet = try turn_tcp.encode_framed_payload(&framed, indication);
    _ = try server.send(framed_packet);

    var bridge_recv: [1024]u8 = undefined;
    var bridge_send: [1024]u8 = undefined;
    var completed: [2]conncheck.CompletedCheck = undefined;
    var timed_out: [2]ice_runtime.TimedOutCheck = undefined;
    const summary = try bridge.advance_bidirectional(100, &bridge_recv, &bridge_send, &completed, &timed_out, .{});
    try std.testing.expectEqual(@as(usize, 1), summary.completed_checks);
    try std.testing.expectEqual(@as(u64, 14_000), completed[0].meta.candidate_pair_id);
}
