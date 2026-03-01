const std = @import("std");

pub const ComponentState = enum {
    disconnected,
    gathering,
    connecting,
    connected,
    ready,
    failed,
};

pub const SelectedPair = struct {
    pair_id: u64,
    local_candidate_id: u64,
    remote_candidate_id: u64,
    nominated: bool,
};

pub const Component = struct {
    id: u16,
    state: ComponentState,
    selected_pair: ?SelectedPair,

    pub fn init(id: u16) Component {
        return .{
            .id = id,
            .state = .disconnected,
            .selected_pair = null,
        };
    }

    pub fn start_gathering(self: *Component) error{InvalidState}!void {
        if (self.state != .disconnected) return error.InvalidState;
        self.state = .gathering;
    }

    pub fn start_connecting(self: *Component) error{InvalidState}!void {
        switch (self.state) {
            .gathering, .disconnected => self.state = .connecting,
            else => return error.InvalidState,
        }
    }

    pub fn set_selected_pair(self: *Component, pair: SelectedPair) error{InvalidState}!void {
        switch (self.state) {
            .connecting, .connected, .ready => {},
            else => return error.InvalidState,
        }

        self.selected_pair = pair;
        if (pair.nominated) {
            self.state = .ready;
        } else {
            self.state = .connected;
        }
    }

    pub fn on_check_succeeded(self: *Component, pair_id: u64, local_candidate_id: u64, remote_candidate_id: u64, nominated: bool) error{InvalidState}!void {
        try self.set_selected_pair(.{
            .pair_id = pair_id,
            .local_candidate_id = local_candidate_id,
            .remote_candidate_id = remote_candidate_id,
            .nominated = nominated,
        });
    }

    pub fn mark_failed(self: *Component) void {
        self.state = .failed;
        self.selected_pair = null;
    }

    pub fn reset(self: *Component) void {
        self.state = .disconnected;
        self.selected_pair = null;
    }

    pub fn can_send_data(self: Component) bool {
        return self.state == .ready and self.selected_pair != null;
    }
};

test "component transitions to ready on nominated pair" {
    var component = Component.init(1);
    try component.start_gathering();
    try component.start_connecting();

    try component.on_check_succeeded(10, 100, 200, true);
    try std.testing.expectEqual(ComponentState.ready, component.state);
    try std.testing.expect(component.can_send_data());
}

test "component non-nominated pair is connected only" {
    var component = Component.init(1);
    try component.start_connecting();
    try component.on_check_succeeded(10, 100, 200, false);

    try std.testing.expectEqual(ComponentState.connected, component.state);
    try std.testing.expect(!component.can_send_data());
}

test "component invalid transition is rejected" {
    var component = Component.init(1);
    try std.testing.expectError(error.InvalidState, component.set_selected_pair(.{
        .pair_id = 1,
        .local_candidate_id = 1,
        .remote_candidate_id = 2,
        .nominated = true,
    }));
}

test "component failed and reset" {
    var component = Component.init(2);
    try component.start_connecting();
    try component.on_check_succeeded(12, 5, 6, true);
    component.mark_failed();

    try std.testing.expectEqual(ComponentState.failed, component.state);
    try std.testing.expectEqual(@as(?SelectedPair, null), component.selected_pair);

    component.reset();
    try std.testing.expectEqual(ComponentState.disconnected, component.state);
}
