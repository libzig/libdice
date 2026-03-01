const std = @import("std");
const libdice = @import("libdice");

pub fn main() !void {
    std.debug.print("{s}\n", .{libdice.build_banner()});
}
