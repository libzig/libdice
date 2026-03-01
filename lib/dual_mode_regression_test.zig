const std = @import("std");
const libfast = @import("libfast");

test "dual mode smoke test" {
    try std.testing.expectEqualStrings("ssh", libfast.mode_name(.ssh));
    try std.testing.expectEqualStrings("tls", libfast.mode_name(.tls));
}
