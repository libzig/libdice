const std = @import("std");
const pump_demo = @import("ice_pump_demo.zig");
const timeout_demo = @import("ice_timeout_demo.zig");
const drive_demo = @import("ice_drive_demo.zig");

fn print_usage(argv0: []const u8) void {
    std.debug.print("usage: {s} <pump|timeout|drive> [--summary]\n", .{argv0});
}

pub fn main() !void {
    var args = std.process.args();
    const argv0 = args.next() orelse "ice_demo_selector";
    const mode = args.next() orelse {
        print_usage(argv0);
        return error.InvalidArguments;
    };
    const maybe_flag = args.next();
    if (args.next() != null) {
        print_usage(argv0);
        return error.InvalidArguments;
    }

    const summary = if (maybe_flag) |flag|
        std.mem.eql(u8, flag, "--summary")
    else
        false;

    if (maybe_flag != null and !summary) {
        print_usage(argv0);
        return error.InvalidArguments;
    }

    if (std.mem.eql(u8, mode, "pump")) {
        if (summary) {
            try pump_demo.run_summary();
        } else {
            try pump_demo.run();
        }
        return;
    }

    if (std.mem.eql(u8, mode, "timeout")) {
        if (summary) {
            try timeout_demo.run_summary();
        } else {
            try timeout_demo.run();
        }
        return;
    }

    if (std.mem.eql(u8, mode, "drive")) {
        if (summary) {
            try drive_demo.run_summary();
        } else {
            try drive_demo.run();
        }
        return;
    }

    print_usage(argv0);
    return error.InvalidArguments;
}
