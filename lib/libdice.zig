const std = @import("std");

pub const EventLoop = @import("core/events.zig").EventLoop;
pub const EventTask = @import("core/events.zig").Task;
pub const FeatureFlags = @import("core/feature_flags.zig").FeatureFlags;
pub const TimerWheel = @import("core/timers.zig").TimerWheel;
pub const TimerId = @import("core/timers.zig").TimerId;
pub const ConnectivityCheckTracker = @import("core/conncheck.zig").ConnectivityCheckTracker;
pub const ConnectivityCheckMeta = @import("core/conncheck.zig").CheckMeta;
pub const CompletedConnectivityCheck = @import("core/conncheck.zig").CompletedCheck;
pub const TimedOutConnectivityCheck = @import("core/conncheck.zig").TimedOutCheck;
pub const ComponentConnectivityEngine = @import("core/connectivity_engine.zig").ComponentConnectivityEngine;
pub const ComponentPairContext = @import("core/connectivity_engine.zig").PairContext;
pub const Checklist = @import("core/checklist.zig").Checklist;
pub const ChecklistPair = @import("core/checklist.zig").Pair;
pub const ChecklistPairState = @import("core/checklist.zig").PairState;
pub const checklist_compute_pair_priority = @import("core/checklist.zig").compute_pair_priority;
pub const Agent = @import("core/agent.zig").Agent;
pub const Stream = @import("core/stream.zig").Stream;
pub const Credentials = @import("core/stream.zig").Credentials;
pub const Candidate = @import("core/candidate.zig").Candidate;
pub const CandidateType = @import("core/candidate.zig").CandidateType;
pub const CandidateTransport = @import("core/candidate.zig").Transport;
pub const CandidateAddress = @import("core/candidate.zig").Address;
pub const CandidateList = @import("core/candidate.zig").CandidateList;
pub const candidate_compute_priority = @import("core/candidate.zig").compute_candidate_priority;
pub const candidate_compute_foundation = @import("core/candidate.zig").compute_foundation;
pub const DiscoveryInterfaceAddress = @import("core/discovery.zig").InterfaceAddress;
pub const gather_host_candidates = @import("core/discovery.zig").gather_host_candidates;
pub const AgentGatherSummary = @import("core/agent.zig").GatherSummary;
pub const Component = @import("core/component.zig").Component;
pub const ComponentState = @import("core/component.zig").ComponentState;
pub const SelectedPair = @import("core/component.zig").SelectedPair;
pub const StunHeader = @import("protocol/stun/message.zig").Header;
pub const StunMessageClass = @import("protocol/stun/message.zig").MessageClass;
pub const StunAttrHeader = @import("protocol/stun/attrs.zig").AttrHeader;
pub const StunAddress = @import("protocol/stun/address_attrs.zig").StunAddress;
pub const TurnChannelDataFrameView = @import("protocol/turn/channel_data.zig").FrameView;
pub const StunMessageView = @import("protocol/stun/parser.zig").MessageView;
pub const parse_stun_message = @import("protocol/stun/parser.zig").parse_message;
pub const StunMessageBuilder = @import("protocol/stun/encoder.zig").Builder;
pub const StunTransactionId = @import("protocol/stun/transaction.zig").TransactionId;
pub const StunRetryPolicy = @import("protocol/stun/timer.zig").RetryPolicy;
pub const StunPendingTransaction = @import("protocol/stun/transaction.zig").PendingTransaction;
pub const StunMatchedResponse = @import("protocol/stun/transaction.zig").MatchedResponse;
pub const StunTransactionStore = @import("protocol/stun/transaction.zig").TransactionStore;
pub const stun_tx_from_rng = @import("protocol/stun/transaction.zig").from_rng;
pub const stun_tx_equals = @import("protocol/stun/transaction.zig").equals;
pub const stun_message_class = @import("protocol/stun/message.zig").message_class;
pub const stun_is_response_type = @import("protocol/stun/message.zig").is_response_type;
pub const stun_is_error_response_type = @import("protocol/stun/message.zig").is_error_response_type;
pub const stun_build_binding_request = @import("protocol/stun/usage_bind.zig").build_binding_request;
pub const stun_build_binding_success_response = @import("protocol/stun/usage_bind.zig").build_binding_success_response;
pub const stun_parse_binding_response = @import("protocol/stun/usage_bind.zig").parse_binding_response;
pub const stun_is_binding_request = @import("protocol/stun/usage_bind.zig").is_binding_request;
pub const stun_is_binding_response = @import("protocol/stun/usage_bind.zig").is_binding_response;
pub const stun_ice_add_priority = @import("protocol/stun/usage_ice.zig").add_priority;
pub const stun_ice_add_use_candidate = @import("protocol/stun/usage_ice.zig").add_use_candidate;
pub const stun_ice_has_use_candidate = @import("protocol/stun/usage_ice.zig").has_use_candidate;
pub const stun_ice_build_connectivity_check_request = @import("protocol/stun/usage_ice.zig").build_connectivity_check_request;
pub const stun_ice_build_connectivity_check_success_response = @import("protocol/stun/usage_ice.zig").build_connectivity_check_success_response;
pub const stun_ice_parse_connectivity_check_request = @import("protocol/stun/usage_ice.zig").parse_connectivity_check_request;
pub const stun_ice_is_connectivity_check_request = @import("protocol/stun/usage_ice.zig").is_connectivity_check_request;
pub const stun_ice_is_connectivity_check_success_response = @import("protocol/stun/usage_ice.zig").is_connectivity_check_success_response;
pub const stun_turn_build_allocate_request = @import("protocol/stun/usage_turn.zig").build_allocate_request;
pub const stun_turn_build_refresh_request = @import("protocol/stun/usage_turn.zig").build_refresh_request;
pub const stun_turn_build_channel_bind_request = @import("protocol/stun/usage_turn.zig").build_channel_bind_request;
pub const stun_turn_build_send_indication = @import("protocol/stun/usage_turn.zig").build_send_indication;
pub const stun_turn_build_create_permission_request = @import("protocol/stun/usage_turn.zig").build_create_permission_request;
pub const stun_turn_is_allocate_success_response = @import("protocol/stun/usage_turn.zig").is_allocate_success_response;
pub const stun_turn_is_allocate_error_response = @import("protocol/stun/usage_turn.zig").is_allocate_error_response;
pub const stun_turn_read_lifetime_seconds = @import("protocol/stun/usage_turn.zig").read_lifetime_seconds;
pub const stun_turn_read_requested_transport = @import("protocol/stun/usage_turn.zig").read_requested_transport;
pub const stun_turn_read_error_code = @import("protocol/stun/usage_turn.zig").read_error_code;
pub const stun_turn_parse_allocate_success_response = @import("protocol/stun/usage_turn.zig").parse_allocate_success_response;
pub const stun_turn_parse_refresh_success_response = @import("protocol/stun/usage_turn.zig").parse_refresh_success_response;
pub const stun_turn_read_channel_number = @import("protocol/stun/usage_turn.zig").read_channel_number;
pub const stun_turn_read_data_attr = @import("protocol/stun/usage_turn.zig").read_data_attr;
pub const stun_turn_count_xor_peer_addresses = @import("protocol/stun/usage_turn.zig").count_xor_peer_addresses;
pub const turn_channel_encode_frame = @import("protocol/turn/channel_data.zig").encode_frame;
pub const turn_channel_decode_frame = @import("protocol/turn/channel_data.zig").decode_frame;
pub const stun_message_integrity_type = @import("protocol/stun/integrity.zig").message_integrity_type;
pub const stun_fingerprint_type = @import("protocol/stun/integrity.zig").fingerprint_type;
pub const stun_compute_message_integrity = @import("protocol/stun/integrity.zig").compute_message_integrity;
pub const stun_verify_message_integrity = @import("protocol/stun/integrity.zig").verify_message_integrity;
pub const stun_compute_fingerprint = @import("protocol/stun/integrity.zig").compute_fingerprint;
pub const stun_add_message_integrity_attr = @import("protocol/stun/integrity.zig").add_message_integrity_attr;
pub const stun_add_fingerprint_attr = @import("protocol/stun/integrity.zig").add_fingerprint_attr;
pub const stun_verify_embedded_message_integrity = @import("protocol/stun/integrity.zig").verify_embedded_message_integrity;
pub const stun_verify_embedded_fingerprint = @import("protocol/stun/integrity.zig").verify_embedded_fingerprint;
pub const HmacSha1Mac = @import("crypto/hmac_sha1.zig").Mac;
pub const hmac_sha1_compute = @import("crypto/hmac_sha1.zig").compute;
pub const hmac_sha1_verify = @import("crypto/hmac_sha1.zig").verify;
pub const Md5Digest = @import("crypto/md5.zig").Digest;
pub const md5_digest = @import("crypto/md5.zig").digest;

pub const version = "0.0.1";

pub fn active_feature_flags() FeatureFlags {
    return FeatureFlags.from_build_options();
}

pub fn build_banner() []const u8 {
    return "libdice: bootstrap build is healthy";
}

test "build_banner returns expected string" {
    try std.testing.expectEqualStrings("libdice: bootstrap build is healthy", build_banner());
}

test "exports are reachable" {
    var flags = FeatureFlags{};
    try std.testing.expect(flags.ice_udp);
    flags.ice_udp = false;
    try std.testing.expect(!flags.ice_udp);
    try std.testing.expectEqualStrings("0.0.1", version);
}

test "active feature flags are accessible" {
    const flags = active_feature_flags();
    try std.testing.expect(flags.ice_udp);
}

test "timer wheel export is reachable" {
    var wheel = TimerWheel.init(std.testing.allocator);
    defer wheel.deinit();

    try std.testing.expectEqual(@as(usize, 0), wheel.pending_count());
}

test "connectivity check tracker export is reachable" {
    var tracker = ConnectivityCheckTracker.init(std.testing.allocator, StunRetryPolicy{});
    defer tracker.deinit();

    const tx_id = [_]u8{ 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41 };
    try tracker.start_check(tx_id, 0, 1, .{ .stream_id = 1, .component_id = 1, .candidate_pair_id = 1 });
    try std.testing.expectEqual(@as(usize, 1), tracker.pending_count());

    var packet: [20]u8 = undefined;
    const header = StunHeader.init(0x0101, 0, tx_id);
    _ = try header.encode(&packet);

    const view = try parse_stun_message(&packet);
    const completed: CompletedConnectivityCheck = try tracker.on_response(view, 10);
    try std.testing.expectEqual(@as(u64, 1), completed.user_tag);
}

test "component connectivity engine export is reachable" {
    var engine = ComponentConnectivityEngine.init(std.testing.allocator, 1, 1, StunRetryPolicy{});
    defer engine.deinit();

    try engine.start_connecting();
    try engine.add_pair(.{
        .id = 1,
        .local_candidate_id = 10,
        .remote_candidate_id = 20,
        .priority = 100,
        .component_id = 1,
        .state = .waiting,
    }, .{ .local_candidate_id = 10, .remote_candidate_id = 20, .nominated = true });

    var prng = std.Random.DefaultPrng.init(5);
    const tx_id = (try engine.start_next_check(prng.random(), 0)).?;

    var packet: [20]u8 = undefined;
    const header = StunHeader.init(0x0101, 0, tx_id);
    _ = try header.encode(&packet);

    const view = try parse_stun_message(&packet);
    const completed = try engine.on_response(view, 10);
    try std.testing.expectEqual(@as(u64, 1), completed.meta.candidate_pair_id);
}

test "checklist exports are reachable" {
    var checklist = Checklist.init(std.testing.allocator);
    defer checklist.deinit();

    const pair_priority = checklist_compute_pair_priority(true, 1000, 900);
    try checklist.add_pair(.{
        .id = 1,
        .local_candidate_id = 1,
        .remote_candidate_id = 2,
        .priority = pair_priority,
        .component_id = 1,
        .state = .waiting,
    });

    const next: *ChecklistPair = checklist.pop_next_ordinary().?;
    try std.testing.expectEqual(ChecklistPairState.in_progress, next.state);
}

test "agent stream component exports are reachable" {
    var agent = Agent.init(std.testing.allocator);
    defer agent.deinit();

    const stream_id = try agent.add_stream(2);
    const stream: *Stream = agent.get_stream(stream_id).?;
    try std.testing.expectEqual(@as(usize, 2), stream.component_count());

    const component: *Component = agent.get_component(stream_id, 1).?;
    try component.start_gathering();
    try component.start_connecting();
    try component.on_check_succeeded(1, 10, 20, true);
    try std.testing.expectEqual(ComponentState.ready, component.state);

    const addr: CandidateAddress = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 9 }, .port = 7777 } };
    const local = Candidate{
        .id = 10,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = candidate_compute_foundation(.udp, .host, addr),
        .priority = candidate_compute_priority(.host, 100, 1),
        .address = addr,
    };

    try std.testing.expect(try agent.add_local_candidate(stream_id, local));
    try std.testing.expectEqual(@as(usize, 1), try agent.local_candidate_count(stream_id, 1));

    const interfaces = [_]DiscoveryInterfaceAddress{
        .{ .address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 10 }, .port = 9000 } }, .local_preference = 5 },
    };
    const components = [_]u16{1};
    const gathered: AgentGatherSummary = try agent.gather_host_candidates(stream_id, &interfaces, &components, 1000, true);
    try std.testing.expectEqual(@as(usize, 1), gathered.generated);
}

test "stun header export is reachable" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    const header = StunHeader.init(0x0001, 0, tx_id);
    try std.testing.expectEqual(@as(u16, 0x0001), header.message_type);
}

test "stun attr header export is reachable" {
    const attr = StunAttrHeader.init(0x0006, 5);
    try std.testing.expectEqual(@as(u16, 0x0006), attr.attr_type);
}

test "stun parser export is reachable" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    var packet: [20]u8 = undefined;
    const header = StunHeader.init(0x0001, 0, tx_id);
    _ = try header.encode(&packet);

    const view = try parse_stun_message(&packet);
    try std.testing.expectEqual(@as(usize, 0), view.body.len);
}

test "stun builder export is reachable" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    var packet: [32]u8 = undefined;

    var builder = try StunMessageBuilder.init(&packet, 0x0001, tx_id);
    const bytes = try builder.finish();
    try std.testing.expectEqual(@as(usize, 20), bytes.len);
}

test "stun transaction exports are reachable" {
    var prng = std.Random.DefaultPrng.init(1234);
    const random = prng.random();

    const tx = stun_tx_from_rng(random);
    try std.testing.expect(stun_tx_equals(tx, tx));

    var store = StunTransactionStore.init(std.testing.allocator, StunRetryPolicy{});
    defer store.deinit();
    try store.start(tx, 0, 9);
    try std.testing.expectEqual(@as(usize, 1), store.count());

    var packet: [20]u8 = undefined;
    const response_header = StunHeader.init(0x0101, 0, tx);
    _ = try response_header.encode(&packet);
    const view = try parse_stun_message(&packet);
    const matched: StunMatchedResponse = try store.match_response(view, 10);
    try std.testing.expectEqual(StunMessageClass.success_response, matched.message_class);
    try std.testing.expect(stun_is_response_type(matched.message_type));
    try std.testing.expect(!stun_is_error_response_type(matched.message_type));
}

test "crypto exports are reachable" {
    const mac = hmac_sha1_compute("key", "message");
    try std.testing.expect(hmac_sha1_verify(mac, "key", "message"));

    const digest = md5_digest("message");
    try std.testing.expectEqual(@as(usize, 16), digest.len);
}

test "stun integrity exports are reachable" {
    const mac = stun_compute_message_integrity("payload", "key");
    try std.testing.expect(stun_verify_message_integrity(mac, "payload", "key"));

    const fp = stun_compute_fingerprint("payload");
    try std.testing.expect(fp != 0);
    try std.testing.expectEqual(@as(u16, 0x0008), stun_message_integrity_type);
    try std.testing.expectEqual(@as(u16, 0x8028), stun_fingerprint_type);

    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    var packet: [128]u8 = undefined;
    var builder = try StunMessageBuilder.init(&packet, 0x0001, tx_id);
    try builder.add_attr(0x0006, "user");
    try stun_add_message_integrity_attr(&builder, "secret");
    try stun_add_fingerprint_attr(&builder);

    const bytes = try builder.finish();
    const view = try parse_stun_message(bytes);
    try std.testing.expect(try stun_verify_embedded_message_integrity(view, "secret"));
    try std.testing.expect(try stun_verify_embedded_fingerprint(view));
}

test "stun bind usage exports are reachable" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    var packet: [256]u8 = undefined;

    const bytes = try stun_build_binding_request(&packet, tx_id, null, null);
    const view = try parse_stun_message(bytes);
    try std.testing.expect(stun_is_binding_request(view));
    try std.testing.expect(!stun_is_binding_response(view));

    const mapped: StunAddress = .{ .ipv4 = .{ .port = 3333, .ip = .{ 198, 51, 100, 44 } } };
    const response_bytes = try stun_build_binding_success_response(&packet, tx_id, .{
        .xor_mapped_address = mapped,
        .integrity_key = "bind-key",
        .include_fingerprint = true,
    });

    const response_view = try parse_stun_message(response_bytes);
    const parsed = try stun_parse_binding_response(response_view, "bind-key");
    try std.testing.expect(stun_is_binding_response(response_view));
    try std.testing.expectEqualDeep(mapped, parsed.xor_mapped_address.?);
}

test "stun ice usage exports are reachable" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    var packet: [256]u8 = undefined;

    const request_bytes = try stun_ice_build_connectivity_check_request(&packet, tx_id, .{
        .username = "local:remote",
        .priority = 1234,
        .role = .{ .role = .controlling, .tie_breaker = 42 },
        .use_candidate = true,
        .integrity_key = "pwd",
        .include_fingerprint = true,
    });

    const request_view = try parse_stun_message(request_bytes);
    const request_info = try stun_ice_parse_connectivity_check_request(request_view, "pwd");
    try std.testing.expect(stun_ice_is_connectivity_check_request(request_view));
    try std.testing.expect(request_info.use_candidate);

    const response_bytes = try stun_ice_build_connectivity_check_success_response(&packet, tx_id, .{
        .software = "libdice-check",
        .integrity_key = "pwd",
        .include_fingerprint = true,
    });

    const response_view = try parse_stun_message(response_bytes);
    try std.testing.expect(stun_ice_is_connectivity_check_success_response(response_view));
}

test "stun turn usage exports are reachable" {
    const tx_id = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    var packet: [128]u8 = undefined;

    const bytes = try stun_turn_build_allocate_request(&packet, tx_id, .{
        .lifetime_seconds = 300,
    });

    const view = try parse_stun_message(bytes);
    const lifetime = try stun_turn_read_lifetime_seconds(view);
    try std.testing.expectEqual(@as(u32, 300), lifetime.?);

    const transport = try stun_turn_read_requested_transport(view);
    try std.testing.expect(transport != null);
    try std.testing.expect(!stun_turn_is_allocate_success_response(view));
    try std.testing.expect(!stun_turn_is_allocate_error_response(view));
    try std.testing.expectEqual(@as(?u16, null), try stun_turn_read_error_code(view));

    const peer: StunAddress = .{ .ipv4 = .{ .port = 7777, .ip = .{ 203, 0, 113, 9 } } };
    const bind_bytes = try stun_turn_build_channel_bind_request(&packet, tx_id, .{
        .channel_number = 0x4002,
        .peer_address = peer,
    });
    const bind_view = try parse_stun_message(bind_bytes);
    try std.testing.expectEqual(@as(?u16, 0x4002), try stun_turn_read_channel_number(bind_view));

    const send_bytes = try stun_turn_build_send_indication(&packet, tx_id, .{
        .peer_address = peer,
        .data = "x",
    });
    const send_view = try parse_stun_message(send_bytes);
    try std.testing.expectEqualStrings("x", (try stun_turn_read_data_attr(send_view)).?);

    const peers = [_]StunAddress{peer};
    const perm_bytes = try stun_turn_build_create_permission_request(&packet, tx_id, .{
        .peer_addresses = &peers,
    });
    const perm_view = try parse_stun_message(perm_bytes);
    try std.testing.expectEqual(@as(usize, 1), try stun_turn_count_xor_peer_addresses(perm_view));
}

test "turn channel data exports are reachable" {
    var buf: [32]u8 = undefined;
    const frame = try turn_channel_encode_frame(&buf, 0x4001, "abc", true);
    const decoded: TurnChannelDataFrameView = try turn_channel_decode_frame(frame, true);
    try std.testing.expectEqual(@as(u16, 0x4001), decoded.channel_number);
    try std.testing.expectEqualStrings("abc", decoded.payload);
}
