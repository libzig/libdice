const std = @import("std");
const libdice = @import("libdice");

test "dual mode smoke test" {
    try std.testing.expectEqualStrings("libdice: bootstrap build is healthy", libdice.build_banner());
}
