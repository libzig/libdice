const std = @import("std");

pub const TransportMode = enum {
    ssh,
    tls,
};

pub fn mode_name(mode: TransportMode) []const u8 {
    return switch (mode) {
        .ssh => "ssh",
        .tls => "tls",
    };
}

pub fn build_banner(mode: TransportMode) []const u8 {
    return switch (mode) {
        .ssh => "libfast: ssh path available",
        .tls => "libfast: tls path available",
    };
}

test "mode_name returns expected string" {
    try std.testing.expectEqualStrings("ssh", mode_name(.ssh));
    try std.testing.expectEqualStrings("tls", mode_name(.tls));
}

test "build_banner returns expected string" {
    try std.testing.expectEqualStrings("libfast: ssh path available", build_banner(.ssh));
    try std.testing.expectEqualStrings("libfast: tls path available", build_banner(.tls));
}
