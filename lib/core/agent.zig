const std = @import("std");
const stream_mod = @import("stream.zig");

pub const Agent = struct {
    allocator: std.mem.Allocator,
    streams: std.ArrayList(stream_mod.Stream),
    next_stream_id: u32,

    pub fn init(allocator: std.mem.Allocator) Agent {
        return .{
            .allocator = allocator,
            .streams = .empty,
            .next_stream_id = 1,
        };
    }

    pub fn deinit(self: *Agent) void {
        for (self.streams.items) |*stream| {
            stream.deinit();
        }
        self.streams.deinit(self.allocator);
    }

    pub fn stream_count(self: Agent) usize {
        return self.streams.items.len;
    }

    pub fn add_stream(self: *Agent, component_count: u16) !u32 {
        const stream_id = self.next_stream_id;
        self.next_stream_id += 1;

        var stream = stream_mod.Stream.init(self.allocator, stream_id);
        errdefer stream.deinit();

        var component_id: u16 = 1;
        while (component_id <= component_count) : (component_id += 1) {
            try stream.add_component(component_id);
        }

        try self.streams.append(self.allocator, stream);
        return stream_id;
    }

    pub fn get_stream(self: *Agent, stream_id: u32) ?*stream_mod.Stream {
        for (self.streams.items) |*stream| {
            if (stream.id == stream_id) return stream;
        }
        return null;
    }

    pub fn remove_stream(self: *Agent, stream_id: u32) bool {
        for (self.streams.items, 0..) |*stream, idx| {
            if (stream.id == stream_id) {
                stream.deinit();
                _ = self.streams.swapRemove(idx);
                return true;
            }
        }
        return false;
    }

    pub fn get_component(self: *Agent, stream_id: u32, component_id: u16) ?*stream_mod.component.Component {
        const stream = self.get_stream(stream_id) orelse return null;
        return stream.get_component(component_id);
    }

    pub fn set_remote_credentials(self: *Agent, stream_id: u32, ufrag: []const u8, password: []const u8) !void {
        const stream = self.get_stream(stream_id) orelse return error.NotFound;
        try stream.set_remote_credentials(ufrag, password);
    }
};

test "agent manages stream lifecycle" {
    var agent = Agent.init(std.testing.allocator);
    defer agent.deinit();

    const s1 = try agent.add_stream(2);
    const s2 = try agent.add_stream(1);
    try std.testing.expectEqual(@as(usize, 2), agent.stream_count());

    const stream_1 = agent.get_stream(s1).?;
    try std.testing.expectEqual(@as(usize, 2), stream_1.component_count());

    try std.testing.expect(agent.remove_stream(s2));
    try std.testing.expectEqual(@as(usize, 1), agent.stream_count());
    try std.testing.expect(!agent.remove_stream(999));
}

test "agent component and credential access" {
    var agent = Agent.init(std.testing.allocator);
    defer agent.deinit();

    const stream_id = try agent.add_stream(2);
    const component = agent.get_component(stream_id, 2).?;
    try std.testing.expectEqual(@as(u16, 2), component.id);

    try agent.set_remote_credentials(stream_id, "ru", "rp");
    const stream = agent.get_stream(stream_id).?;
    try std.testing.expectEqualStrings("ru", (&stream.remote_credentials.?).ufrag());
    try std.testing.expectError(error.NotFound, agent.set_remote_credentials(404, "u", "p"));
}
