const std = @import("std");
const libdice = @import("libdice");

pub fn run() !void {
    try run_with_summary(false);
}

pub fn run_summary() !void {
    try run_with_summary(true);
}

fn run_with_summary(summary: bool) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var agent = libdice.Agent.init(allocator);
    defer agent.deinit();

    const stream_id = try agent.add_stream(1);
    try agent.get_stream(stream_id).?.set_local_credentials("simple-ufrag", "simple-pass");

    const addr: libdice.CandidateAddress = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 200 }, .port = 5000 } };
    const added = try agent.add_local_candidate(stream_id, .{
        .id = 1,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = libdice.candidate_compute_foundation(.udp, .host, addr),
        .priority = libdice.candidate_compute_priority(.host, 100, 1),
        .address = addr,
    });
    if (!added) return error.UnexpectedDuplicateCandidate;

    const local_count = try agent.local_candidate_count(stream_id, 1);
    const creds = agent.get_stream(stream_id).?.local_credentials orelse return error.MissingLocalCredentials;

    if (summary) {
        std.debug.print("demo=simple stream={d} local_candidates={d} ufrag={s}\n", .{ stream_id, local_count, (&creds).ufrag() });
        return;
    }

    std.debug.print("simple example created stream {d}\n", .{stream_id});
    std.debug.print("component 1 local candidates: {d}\n", .{local_count});
    std.debug.print("local ufrag: {s}\n", .{(&creds).ufrag()});
}

pub fn main() !void {
    try run();
}
