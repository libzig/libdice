const std = @import("std");
pub const component = @import("component.zig");

pub const max_ufrag_len: usize = 32;
pub const max_password_len: usize = 256;

pub const Credentials = struct {
    ufrag_buf: [max_ufrag_len]u8,
    ufrag_len: u8,
    password_buf: [max_password_len]u8,
    password_len: u16,

    pub fn from_slices(ufrag_in: []const u8, password_in: []const u8) error{CredentialTooLong}!Credentials {
        if (ufrag_in.len > max_ufrag_len or password_in.len > max_password_len) return error.CredentialTooLong;

        var creds = Credentials{
            .ufrag_buf = [_]u8{0} ** max_ufrag_len,
            .ufrag_len = @intCast(ufrag_in.len),
            .password_buf = [_]u8{0} ** max_password_len,
            .password_len = @intCast(password_in.len),
        };

        @memcpy(creds.ufrag_buf[0..ufrag_in.len], ufrag_in);
        @memcpy(creds.password_buf[0..password_in.len], password_in);
        return creds;
    }

    pub fn ufrag(self: *const Credentials) []const u8 {
        return self.ufrag_buf[0..self.ufrag_len];
    }

    pub fn password(self: *const Credentials) []const u8 {
        return self.password_buf[0..self.password_len];
    }
};

pub const Stream = struct {
    allocator: std.mem.Allocator,
    id: u32,
    components: std.ArrayList(component.Component),
    local_credentials: ?Credentials,
    remote_credentials: ?Credentials,

    pub fn init(allocator: std.mem.Allocator, id: u32) Stream {
        return .{
            .allocator = allocator,
            .id = id,
            .components = .empty,
            .local_credentials = null,
            .remote_credentials = null,
        };
    }

    pub fn deinit(self: *Stream) void {
        self.components.deinit(self.allocator);
    }

    pub fn add_component(self: *Stream, component_id: u16) !void {
        try self.components.append(self.allocator, component.Component.init(component_id));
    }

    pub fn get_component(self: *Stream, component_id: u16) ?*component.Component {
        for (self.components.items) |*item| {
            if (item.id == component_id) return item;
        }
        return null;
    }

    pub fn component_count(self: Stream) usize {
        return self.components.items.len;
    }

    pub fn set_local_credentials(self: *Stream, ufrag: []const u8, password: []const u8) !void {
        self.local_credentials = try Credentials.from_slices(ufrag, password);
    }

    pub fn set_remote_credentials(self: *Stream, ufrag: []const u8, password: []const u8) !void {
        self.remote_credentials = try Credentials.from_slices(ufrag, password);
    }
};

test "stream manages components" {
    var stream = Stream.init(std.testing.allocator, 5);
    defer stream.deinit();

    try stream.add_component(1);
    try stream.add_component(2);
    try std.testing.expectEqual(@as(usize, 2), stream.component_count());

    const c1 = stream.get_component(1).?;
    try std.testing.expectEqual(@as(u16, 1), c1.id);
    try std.testing.expectEqual(@as(?*component.Component, null), stream.get_component(3));
}

test "stream credentials storage" {
    var stream = Stream.init(std.testing.allocator, 1);
    defer stream.deinit();

    try stream.set_local_credentials("local_u", "local_password");
    try stream.set_remote_credentials("remote_u", "remote_password");

    try std.testing.expectEqualStrings("local_u", (&stream.local_credentials.?).ufrag());
    try std.testing.expectEqualStrings("remote_password", (&stream.remote_credentials.?).password());
}

test "credential length validation" {
    var oversized_ufrag: [33]u8 = undefined;
    @memset(&oversized_ufrag, 'u');
    try std.testing.expectError(error.CredentialTooLong, Credentials.from_slices(&oversized_ufrag, "ok"));
}
