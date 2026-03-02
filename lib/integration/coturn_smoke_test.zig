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

    const tx_challenge = [_]u8{ 1, 3, 3, 7, 5, 9, 1, 1, 2, 2, 3, 3 };
    var out: [512]u8 = undefined;
    var recv: [2048]u8 = undefined;

    var challenge: ?libdice.StunMessageView = null;
    var probe_count: usize = 0;
    while (probe_count < 5 and challenge == null) : (probe_count += 1) {
        _ = try turn.send_allocate_request(&out, tx_challenge, .{});
        challenge = try wait_for_stun_packet(&turn, &recv, 1_000);
    }

    const challenge_view = challenge orelse return error.Timeout;
    try std.testing.expect(libdice.stun_turn_is_allocate_error_response(challenge_view));

    const code = (try libdice.stun_turn_read_error_code(challenge_view)) orelse return error.ExpectedTurnErrorCode;
    try std.testing.expect(code == 401 or code == 438);

    const realm = (try libdice.stun_turn_read_realm(challenge_view)) orelse return error.ExpectedRealm;
    const nonce = (try libdice.stun_turn_read_nonce(challenge_view)) orelse return error.ExpectedNonce;
    const key = try derive_turn_long_term_key(username.value, realm, password.value);

    var tx_retry = [_]u8{ 4, 4, 1, 0, 9, 2, 8, 2, 7, 2, 6, 2 };
    var retry_packet = try libdice.stun_turn_build_allocate_request(&out, tx_retry, .{
        .username = username.value,
        .realm = realm,
        .nonce = nonce,
        .integrity_key = key[0..],
        .include_fingerprint = true,
    });

    const retry_view = try libdice.parse_stun_message(retry_packet);
    try std.testing.expect((try libdice.stun_turn_read_realm(retry_view)) != null);
    try std.testing.expect((try libdice.stun_turn_read_nonce(retry_view)) != null);
    try std.testing.expect(try libdice.stun_verify_embedded_message_integrity(retry_view, key[0..]));
    try std.testing.expect(try libdice.stun_verify_embedded_fingerprint(retry_view));

    _ = try turn.socket.send_to(server, retry_packet);

    const start = std.time.milliTimestamp();
    var retries: usize = 0;
    while (@as(u64, @intCast(std.time.milliTimestamp() - start)) < max_wait_ms and retries < 3) {
        const response = (try wait_for_stun_packet(&turn, &recv, 1_000)) orelse continue;
        if (libdice.stun_turn_is_allocate_success_response(response)) {
            try turn.on_allocate_success(response, 0, key[0..]);
            try std.testing.expect(turn.allocation != null);
            try std.testing.expect(turn.allocation.?.relayed_address != null);
            return;
        }

        if (!libdice.stun_turn_is_allocate_error_response(response)) continue;
        const response_code = (try libdice.stun_turn_read_error_code(response)) orelse continue;
        if (response_code != 401 and response_code != 438) return error.UnexpectedTurnErrorCode;

        const response_realm = (try libdice.stun_turn_read_realm(response)) orelse return error.ExpectedRealm;
        const response_nonce = (try libdice.stun_turn_read_nonce(response)) orelse return error.ExpectedNonce;
        const response_key = try derive_turn_long_term_key(username.value, response_realm, password.value);

        tx_retry[11] +%= 1;
        retry_packet = try libdice.stun_turn_build_allocate_request(&out, tx_retry, .{
            .username = username.value,
            .realm = response_realm,
            .nonce = response_nonce,
            .integrity_key = response_key[0..],
            .include_fingerprint = true,
        });
        _ = try turn.socket.send_to(server, retry_packet);
        retries += 1;
    }

    return error.Timeout;
}
