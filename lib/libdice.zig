const std = @import("std");

pub const EventLoop = @import("core/events.zig").EventLoop;
pub const EventTask = @import("core/events.zig").Task;
pub const FeatureFlags = @import("core/feature_flags.zig").FeatureFlags;

pub const version = "0.0.1";

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
