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

fn complete_authenticated_allocate(
    turn: *libdice.TurnUdpSocket,
    server: libdice.CandidateAddress,
    username: []const u8,
    password: []const u8,
    send_buf: []u8,
    recv_buf: []u8,
) !AuthAllocateResult {
    var tx = [_]u8{ 4, 4, 1, 0, 9, 2, 8, 2, 7, 2, 6, 2 };
    _ = try turn.send_allocate_request(send_buf, tx, .{});

    const start = std.time.milliTimestamp();
    var attempts: usize = 0;
    var key: ?libdice.Md5Digest = null;
    while (@as(u64, @intCast(std.time.milliTimestamp() - start)) < max_wait_ms and attempts < 8) : (attempts += 1) {
        const elapsed_ms: u64 = @intCast(std.time.milliTimestamp() - start);
        const response = (try wait_for_stun_packet(turn, recv_buf, 1_000)) orelse continue;

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
        const retry_packet = try libdice.stun_turn_build_allocate_request(send_buf, tx, .{
            .username = username,
            .realm = realm,
            .nonce = nonce,
            .integrity_key = derived_key[0..],
            .include_fingerprint = true,
        });

        _ = try turn.socket.send_to(server, retry_packet);
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
