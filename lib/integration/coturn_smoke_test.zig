const std = @import("std");
const libdice = @import("libdice");

const max_wait_ms: u64 = 10_000;
const poll_sleep_ms: u64 = 20;

const EnvValue = struct {
    value: []const u8,
    owned: ?[]u8,

    fn deinit(self: EnvValue) void {
        if (self.owned) |buf| std.testing.allocator.free(buf);
    }
};

fn env_or_default(name: []const u8, default_value: []const u8) EnvValue {
    const maybe_value = std.process.getEnvVarOwned(std.testing.allocator, name) catch null;
    if (maybe_value) |value| {
        return .{ .value = value, .owned = value };
    }
    return .{ .value = default_value, .owned = null };
}

fn wait_for_stun_packet(turn: *libdice.TurnUdpSocket, recv_buf: []u8, timeout_ms: u64) !?libdice.StunMessageView {
    const start = std.time.milliTimestamp();
    while (@as(u64, @intCast(std.time.milliTimestamp() - start)) < timeout_ms) {
        const packet = try turn.recv_from_server(recv_buf) orelse {
            std.Thread.sleep(poll_sleep_ms * std.time.ns_per_ms);
            continue;
        };

        switch (packet) {
            .stun => |view| return view,
            else => continue,
        }
    }

    return null;
}

fn derive_turn_long_term_key(username: []const u8, realm: []const u8, password: []const u8) !libdice.Md5Digest {
    var key_material_buf: [512]u8 = undefined;
    const key_material = try std.fmt.bufPrint(&key_material_buf, "{s}:{s}:{s}", .{ username, realm, password });
    return libdice.md5_digest(key_material);
}

const AuthAllocateResult = struct {
    key: libdice.Md5Digest,
};

fn handle_auth_challenge(
    turn: *libdice.TurnUdpSocket,
    username: []const u8,
    password: []const u8,
) !libdice.Md5Digest {
    const realm = turn.auth_realm_value() orelse return error.ExpectedRealm;
    _ = turn.auth_nonce_value() orelse return error.ExpectedNonce;
    return derive_turn_long_term_key(username, realm, password);
}

fn complete_authenticated_allocate(
    turn: *libdice.TurnUdpSocket,
    server: libdice.CandidateAddress,
    username: []const u8,
    password: []const u8,
    send_buf: []u8,
    recv_buf: []u8,
) !AuthAllocateResult {
    var tx = [_]u8{ 4, 4, 1, 0, 9, 2, 8, 2, 7, 2, 6, 2 };
    var current_packet = try libdice.stun_turn_build_allocate_request(send_buf, tx, .{});
    _ = try turn.socket.send_to(server, current_packet);

    const start = std.time.milliTimestamp();
    var attempts: usize = 0;
    var key: ?libdice.Md5Digest = null;
    while (@as(u64, @intCast(std.time.milliTimestamp() - start)) < max_wait_ms and attempts < 12) : (attempts += 1) {
        const elapsed_ms: u64 = @intCast(std.time.milliTimestamp() - start);
        const response = (try wait_for_stun_packet(turn, recv_buf, 800)) orelse {
            _ = try turn.socket.send_to(server, current_packet);
            continue;
        };

        if (libdice.stun_turn_is_allocate_success_response(response)) {
            const auth_key = key orelse return error.ExpectedAuthKey;
            try turn.on_allocate_success(response, elapsed_ms, auth_key[0..]);
            try std.testing.expect(turn.allocation != null);
            try std.testing.expect(turn.allocation.?.relayed_address != null);
            return .{ .key = auth_key };
        }

        if (!libdice.stun_turn_is_allocate_error_response(response)) continue;
        const outcome = try turn.on_server_stun(response, elapsed_ms, null);
        if (outcome != .auth_challenge_required) {
            return error.UnexpectedTurnErrorCode;
        }

        const realm = turn.auth_realm_value() orelse return error.ExpectedRealm;
        const nonce = turn.auth_nonce_value() orelse return error.ExpectedNonce;
        const derived_key = try derive_turn_long_term_key(username, realm, password);
        key = derived_key;

        tx[11] +%= 1;
        current_packet = try libdice.stun_turn_build_allocate_request(send_buf, tx, .{
            .username = username,
            .realm = realm,
            .nonce = nonce,
            .integrity_key = derived_key[0..],
            .include_fingerprint = true,
        });

        _ = try turn.socket.send_to(server, current_packet);
    }

    return error.Timeout;
}

fn complete_authenticated_permission(
    turn: *libdice.TurnUdpSocket,
    username: []const u8,
    password: []const u8,
    key: *libdice.Md5Digest,
    peer_candidate: libdice.CandidateAddress,
    peer_stun: libdice.StunAddress,
    send_buf: []u8,
    recv_buf: []u8,
) !void {
    var tx = [_]u8{ 2, 1, 0, 0, 8, 8, 1, 1, 7, 7, 3, 3 };
    const peer_list = [_]libdice.StunAddress{peer_stun};

    try turn.note_permission_refresh_request(tx, peer_candidate, libdice.TurnUdpSocket.permission_default_lifetime_seconds);
    _ = try turn.send_create_permission_request(send_buf, tx, .{
        .peer_addresses = &peer_list,
        .username = username,
        .realm = turn.auth_realm_value(),
        .nonce = turn.auth_nonce_value(),
        .integrity_key = key[0..],
        .include_fingerprint = true,
    });

    const start = std.time.milliTimestamp();
    var attempts: usize = 0;
    while (@as(u64, @intCast(std.time.milliTimestamp() - start)) < max_wait_ms and attempts < 5) : (attempts += 1) {
        const elapsed_ms: u64 = @intCast(std.time.milliTimestamp() - start);
        const response = (try wait_for_stun_packet(turn, recv_buf, 1_000)) orelse continue;

        if (response.header.message_type == 0x0108) {
            const outcome = try turn.on_server_stun(response, elapsed_ms, key[0..]);
            try std.testing.expectEqual(libdice.TurnUdpSocket.ServerStunOutcome.handled, outcome);
            try std.testing.expectEqual(@as(usize, 1), turn.permission_count());
            return;
        }

        if (!libdice.stun_is_error_response_type(response.header.message_type)) continue;
        const outcome = try turn.on_server_stun(response, elapsed_ms, null);
        if (outcome != .auth_challenge_required) return error.UnexpectedTurnErrorCode;

        key.* = try handle_auth_challenge(turn, username, password);
        tx[11] +%= 1;
        try turn.note_permission_refresh_request(tx, peer_candidate, libdice.TurnUdpSocket.permission_default_lifetime_seconds);
        _ = try turn.send_create_permission_request(send_buf, tx, .{
            .peer_addresses = &peer_list,
            .username = username,
            .realm = turn.auth_realm_value(),
            .nonce = turn.auth_nonce_value(),
            .integrity_key = key[0..],
            .include_fingerprint = true,
        });
    }

    return error.Timeout;
}

fn complete_authenticated_channel_bind(
    turn: *libdice.TurnUdpSocket,
    username: []const u8,
    password: []const u8,
    key: *libdice.Md5Digest,
    channel_number: u16,
    peer_candidate: libdice.CandidateAddress,
    peer_stun: libdice.StunAddress,
    send_buf: []u8,
    recv_buf: []u8,
) !void {
    var tx = [_]u8{ 3, 9, 1, 1, 6, 6, 2, 2, 5, 5, 4, 4 };

    try turn.note_channel_refresh_request(tx, channel_number, peer_candidate, libdice.TurnUdpSocket.channel_default_lifetime_seconds);
    _ = try turn.send_channel_bind_request(send_buf, tx, .{
        .channel_number = channel_number,
        .peer_address = peer_stun,
        .username = username,
        .realm = turn.auth_realm_value(),
        .nonce = turn.auth_nonce_value(),
        .integrity_key = key[0..],
        .include_fingerprint = true,
    });

    const start = std.time.milliTimestamp();
    var attempts: usize = 0;
    while (@as(u64, @intCast(std.time.milliTimestamp() - start)) < max_wait_ms and attempts < 5) : (attempts += 1) {
        const elapsed_ms: u64 = @intCast(std.time.milliTimestamp() - start);
        const response = (try wait_for_stun_packet(turn, recv_buf, 1_000)) orelse continue;

        if (response.header.message_type == 0x0109) {
            const outcome = try turn.on_server_stun(response, elapsed_ms, key[0..]);
            try std.testing.expectEqual(libdice.TurnUdpSocket.ServerStunOutcome.handled, outcome);
            try std.testing.expectEqual(@as(usize, 1), turn.channel_binding_count());
            return;
        }

        if (!libdice.stun_is_error_response_type(response.header.message_type)) continue;
        const outcome = try turn.on_server_stun(response, elapsed_ms, null);
        if (outcome != .auth_challenge_required) return error.UnexpectedTurnErrorCode;

        key.* = try handle_auth_challenge(turn, username, password);
        tx[11] +%= 1;
        try turn.note_channel_refresh_request(tx, channel_number, peer_candidate, libdice.TurnUdpSocket.channel_default_lifetime_seconds);
        _ = try turn.send_channel_bind_request(send_buf, tx, .{
            .channel_number = channel_number,
            .peer_address = peer_stun,
            .username = username,
            .realm = turn.auth_realm_value(),
            .nonce = turn.auth_nonce_value(),
            .integrity_key = key[0..],
            .include_fingerprint = true,
        });
    }

    return error.Timeout;
}

test "coturn allocate challenge-retry succeeds with long-term credentials" {
    const server_text = env_or_default("COTURN_SERVER", "127.0.0.1:3478");
    defer server_text.deinit();
    const username = env_or_default("COTURN_USERNAME", "test");
    defer username.deinit();
    const password = env_or_default("COTURN_PASSWORD", "testpass");
    defer password.deinit();

    const server = try libdice.net_parse_ip_port(server_text.value);
    var turn = try libdice.TurnUdpSocket.init_nonblocking(
        std.testing.allocator,
        .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } },
        server,
    );
    defer turn.deinit();

    var out: [512]u8 = undefined;
    var recv: [2048]u8 = undefined;

    _ = try complete_authenticated_allocate(&turn, server, username.value, password.value, &out, &recv);
}

test "coturn refresh succeeds after authenticated allocate" {
    const server_text = env_or_default("COTURN_SERVER", "127.0.0.1:3478");
    defer server_text.deinit();
    const username = env_or_default("COTURN_USERNAME", "test");
    defer username.deinit();
    const password = env_or_default("COTURN_PASSWORD", "testpass");
    defer password.deinit();

    const server = try libdice.net_parse_ip_port(server_text.value);
    var turn = try libdice.TurnUdpSocket.init_nonblocking(
        std.testing.allocator,
        .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } },
        server,
    );
    defer turn.deinit();

    var out: [512]u8 = undefined;
    var recv: [2048]u8 = undefined;
    var auth = try complete_authenticated_allocate(&turn, server, username.value, password.value, &out, &recv);

    var tx_refresh = [_]u8{ 9, 7, 7, 0, 2, 2, 9, 9, 4, 4, 8, 8 };
    _ = try turn.send_refresh_request(&out, tx_refresh, .{
        .lifetime_seconds = 300,
        .username = username.value,
        .realm = turn.auth_realm_value(),
        .nonce = turn.auth_nonce_value(),
        .integrity_key = auth.key[0..],
        .include_fingerprint = true,
    });

    const start = std.time.milliTimestamp();
    var retries: usize = 0;
    while (@as(u64, @intCast(std.time.milliTimestamp() - start)) < max_wait_ms and retries < 4) {
        const elapsed_ms: u64 = @intCast(std.time.milliTimestamp() - start);
        const response = (try wait_for_stun_packet(&turn, &recv, 1_000)) orelse continue;

        if (libdice.stun_turn_parse_refresh_success_response(response, auth.key[0..])) |_| {
            try turn.on_refresh_success(response, elapsed_ms, auth.key[0..]);
            try std.testing.expect(turn.allocation != null);
            try std.testing.expect(turn.allocation.?.lifetime_seconds == 300 or turn.allocation.?.lifetime_seconds > 0);
            return;
        } else |err| switch (err) {
            error.NotRefreshSuccessResponse => {},
            else => return err,
        }

        if (!libdice.stun_is_error_response_type(response.header.message_type)) continue;
        const outcome = try turn.on_server_stun(response, elapsed_ms, null);
        if (outcome != .auth_challenge_required) return error.UnexpectedTurnErrorCode;

        const realm = turn.auth_realm_value() orelse return error.ExpectedRealm;
        const nonce = turn.auth_nonce_value() orelse return error.ExpectedNonce;
        auth.key = try derive_turn_long_term_key(username.value, realm, password.value);

        tx_refresh[11] +%= 1;
        _ = try turn.send_refresh_request(&out, tx_refresh, .{
            .lifetime_seconds = 300,
            .username = username.value,
            .realm = realm,
            .nonce = nonce,
            .integrity_key = auth.key[0..],
            .include_fingerprint = true,
        });
        retries += 1;
    }

    return error.Timeout;
}

test "coturn permission and channel bind succeed after authenticated allocate" {
    const server_text = env_or_default("COTURN_SERVER", "127.0.0.1:3478");
    defer server_text.deinit();
    const username = env_or_default("COTURN_USERNAME", "test");
    defer username.deinit();
    const password = env_or_default("COTURN_PASSWORD", "testpass");
    defer password.deinit();

    const server = try libdice.net_parse_ip_port(server_text.value);
    var turn = try libdice.TurnUdpSocket.init_nonblocking(
        std.testing.allocator,
        .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } },
        server,
    );
    defer turn.deinit();

    var out: [1024]u8 = undefined;
    var recv: [2048]u8 = undefined;
    var auth = try complete_authenticated_allocate(&turn, server, username.value, password.value, &out, &recv);

    const peer_candidate: libdice.CandidateAddress = .{ .ipv4 = .{ .ip = .{ 203, 0, 113, 33 }, .port = 5000 } };
    const peer_stun: libdice.StunAddress = .{ .ipv4 = .{ .ip = .{ 203, 0, 113, 33 }, .port = 5000 } };

    try complete_authenticated_permission(&turn, username.value, password.value, &auth.key, peer_candidate, peer_stun, &out, &recv);
    try complete_authenticated_channel_bind(&turn, username.value, password.value, &auth.key, 0x4001, peer_candidate, peer_stun, &out, &recv);
}
