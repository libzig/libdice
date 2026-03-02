const candidate = @import("candidate.zig");

pub const TcpRoleAction = struct {
    initiate_connect: bool,
    accept_incoming: bool,
};

pub const IceTcpError = error{
    MissingTcpRole,
    IncompatibleRoles,
};

pub fn action_for_local_role(local_role: candidate.TcpRole) TcpRoleAction {
    return switch (local_role) {
        .active => .{ .initiate_connect = true, .accept_incoming = false },
        .passive => .{ .initiate_connect = false, .accept_incoming = true },
        .sim_open => .{ .initiate_connect = true, .accept_incoming = true },
    };
}

pub fn action_for_pair(local_role: ?candidate.TcpRole, remote_role: ?candidate.TcpRole) IceTcpError!TcpRoleAction {
    if (local_role == null or remote_role == null) return error.MissingTcpRole;
    if (!candidate.tcp_roles_compatible(local_role, remote_role)) return error.IncompatibleRoles;
    return action_for_local_role(local_role.?);
}

test "ice tcp role action mapping" {
    const active = action_for_local_role(.active);
    try @import("std").testing.expect(active.initiate_connect);
    try @import("std").testing.expect(!active.accept_incoming);

    const passive = action_for_local_role(.passive);
    try @import("std").testing.expect(!passive.initiate_connect);
    try @import("std").testing.expect(passive.accept_incoming);

    const sim = action_for_local_role(.sim_open);
    try @import("std").testing.expect(sim.initiate_connect);
    try @import("std").testing.expect(sim.accept_incoming);
}

test "ice tcp pair action validates compatibility" {
    const ok = try action_for_pair(.active, .passive);
    try @import("std").testing.expect(ok.initiate_connect);

    try @import("std").testing.expectError(error.MissingTcpRole, action_for_pair(.active, null));
    try @import("std").testing.expectError(error.IncompatibleRoles, action_for_pair(.active, .active));
}

test "libnice parity: test-icetcp" {
    const a = try action_for_pair(.active, .passive);
    try @import("std").testing.expect(a.initiate_connect);
    const b = try action_for_pair(.passive, .active);
    try @import("std").testing.expect(b.accept_incoming);
}
