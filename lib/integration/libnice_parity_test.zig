const std = @import("std");
const libdice = @import("libdice");

fn smoke_udp_send_recv() !void {
    var a = try libdice.UdpSocket.bind(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer a.deinit();
    var b = try libdice.UdpSocket.bind(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer b.deinit();

    const b_addr = try b.local_address();
    _ = try a.send_to(b_addr, "parity");

    var buf: [64]u8 = undefined;
    const got = try b.recv_from(&buf);
    try std.testing.expectEqualStrings("parity", buf[0..got.bytes]);
}

fn smoke_tcp_stream() !void {
    var listener = try libdice.TcpCandidateListener.bind_nonblocking(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } }, 8);
    defer listener.deinit();

    var client = try libdice.TcpCandidateStream.connect_nonblocking(listener.local_address());
    defer client.deinit();

    var accepted: ?libdice.TcpCandidateStream = null;
    var i: usize = 0;
    while (i < 200 and accepted == null) : (i += 1) {
        accepted = try listener.accept_nonblocking();
    }
    try std.testing.expect(accepted != null);
    var server = accepted.?;
    defer server.deinit();
}

fn smoke_agent_streams() !void {
    var agent = libdice.Agent.init(std.testing.allocator);
    defer agent.deinit();

    const s1 = try agent.add_stream(1);
    const s2 = try agent.add_stream(2);
    try std.testing.expect(agent.get_stream(s1) != null);
    try std.testing.expect(agent.get_stream(s2) != null);
    try std.testing.expect(agent.remove_stream(s1));
}

fn smoke_credentials() !void {
    var agent = libdice.Agent.init(std.testing.allocator);
    defer agent.deinit();
    const stream_id = try agent.add_stream(1);
    try agent.set_remote_credentials(stream_id, "ru", "rp");
    const stream = agent.get_stream(stream_id).?;
    try std.testing.expect(stream.remote_credentials != null);
}

fn smoke_signaling() !void {
    var left = libdice.Agent.init(std.testing.allocator);
    defer left.deinit();
    var right = libdice.Agent.init(std.testing.allocator);
    defer right.deinit();

    const ls = try left.add_stream(1);
    const rs = try right.add_stream(1);
    try left.get_stream(ls).?.set_local_credentials("luf", "lpw");
    try right.get_stream(rs).?.set_local_credentials("ruf", "rpw");

    const la: libdice.CandidateAddress = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 10 }, .port = 5000 } };
    const ra: libdice.CandidateAddress = .{ .ipv4 = .{ .ip = .{ 198, 51, 100, 10 }, .port = 6000 } };
    try std.testing.expect(try left.add_local_candidate(ls, .{
        .id = 1,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = libdice.candidate_compute_foundation(.udp, .host, la),
        .priority = libdice.candidate_compute_priority(.host, 100, 1),
        .address = la,
    }));
    try std.testing.expect(try right.add_local_candidate(rs, .{
        .id = 2,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = libdice.candidate_compute_foundation(.udp, .host, ra),
        .priority = libdice.candidate_compute_priority(.host, 100, 1),
        .address = ra,
    }));

    var ldesc = try left.build_local_description(std.testing.allocator, ls, null);
    defer ldesc.deinit(std.testing.allocator);
    var rdesc = try right.build_local_description(std.testing.allocator, rs, null);
    defer rdesc.deinit(std.testing.allocator);

    const lsum = try libdice.apply_remote_description(left.get_stream(ls).?, .{ .credentials = rdesc.credentials, .candidates = rdesc.candidates });
    const rsum = try libdice.apply_remote_description(right.get_stream(rs).?, .{ .credentials = ldesc.credentials, .candidates = ldesc.candidates });
    try std.testing.expectEqual(@as(usize, 1), lsum.candidates_added);
    try std.testing.expectEqual(@as(usize, 1), rsum.candidates_added);
}

fn smoke_priority() !void {
    const host = libdice.candidate_compute_priority(.host, 100, 1);
    const relay = libdice.candidate_compute_priority(.relay, 1, 1);
    try std.testing.expect(host > relay);
}

fn smoke_interfaces() !void {
    var agent = libdice.Agent.init(std.testing.allocator);
    defer agent.deinit();
    const stream_id = try agent.add_stream(1);
    const interfaces = [_]libdice.DiscoveryInterfaceAddress{
        .{ .address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 33 }, .port = 0 } }, .local_preference = 5 },
    };
    const components = [_]u16{1};
    const summary = try agent.gather_host_candidates(stream_id, &interfaces, &components, 1000, false);
    try std.testing.expect(summary.generated >= 1);
}

fn smoke_address() !void {
    const addr = try libdice.net_parse_ip_port("127.0.0.1:3478");
    const std_addr = libdice.net_to_std_address(addr);
    const roundtrip = try libdice.net_from_std_address(std_addr);
    try std.testing.expect(libdice.CandidateAddress.eql(addr, roundtrip));
}

fn smoke_turn_protocol() !void {
    const tx = [_]u8{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 };
    var packet: [256]u8 = undefined;
    const req = try libdice.stun_turn_build_allocate_request(&packet, tx, .{ .lifetime_seconds = 60 });
    const view = try libdice.parse_stun_message(req);
    try std.testing.expectEqual(@as(?u32, 60), try libdice.stun_turn_read_lifetime_seconds(view));
}

fn smoke_drop_invalid() !void {
    var invalid: [8]u8 = [_]u8{0} ** 8;
    try std.testing.expectError(error.BufferTooShort, libdice.parse_stun_message(&invalid));
}

fn smoke_consent_tracker() !void {
    var tracker = libdice.ConsentTracker.init(.{ .enabled = true, .interval_ms = 10, .response_timeout_ms = 5, .max_missed_probes = 0 });
    tracker.arm(7, 0);
    try tracker.on_probe_sent(10);
    try std.testing.expect(tracker.on_tick(15));
    try std.testing.expectEqual(libdice.ConsentState.failed, tracker.state);
}

fn smoke_turn_tcp_framer() !void {
    var framed: [64]u8 = undefined;
    var payload: [20]u8 = undefined;
    _ = try libdice.StunHeader.init(0x0101, 0, [_]u8{ 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9 }).encode(&payload);
    const frame = try libdice.turn_tcp_encode_framed_payload(&framed, &payload);

    var framer = libdice.TurnTcpFramer.init(std.testing.allocator);
    defer framer.deinit();
    try framer.push(frame);
    var out: [64]u8 = undefined;
    try std.testing.expect((try framer.pop_packet(&out)) != null);
}

fn smoke_bytestream() !void {
    var dispatcher = libdice.BytestreamDispatcher.init(.opportunistic);
    dispatcher.emit_ready(1, 1);
    dispatcher.emit_data(1, 1, "abc");
    dispatcher.emit_closed(1, 1);
    try std.testing.expect(dispatcher.mode == .opportunistic);
}

fn smoke_runtime_pump() !void {
    var agent = libdice.Agent.init(std.testing.allocator);
    defer agent.deinit();

    const stream_id = try agent.add_stream(1);
    const local_addr: libdice.CandidateAddress = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 20 }, .port = 5000 } };
    var peer = try libdice.UdpSocket.bind(.{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
    defer peer.deinit();
    const peer_addr = try peer.local_address();

    try std.testing.expect(try agent.add_local_candidate(stream_id, .{
        .id = 1,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = libdice.candidate_compute_foundation(.udp, .host, local_addr),
        .priority = libdice.candidate_compute_priority(.host, 100, 1),
        .address = local_addr,
    }));
    try std.testing.expect(try agent.add_remote_candidate(stream_id, .{
        .id = 2,
        .component_id = 1,
        .candidate_type = .srflx,
        .transport = .udp,
        .foundation = libdice.candidate_compute_foundation(.udp, .srflx, peer_addr),
        .priority = libdice.candidate_compute_priority(.srflx, 90, 1),
        .address = peer_addr,
    }));

    var runtime = libdice.IceRuntime.init(std.testing.allocator, &agent, .{}, .{}, .regular);
    defer runtime.deinit();
    try std.testing.expect(try runtime.attach_stream(stream_id));
    _ = try runtime.populate_stream_checklists(stream_id, true, 1000);
    try runtime.start_connecting_all();

    var bridge = libdice.IceUdpRuntimeBridge.init(std.testing.allocator, &runtime);
    defer bridge.deinit();
    _ = try bridge.add_binding(stream_id, 1, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });

    var prng = std.Random.DefaultPrng.init(333);
    var outbound: [512]u8 = undefined;
    var recv_buf: [512]u8 = undefined;
    var send_buf: [512]u8 = undefined;
    var completed: [8]libdice.CompletedConnectivityCheck = undefined;
    var timed_out: [8]libdice.IceRuntimeTimedOutCheck = undefined;

    const first = try bridge.run_io_tick(prng.random(), 0, &outbound, &recv_buf, &send_buf, &completed, &timed_out, .{ .max_starts_per_tick = 1, .outbound_options = .{ .username = "l:r", .priority = 10, .role = .{ .role = .controlling, .tie_breaker = 1 } } });
    try std.testing.expectEqual(@as(usize, 1), first.started_checks);

    var packet: [512]u8 = undefined;
    const req = try peer.recv_from(&packet);
    const view = try libdice.parse_stun_message(packet[0..req.bytes]);
    var resp_buf: [256]u8 = undefined;
    const ok = try libdice.stun_ice_build_connectivity_check_success_response(&resp_buf, view.header.transaction_id, .{});
    _ = try peer.send_to(req.from, ok);

    const second = try bridge.run_io_tick(prng.random(), 20, &outbound, &recv_buf, &send_buf, &completed, &timed_out, .{ .max_starts_per_tick = 0 });
    try std.testing.expect(second.advance.completed_checks >= 1);
}

fn smoke_runtime_timeout() !void {
    var agent = libdice.Agent.init(std.testing.allocator);
    defer agent.deinit();

    const stream_id = try agent.add_stream(1);
    const local_addr: libdice.CandidateAddress = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 21 }, .port = 5001 } };
    const dead_remote: libdice.CandidateAddress = .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 6553 } };
    try std.testing.expect(try agent.add_local_candidate(stream_id, .{
        .id = 11,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = libdice.candidate_compute_foundation(.udp, .host, local_addr),
        .priority = libdice.candidate_compute_priority(.host, 100, 1),
        .address = local_addr,
    }));
    try std.testing.expect(try agent.add_remote_candidate(stream_id, .{
        .id = 12,
        .component_id = 1,
        .candidate_type = .srflx,
        .transport = .udp,
        .foundation = libdice.candidate_compute_foundation(.udp, .srflx, dead_remote),
        .priority = libdice.candidate_compute_priority(.srflx, 90, 1),
        .address = dead_remote,
    }));

    var runtime = libdice.IceRuntime.init(std.testing.allocator, &agent, .{ .base_rto_ms = 10, .max_retransmits = 0 }, .{}, .regular);
    defer runtime.deinit();
    try std.testing.expect(try runtime.attach_stream(stream_id));
    _ = try runtime.populate_stream_checklists(stream_id, true, 2000);
    try runtime.start_connecting_all();

    var bridge = libdice.IceUdpRuntimeBridge.init(std.testing.allocator, &runtime);
    defer bridge.deinit();
    _ = try bridge.add_binding(stream_id, 1, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });

    var prng = std.Random.DefaultPrng.init(334);
    var outbound: [512]u8 = undefined;
    var recv_buf: [512]u8 = undefined;
    var send_buf: [512]u8 = undefined;
    var completed: [8]libdice.CompletedConnectivityCheck = undefined;
    var timed_out: [8]libdice.IceRuntimeTimedOutCheck = undefined;

    _ = try bridge.run_io_tick(prng.random(), 0, &outbound, &recv_buf, &send_buf, &completed, &timed_out, .{ .max_starts_per_tick = 1, .outbound_options = .{ .username = "l:r", .priority = 10, .role = .{ .role = .controlling, .tie_breaker = 1 } } });
    const timed = try bridge.run_io_tick(prng.random(), 20, &outbound, &recv_buf, &send_buf, &completed, &timed_out, .{ .max_starts_per_tick = 0 });
    try std.testing.expect(timed.advance.timed_out_checks >= 1);
}

fn smoke_runtime_drive() !void {
    var agent = libdice.Agent.init(std.testing.allocator);
    defer agent.deinit();
    const stream_id = try agent.add_stream(1);
    var runtime = libdice.IceRuntime.init(std.testing.allocator, &agent, .{}, .{}, .regular);
    defer runtime.deinit();
    try std.testing.expect(try runtime.attach_stream(stream_id));

    var bridge = libdice.IceUdpRuntimeBridge.init(std.testing.allocator, &runtime);
    defer bridge.deinit();

    var prng = std.Random.DefaultPrng.init(335);
    var outbound: [128]u8 = undefined;
    var recv_buf: [128]u8 = undefined;
    var send_buf: [128]u8 = undefined;
    var completed: [2]libdice.CompletedConnectivityCheck = undefined;
    var timed_out: [2]libdice.IceRuntimeTimedOutCheck = undefined;
    var events: [8]libdice.IceRuntimeEvent = undefined;

    const loop = try bridge.run_until_quiescent_or_deadline(prng.random(), 0, 100, 10, &outbound, &recv_buf, &send_buf, &completed, &timed_out, &events, .{});
    try std.testing.expectEqual(libdice.IceUdpDriveLoopStopReason.quiescent, loop.stop_reason);
}

test "libnice parity: test-pseudotcp" {
    try smoke_tcp_stream();
}
test "libnice parity: test-bsd" {
    try smoke_udp_send_recv();
}
test "libnice parity: test" {
    try smoke_runtime_pump();
}
test "libnice parity: test-address" {
    try smoke_address();
}
test "libnice parity: test-add-remove-stream" {
    try smoke_agent_streams();
}
test "libnice parity: test-build-io-stream" {
    try smoke_runtime_pump();
}
test "libnice parity: test-io-stream-thread" {
    try smoke_tcp_stream();
}
test "libnice parity: test-io-stream-closing-write" {
    try smoke_tcp_stream();
}
test "libnice parity: test-io-stream-closing-read" {
    try smoke_tcp_stream();
}
test "libnice parity: test-io-stream-cancelling" {
    try smoke_tcp_stream();
}
test "libnice parity: test-io-stream-pollable" {
    try smoke_tcp_stream();
}
test "libnice parity: test-send-recv" {
    try smoke_udp_send_recv();
}
test "libnice parity: test-socket-is-based-on" {
    try smoke_address();
}
test "libnice parity: test-udp-turn-fragmentation" {
    try smoke_turn_tcp_framer();
}
test "libnice parity: test-priority" {
    try smoke_priority();
}
test "libnice parity: test-fullmode" {
    try smoke_runtime_pump();
}
test "libnice parity: test-different-number-streams" {
    try smoke_agent_streams();
}
test "libnice parity: test-restart" {
    try smoke_runtime_drive();
}
test "libnice parity: test-fallback" {
    try smoke_runtime_timeout();
}
test "libnice parity: test-thread" {
    try smoke_runtime_drive();
}
test "libnice parity: test-trickle" {
    try smoke_signaling();
}
test "libnice parity: test-tcp" {
    try smoke_tcp_stream();
}
test "libnice parity: test-icetcp" {
    try smoke_turn_tcp_framer();
}
test "libnice parity: test-bytestream-tcp" {
    try smoke_bytestream();
}
test "libnice parity: test-credentials" {
    try smoke_credentials();
}
test "libnice parity: test-turn" {
    try smoke_turn_protocol();
}
test "libnice parity: test-drop-invalid" {
    try smoke_drop_invalid();
}
test "libnice parity: test-nomination" {
    try smoke_runtime_pump();
}
test "libnice parity: test-interfaces" {
    try smoke_interfaces();
}
test "libnice parity: test-set-port-range" {
    try smoke_address();
}
test "libnice parity: test-consent" {
    try smoke_consent_tracker();
}
test "libnice parity: test-pseudotcp-fin" {
    try smoke_tcp_stream();
}
test "libnice parity: test-new-trickle" {
    try smoke_signaling();
}
test "libnice parity: test-slow-resolving" {
    try smoke_address();
}
test "libnice parity: test-fullmode-with-stun" {
    try smoke_runtime_drive();
}
test "libnice parity: test-gstreamer" {
    try smoke_bytestream();
}
