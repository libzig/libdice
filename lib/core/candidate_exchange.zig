const std = @import("std");
const stream_mod = @import("stream.zig");
const candidate = @import("candidate.zig");
const net_address = @import("../net/address.zig");

pub const CandidateExchangeError = std.mem.Allocator.Error || std.fmt.ParseIntError || error{
    NoSpaceLeft,
    InvalidFormat,
    MissingField,
    UnknownTransport,
    UnknownCandidateType,
    UnknownTcpRole,
    UnsupportedAddressFamily,
    InvalidAddress,
    InvalidPort,
    CredentialTooLong,
};

pub const ParsedDescription = struct {
    credentials: ?stream_mod.Credentials,
    candidates: []candidate.Candidate,

    pub fn deinit(self: *ParsedDescription, allocator: std.mem.Allocator) void {
        allocator.free(self.candidates);
        self.candidates = &[_]candidate.Candidate{};
    }
};

pub fn encode_candidate_line(buffer: []u8, value: candidate.Candidate) CandidateExchangeError![]const u8 {
    var stream = std.io.fixedBufferStream(buffer);
    const writer = stream.writer();

    const transport = switch (value.transport) {
        .udp => "udp",
        .tcp => "tcp",
    };
    const cand_type = switch (value.candidate_type) {
        .host => "host",
        .srflx => "srflx",
        .relay => "relay",
        .prflx => "prflx",
    };

    switch (value.address) {
        .ipv4 => |v4| {
            try writer.print(
                "cand id={d} comp={d} transport={s} type={s} prio={d} foundation={d} addr={d}.{d}.{d}.{d}:{d}",
                .{ value.id, value.component_id, transport, cand_type, value.priority, value.foundation, v4.ip[0], v4.ip[1], v4.ip[2], v4.ip[3], v4.port },
            );
        },
        .ipv6 => |v6| {
            const std_addr = std.net.Address.initIp6(v6.ip, v6.port, 0, 0);
            try writer.print(
                "cand id={d} comp={d} transport={s} type={s} prio={d} foundation={d} addr={f}",
                .{ value.id, value.component_id, transport, cand_type, value.priority, value.foundation, std_addr },
            );
        },
    }

    if (value.tcp_role) |role| {
        const role_text = switch (role) {
            .active => "active",
            .passive => "passive",
            .sim_open => "sim_open",
        };
        try writer.print(" tcprole={s}", .{role_text});
    }

    return stream.getWritten();
}

pub fn parse_candidate_line(line: []const u8) CandidateExchangeError!candidate.Candidate {
    var id: ?u64 = null;
    var component_id: ?u16 = null;
    var transport: ?candidate.Transport = null;
    var cand_type: ?candidate.CandidateType = null;
    var priority: ?u32 = null;
    var foundation: ?u32 = null;
    var address: ?candidate.Address = null;
    var tcp_role: ?candidate.TcpRole = null;

    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const tag = it.next() orelse return error.InvalidFormat;
    if (!std.mem.eql(u8, tag, "cand")) return error.InvalidFormat;

    while (it.next()) |token| {
        const sep = std.mem.indexOfScalar(u8, token, '=') orelse return error.InvalidFormat;
        const key = token[0..sep];
        const value = token[sep + 1 ..];

        if (std.mem.eql(u8, key, "id")) {
            id = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, key, "comp")) {
            component_id = try std.fmt.parseInt(u16, value, 10);
        } else if (std.mem.eql(u8, key, "transport")) {
            if (std.mem.eql(u8, value, "udp")) transport = .udp else if (std.mem.eql(u8, value, "tcp")) transport = .tcp else return error.UnknownTransport;
        } else if (std.mem.eql(u8, key, "type")) {
            if (std.mem.eql(u8, value, "host")) cand_type = .host else if (std.mem.eql(u8, value, "srflx")) cand_type = .srflx else if (std.mem.eql(u8, value, "relay")) cand_type = .relay else if (std.mem.eql(u8, value, "prflx")) cand_type = .prflx else return error.UnknownCandidateType;
        } else if (std.mem.eql(u8, key, "prio")) {
            priority = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, key, "foundation")) {
            foundation = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, key, "addr")) {
            address = try net_address.parse_ip_port(value);
        } else if (std.mem.eql(u8, key, "tcprole")) {
            if (std.mem.eql(u8, value, "active")) tcp_role = .active else if (std.mem.eql(u8, value, "passive")) tcp_role = .passive else if (std.mem.eql(u8, value, "sim_open")) tcp_role = .sim_open else return error.UnknownTcpRole;
        }
    }

    return .{
        .id = id orelse return error.MissingField,
        .component_id = component_id orelse return error.MissingField,
        .candidate_type = cand_type orelse return error.MissingField,
        .transport = transport orelse return error.MissingField,
        .foundation = foundation orelse return error.MissingField,
        .priority = priority orelse return error.MissingField,
        .address = address orelse return error.MissingField,
        .tcp_role = tcp_role,
    };
}

pub fn encode_description(
    allocator: std.mem.Allocator,
    credentials: ?stream_mod.Credentials,
    candidates: []const candidate.Candidate,
) CandidateExchangeError![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    if (credentials) |creds| {
        try out.writer(allocator).print("ufrag={s}\n", .{creds.ufrag()});
        try out.writer(allocator).print("pwd={s}\n", .{creds.password()});
    }

    for (candidates) |item| {
        var line_buf: [512]u8 = undefined;
        const line = try encode_candidate_line(&line_buf, item);
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }

    return out.toOwnedSlice(allocator);
}

pub fn parse_description(allocator: std.mem.Allocator, text: []const u8) CandidateExchangeError!ParsedDescription {
    var parsed = ParsedDescription{
        .credentials = null,
        .candidates = &[_]candidate.Candidate{},
    };

    var list = std.ArrayList(candidate.Candidate).empty;
    errdefer list.deinit(allocator);

    var ufrag: ?[]const u8 = null;
    var pwd: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "ufrag=")) {
            ufrag = line[6..];
            continue;
        }
        if (std.mem.startsWith(u8, line, "pwd=")) {
            pwd = line[4..];
            continue;
        }

        const cand = try parse_candidate_line(line);
        try list.append(allocator, cand);
    }

    if (ufrag != null and pwd != null) {
        parsed.credentials = try stream_mod.Credentials.from_slices(ufrag.?, pwd.?);
    }

    parsed.candidates = try list.toOwnedSlice(allocator);
    return parsed;
}

test "candidate exchange candidate line roundtrip" {
    const item = candidate.Candidate{
        .id = 42,
        .component_id = 1,
        .candidate_type = .relay,
        .transport = .tcp,
        .foundation = 1234,
        .priority = 5678,
        .address = .{ .ipv4 = .{ .ip = .{ 203, 0, 113, 44 }, .port = 7000 } },
        .tcp_role = .active,
    };

    var buf: [512]u8 = undefined;
    const line = try encode_candidate_line(&buf, item);
    const parsed = try parse_candidate_line(line);
    try std.testing.expectEqualDeep(item, parsed);
}

test "candidate exchange description roundtrip" {
    const creds = try stream_mod.Credentials.from_slices("ufragA", "pwdA");
    const items = [_]candidate.Candidate{
        .{
            .id = 1,
            .component_id = 1,
            .candidate_type = .host,
            .transport = .udp,
            .foundation = 11,
            .priority = 22,
            .address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 50 }, .port = 5000 } },
        },
        .{
            .id = 2,
            .component_id = 1,
            .candidate_type = .host,
            .transport = .tcp,
            .foundation = 12,
            .priority = 23,
            .address = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 51 }, .port = 5001 } },
            .tcp_role = .passive,
        },
    };

    const text = try encode_description(std.testing.allocator, creds, &items);
    defer std.testing.allocator.free(text);

    var parsed = try parse_description(std.testing.allocator, text);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expect(parsed.credentials != null);
    try std.testing.expectEqualStrings("ufragA", parsed.credentials.?.ufrag());
    try std.testing.expectEqual(@as(usize, 2), parsed.candidates.len);
    try std.testing.expectEqual(candidate.TcpRole.passive, parsed.candidates[1].tcp_role.?);
}
