const std = @import("std");
const libfast = @import("libfast");

pub fn main() !void {
    std.debug.print("{s}\n", .{libfast.build_banner(.tls)});
}
