const std = @import("std");
const libdice = @import("libdice");
const api = libdice.StableApi;

pub fn run() !void {
    try run_with_summary(false);
}

pub fn run_summary() !void {
    try run_with_summary(true);
}

fn run_with_summary(summary: bool) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        _ = gpa.deinit();
    }
    const allocator = gpa.allocator();

    var left = api.AgentType.init(allocator);
    defer left.deinit();
    var right = api.AgentType.init(allocator);
    defer right.deinit();

    const left_stream_id = try left.add_stream(1);
    const right_stream_id = try right.add_stream(1);

    try left.get_stream(left_stream_id).?.set_local_credentials("leftuf", "leftpw");
    try right.get_stream(right_stream_id).?.set_local_credentials("rightuf", "rightpw");

    const left_addr: api.CandidateAddressType = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 230 }, .port = 5000 } };
    const right_addr: api.CandidateAddressType = .{ .ipv4 = .{ .ip = .{ 198, 51, 100, 230 }, .port = 6000 } };

    if (!(try left.add_local_candidate(left_stream_id, .{
        .id = 1,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = libdice.candidate_compute_foundation(.udp, .host, left_addr),
        .priority = libdice.candidate_compute_priority(.host, 100, 1),
        .address = left_addr,
    }))) return error.UnexpectedDuplicateCandidate;

    if (!(try right.add_local_candidate(right_stream_id, .{
        .id = 2,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = libdice.candidate_compute_foundation(.udp, .host, right_addr),
        .priority = libdice.candidate_compute_priority(.host, 100, 1),
        .address = right_addr,
    }))) return error.UnexpectedDuplicateCandidate;

    var left_desc = try api.build_local_description_fn(allocator, left.get_stream(left_stream_id).?, null);
    defer left_desc.deinit(allocator);
    var right_desc = try api.build_local_description_fn(allocator, right.get_stream(right_stream_id).?, null);
    defer right_desc.deinit(allocator);

    const apply_on_right = try api.apply_remote_description_fn(right.get_stream(right_stream_id).?, .{
        .credentials = left_desc.credentials,
        .candidates = left_desc.candidates,
    });
    const apply_on_left = try api.apply_remote_description_fn(left.get_stream(left_stream_id).?, .{
        .credentials = right_desc.credentials,
        .candidates = right_desc.candidates,
    });

    var left_runtime = api.RuntimeType.init(allocator, &left, .{}, .{}, .regular);
    defer left_runtime.deinit();
    var right_runtime = api.RuntimeType.init(allocator, &right, .{}, .{}, .regular);
    defer right_runtime.deinit();

    if (!(try left_runtime.attach_stream(left_stream_id))) return error.UnexpectedAttachFailure;
    if (!(try right_runtime.attach_stream(right_stream_id))) return error.UnexpectedAttachFailure;

    const pair_summary = try api.populate_checklists_both_fn(
        &left_runtime,
        left_stream_id,
        true,
        1_000,
        .{},
        &right_runtime,
        right_stream_id,
        false,
        2_000,
        .{},
    );

    const left_remote = left.get_stream(left_stream_id).?.remote_credentials orelse return error.MissingRemoteCredentials;
    const right_remote = right.get_stream(right_stream_id).?.remote_credentials orelse return error.MissingRemoteCredentials;

    if (summary) {
        std.debug.print(
            "demo=sdp api=StableApi left_added={d} right_added={d} left_pairs={d} right_pairs={d} left_remote_ufrag={s} right_remote_ufrag={s}\n",
            .{
                apply_on_left.candidates_added,
                apply_on_right.candidates_added,
                pair_summary.left.added,
                pair_summary.right.added,
                left_remote.ufrag(),
                right_remote.ufrag(),
            },
        );
        return;
    }

    std.debug.print(
        "api=StableApi applied remote candidates left={d} right={d}; populated pairs left={d} right={d}\n",
        .{ apply_on_left.candidates_added, apply_on_right.candidates_added, pair_summary.left.added, pair_summary.right.added },
    );
    std.debug.print(
        "left remote ufrag={s} right remote ufrag={s}\n",
        .{ left_remote.ufrag(), right_remote.ufrag() },
    );
}

pub fn main() !void {
    try run();
}
