# libdice Documentation

This is the single documentation file for `libdice`.

It is focused on practical usage:
- what the library does
- architecture and runtime model
- when to use each API
- examples you can run now
- testing and troubleshooting

## 1) What libdice is

`libdice` is a Zig ICE/TURN library with explicit control over transport and state progression.

Main capabilities:
- ICE candidate/checklist/runtime flow
- TURN UDP and TURN TCP control/data paths
- consent freshness and failure transitions
- real-server integration against coturn

`libdice` is not a complete WebRTC stack. It does not replace browser SDP/media/session layers.

## 2) Use cases

Good fit:
- building a custom real-time transport pipeline in Zig
- server-side ICE/TURN agents
- tooling/tests where deterministic network state transitions matter
- low-level TURN behavior work (auth, refresh, permission, channel)

Not a good fit by itself:
- drop-in browser-like WebRTC API compatibility
- full media pipeline orchestration

## 3) Architecture overview

`libdice` is intentionally layered.

### 3.1 Core state layer (`lib/core`)

- `Agent`
  - stream/component ownership
  - local/remote candidate inventory
  - credentials and signaling data
- `IceRuntime`
  - checklist progression
  - transaction tracking
  - nomination and consent state

Think of core as protocol state + decision logic.

### 3.2 Network execution layer (`lib/net`)

- `IceUdpRuntimeBridge`
  - binds sockets
  - sends checks/retransmits/consent probes
  - receives packets and feeds runtime
  - runs TURN maintenance
- UDP/TCP socket wrappers
- TURN UDP/TCP wrappers

Think of net as I/O execution against real sockets.

### 3.3 Protocol layer (`lib/protocol/stun`, `lib/protocol/turn`)

- STUN/TURN message building/parsing
- MESSAGE-INTEGRITY/FINGERPRINT helpers
- TURN ChannelData framing

Think of protocol as packet-level correctness.

## 4) Runtime model

`IceRuntime` and `IceUdpRuntimeBridge` work in ticks.

A typical tick (`run_io_tick`) can:
1. start new checks
2. send retransmits
3. send consent probes
4. run TURN maintenance
5. process inbound packets
6. apply timeouts/failures

Higher-level driver:
- `run_until_quiescent_or_deadline(...)`
  - stop when no progress (quiescent)
  - or stop at deadline/tick limit

This model keeps behavior deterministic and testable.

## 5) API selection guide

Use this as the default decision table.

- Need to manage streams/candidates/credentials?
  - Use `Agent`
- Need to drive ICE state/checklists?
  - Use `IceRuntime`
- Need actual packet I/O?
  - Use `IceUdpRuntimeBridge`
- Need STUN/TURN packet-level control?
  - Use protocol builders/parsers in `libdice` exports
- Need relay transport management?
  - Use TURN socket wrappers

## 6) Quick start (minimal flow)

```zig
const std = @import("std");
const libdice = @import("libdice");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var agent = libdice.Agent.init(allocator);
    defer agent.deinit();

    const stream_id = try agent.add_stream(1);
    try agent.get_stream(stream_id).?.set_local_credentials("ufrag", "password");

    const local_addr: libdice.CandidateAddress = .{
        .ipv4 = .{ .ip = .{ 192, 0, 2, 10 }, .port = 5000 },
    };

    _ = try agent.add_local_candidate(stream_id, .{
        .id = 1,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = libdice.candidate_compute_foundation(.udp, .host, local_addr),
        .priority = libdice.candidate_compute_priority(.host, 100, 1),
        .address = local_addr,
    });
}
```

## 7) Signaling flow (description exchange)

Common sequence:
1. each side builds local description
2. each side applies remote description
3. each side populates runtime checklist

```zig
var desc = try agent.build_local_description(allocator, stream_id, null);
defer desc.deinit(allocator);

const applied = try peer_agent.apply_remote_description(peer_stream_id, .{
    .credentials = desc.credentials,
    .candidates = desc.candidates,
});
_ = applied;
```

## 8) Runtime + bridge setup

```zig
var runtime = libdice.IceRuntime.init(allocator, &agent, .{}, .{}, .regular);
defer runtime.deinit();

try std.testing.expect(try runtime.attach_stream(stream_id));
_ = try runtime.populate_stream_checklists(stream_id, true, 10_000);
try runtime.start_connecting_all();

var bridge = libdice.IceUdpRuntimeBridge.init(allocator, &runtime);
defer bridge.deinit();
_ = try bridge.add_binding(stream_id, 1, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });
```

## 9) Tick and event handling

Single-tick usage:

```zig
var prng = std.Random.DefaultPrng.init(1);
var outbound: [1024]u8 = undefined;
var recv_buf: [1024]u8 = undefined;
var send_buf: [1024]u8 = undefined;
var completed: [8]libdice.CompletedConnectivityCheck = undefined;
var timed_out: [8]libdice.IceRuntimeTimedOutCheck = undefined;

const tick = try bridge.run_io_tick(
    prng.random(),
    0,
    &outbound,
    &recv_buf,
    &send_buf,
    &completed,
    &timed_out,
    .{ .max_starts_per_tick = 1 },
);
_ = tick;
```

Tick with events:

```zig
var events: [32]libdice.IceRuntimeEvent = undefined;
const with_events = try bridge.run_io_tick_with_events(
    prng.random(),
    10,
    &outbound,
    &recv_buf,
    &send_buf,
    &completed,
    &timed_out,
    &events,
    .{},
);
_ = with_events;
```

## 10) TURN support details

### 10.1 TURN UDP

Supported:
- Allocate
- Refresh
- CreatePermission
- ChannelBind
- relayed payload send/receive

### 10.2 TURN TCP

Supported:
- framed stream handling
- auth challenge/retry flow
- maintenance operations
- relayed data (indication + channel)

### 10.3 Auth flow

Long-term credential flow:
1. initial request
2. read `401/438`
3. extract `REALM` + `NONCE`
4. sign retry
5. apply success response

## 11) TURN code snippets

Build allocate request:

```zig
const tx = [_]u8{ 1,2,3,4,5,6,7,8,9,10,11,12 };
var packet: [1024]u8 = undefined;
const req = try libdice.stun_turn_build_allocate_request(&packet, tx, .{
    .username = "u",
    .realm = "r",
    .nonce = "n",
    .integrity_key = "key",
    .include_fingerprint = true,
});
_ = req;
```

Build refresh request:

```zig
const refresh = try libdice.stun_turn_build_refresh_request(&packet, tx, .{
    .lifetime_seconds = 300,
    .username = "u",
    .realm = "r",
    .nonce = "n",
    .integrity_key = "key",
    .include_fingerprint = true,
});
_ = refresh;
```

## 12) Consent behavior

Consent handling includes:
- probe scheduling
- sent probe tracking
- valid source response acceptance
- wrong source response rejection
- timeout to failed component transition

This is tested at runtime and bridge levels.

## 13) Examples and what they demonstrate

Examples in `examples/`:

- `simple_example.zig`
  - minimal stream + candidate setup
- `sdp_example.zig`
  - local/remote description exchange
- `ice_pump_demo.zig`
  - basic started/completed flow
- `ice_timeout_demo.zig`
  - timeout/retransmit path
- `ice_drive_demo.zig`
  - quiescent/deadline behavior
- `ice_demo_selector.zig`
  - unified CLI selector for all modes

Selector modes:
- `simple`
- `sdp`
- `pump`
- `timeout`
- `drive`

## 14) Commands

Core:

```bash
make test
make build
```

Examples:

```bash
zig build run-simple-example
zig build run-ice-demo -- simple --summary
zig build run-ice-demo -- sdp --summary
zig build run-ice-demo -- pump --summary
zig build run-ice-demo -- timeout --summary
zig build run-ice-demo -- drive --summary
zig build test-examples-smoke --summary all
```

Integration:

```bash
make integration-coturn
make coturn-down
```

## 15) Testing strategy

There are 3 practical layers:

1. module tests in implementation files
2. example smoke tests
3. coturn integration tests

Run order for normal development:

1. `make test`
2. `make build`
3. `zig build test-examples-smoke --summary all`
4. `make integration-coturn` (when TURN/runtime/net behavior changed)

## 16) Troubleshooting

### Build fails in examples

Check selector mode wiring in:
- `examples/ice_demo_selector.zig`
- `build.zig`

Then run:

```bash
zig build test-examples-smoke --summary all
```

### TURN tests fail only with coturn

Likely causes:
- nonce/realm challenge handling bug
- integrity/fingerprint framing mismatch
- maintenance scheduling regression

Run:

```bash
make integration-coturn
```

### Consent failures are unexpected

Check:
- source-address validation for response packets
- probe scheduling windows
- timeout thresholds

## 17) Practical extension rules

When adding features:
- put tests in the same module as implementation
- keep parser/codec tests strict and small
- keep bridge/runtime tests deterministic (fixed seeds/time)
- update selector/example smoke coverage when adding demo modes

When changing TURN behavior:
- update unit tests near TURN protocol/socket modules
- run coturn integration before considering the change complete

## 18) Current maturity snapshot

- ICE core/runtime: strong coverage
- TURN UDP: covered in unit + coturn integration
- TURN TCP: covered in unit + coturn integration
- consent model: covered at runtime and bridge paths
- examples: simple + signaling + runtime execution modes

## 19) Final checklist before merging a major change

- `make test` passes
- `make build` passes
- `zig build test-examples-smoke --summary all` passes
- `make integration-coturn` passes if TURN/runtime/network changed
- this doc still matches current command names and selector modes

## 20) Extended use cases

This section describes concrete ways teams can use `libdice` in real systems.

### Use case A: Headless server-side connectivity worker

Problem:
- You need to run ICE/TURN negotiation on backend workers (no browser runtime).

Why `libdice` fits:
- explicit runtime control
- deterministic tick model
- no hidden event loop required

Typical shape:
1. worker receives signaling payload
2. worker creates `Agent` and `IceRuntime`
3. worker drives `IceUdpRuntimeBridge` in service loop
4. worker emits state updates to your control plane

### Use case B: Integration test harness for network state transitions

Problem:
- You want reproducible tests for nomination, timeout, and consent behavior.

Why `libdice` fits:
- predictable timestamps and PRNG seeds
- module-local tests in core/net/protocol
- coturn integration for real TURN behavior

Typical shape:
1. create deterministic local/remote candidates
2. tick runtime at fixed times
3. inject exact packet sequence
4. assert summary/event/state transitions

### Use case C: TURN-focused relay service validation

Problem:
- You care about long-term auth retries, stale nonce handling, and relay data correctness.

Why `libdice` fits:
- direct TURN request builders/parsers
- TURN UDP + TURN TCP wrappers
- integration tests that hit coturn directly

Typical shape:
1. send unauthenticated request
2. parse `401/438` realm/nonce
3. build signed retry
4. assert allocation/refresh/permission/channel-bind behavior

### Use case D: Custom real-time protocol over ICE-selected path

Problem:
- You want to run your own framing/protocol on the selected transport path.

Why `libdice` fits:
- bridge-level packet routing control
- bytestream hooks for TCP-oriented paths
- transport-level visibility for diagnostics

Typical shape:
1. establish connectivity
2. observe selected pair and consent state
3. map selected path to your protocol session
4. run payload send/receive via direct/relay path rules

## 21) End-to-end recipe: two-agent loopback signaling

This is a complete in-process recipe for signaling exchange and checklist population.

```zig
const std = @import("std");
const libdice = @import("libdice");

pub fn loopback_signaling_demo() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var left = libdice.Agent.init(allocator);
    defer left.deinit();
    var right = libdice.Agent.init(allocator);
    defer right.deinit();

    const ls = try left.add_stream(1);
    const rs = try right.add_stream(1);
    try left.get_stream(ls).?.set_local_credentials("left", "left-pass");
    try right.get_stream(rs).?.set_local_credentials("right", "right-pass");

    const left_addr: libdice.CandidateAddress = .{ .ipv4 = .{ .ip = .{ 192, 0, 2, 61 }, .port = 5000 } };
    const right_addr: libdice.CandidateAddress = .{ .ipv4 = .{ .ip = .{ 198, 51, 100, 61 }, .port = 6000 } };

    _ = try left.add_local_candidate(ls, .{
        .id = 1,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = libdice.candidate_compute_foundation(.udp, .host, left_addr),
        .priority = libdice.candidate_compute_priority(.host, 100, 1),
        .address = left_addr,
    });

    _ = try right.add_local_candidate(rs, .{
        .id = 2,
        .component_id = 1,
        .candidate_type = .host,
        .transport = .udp,
        .foundation = libdice.candidate_compute_foundation(.udp, .host, right_addr),
        .priority = libdice.candidate_compute_priority(.host, 100, 1),
        .address = right_addr,
    });

    var ldesc = try left.build_local_description(allocator, ls, null);
    defer ldesc.deinit(allocator);
    var rdesc = try right.build_local_description(allocator, rs, null);
    defer rdesc.deinit(allocator);

    _ = try left.apply_remote_description(ls, .{
        .credentials = rdesc.credentials,
        .candidates = rdesc.candidates,
    });
    _ = try right.apply_remote_description(rs, .{
        .credentials = ldesc.credentials,
        .candidates = ldesc.candidates,
    });

    var lrt = libdice.IceRuntime.init(allocator, &left, .{}, .{}, .regular);
    defer lrt.deinit();
    var rrt = libdice.IceRuntime.init(allocator, &right, .{}, .{}, .regular);
    defer rrt.deinit();

    try std.testing.expect(try lrt.attach_stream(ls));
    try std.testing.expect(try rrt.attach_stream(rs));

    const pair_summary = try libdice.loopback_populate_checklists_both(
        &lrt,
        ls,
        true,
        1000,
        .{},
        &rrt,
        rs,
        false,
        2000,
        .{},
    );

    _ = pair_summary;
}
```

## 22) End-to-end recipe: runtime tick loop with socket I/O

```zig
const std = @import("std");
const libdice = @import("libdice");

pub fn runtime_tick_demo(agent: *libdice.Agent, stream_id: u32) !void {
    var runtime = libdice.IceRuntime.init(std.heap.page_allocator, agent, .{}, .{}, .regular);
    defer runtime.deinit();
    try std.testing.expect(try runtime.attach_stream(stream_id));
    _ = try runtime.populate_stream_checklists(stream_id, true, 10_000);
    try runtime.start_connecting_all();

    var bridge = libdice.IceUdpRuntimeBridge.init(std.heap.page_allocator, &runtime);
    defer bridge.deinit();
    _ = try bridge.add_binding(stream_id, 1, .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } });

    var prng = std.Random.DefaultPrng.init(77);
    var outbound: [1024]u8 = undefined;
    var recv_buf: [1024]u8 = undefined;
    var send_buf: [1024]u8 = undefined;
    var completed: [16]libdice.CompletedConnectivityCheck = undefined;
    var timed_out: [16]libdice.IceRuntimeTimedOutCheck = undefined;

    var now_ms: u64 = 0;
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const tick = try bridge.run_io_tick(
            prng.random(),
            now_ms,
            &outbound,
            &recv_buf,
            &send_buf,
            &completed,
            &timed_out,
            .{
                .max_starts_per_tick = 2,
                .outbound_options = .{
                    .username = "local:remote",
                    .priority = 12345,
                    .role = .{ .role = .controlling, .tie_breaker = 999 },
                },
            },
        );

        if (tick.started_checks == 0 and tick.advance.packets_seen == 0 and tick.retransmits_sent == 0) {
            break;
        }
        now_ms += 20;
    }
}
```

## 23) End-to-end recipe: TURN auth challenge and retry

```zig
const std = @import("std");
const libdice = @import("libdice");

pub fn turn_auth_retry_demo(server: libdice.CandidateAddress, username: []const u8, password: []const u8) !void {
    var turn = try libdice.TurnUdpSocket.init_nonblocking(
        std.heap.page_allocator,
        .{ .ipv4 = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 } },
        server,
    );
    defer turn.deinit();

    var out: [1024]u8 = undefined;
    var in: [2048]u8 = undefined;
    var tx = [_]u8{ 1,2,3,4,5,6,7,8,9,10,11,12 };

    _ = try turn.send_allocate_request(&out, tx, .{});

    while (true) {
        const p = try turn.recv_from_server(&in) orelse continue;
        switch (p) {
            .stun => |view| {
                if (libdice.stun_turn_is_allocate_success_response(view)) {
                    // success path
                    break;
                }
                if (libdice.stun_turn_is_allocate_error_response(view)) {
                    const code = (try libdice.stun_turn_read_error_code(view)) orelse continue;
                    if (code != 401 and code != 438) return error.UnexpectedTurnErrorCode;

                    const realm = (try libdice.stun_turn_read_realm(view)) orelse return error.MissingRealm;
                    const nonce = (try libdice.stun_turn_read_nonce(view)) orelse return error.MissingNonce;

                    var material: [256]u8 = undefined;
                    const key_input = try std.fmt.bufPrint(&material, "{s}:{s}:{s}", .{ username, realm, password });
                    const key = libdice.md5_digest(key_input);

                    tx[11] +%= 1;
                    _ = try turn.send_allocate_request(&out, tx, .{
                        .username = username,
                        .realm = realm,
                        .nonce = nonce,
                        .integrity_key = key[0..],
                        .include_fingerprint = true,
                    });
                }
            },
            else => {},
        }
    }
}
```

## 24) TURN operation matrix

| Operation | UDP | TCP | Notes |
|---|---|---|---|
| Allocate | Yes | Yes | includes challenge/retry |
| Refresh | Yes | Yes | includes auth retry path |
| CreatePermission | Yes | Yes | tested in coturn flows |
| ChannelBind | Yes | Yes | tested in coturn flows |
| Data (Indication) | Yes | Yes | relayed payload path |
| Data (ChannelData) | Yes | Yes | relayed payload path |

## 25) Example selection by goal

If your goal is this, run this first:

- verify everything compiles quickly
  - `zig build run-simple-example`
- verify signaling exchange logic
  - `zig build run-ice-demo -- sdp --summary`
- verify runtime steady-state behavior
  - `zig build run-ice-demo -- drive --summary`
- verify timeout/retransmit behavior
  - `zig build run-ice-demo -- timeout --summary`
- verify smoke pack for all modes
  - `zig build test-examples-smoke --summary all`

## 26) Operational guidance for teams

### 26.1 Local development loop

1. edit module
2. run `make test`
3. run `make build`
4. run smoke examples if interfaces changed

### 26.2 Before pushing network-sensitive changes

Run:

```bash
make test
make build
zig build test-examples-smoke --summary all
make integration-coturn
```

### 26.3 Debugging order

If something breaks, debug in this order:
1. parser/codec assumptions
2. runtime state transition assumptions
3. bridge packet routing and source validation
4. TURN auth and maintenance timing

## 27) Common mistakes and fixes

### Mistake: checklist not populated

Symptom:
- no checks start

Fix:
- call `runtime.populate_stream_checklists(...)` after candidates exist

### Mistake: missing outbound options

Symptom:
- outbound checks fail to build

Fix:
- include required username/priority/role options when starting checks

### Mistake: TURN retries not signed after challenge

Symptom:
- repeated auth failures with coturn

Fix:
- parse realm+nonce and build retry with integrity key + fingerprint

### Mistake: consent response accepted from wrong source

Symptom:
- false-positive consent health

Fix:
- ensure source-address validation against selected remote candidate

## 28) Additional snippets

### 28.1 Parse address and roundtrip conversion

```zig
const a = try libdice.net_parse_ip_port("127.0.0.1:3478");
const std_a = libdice.net_to_std_address(a);
const back = try libdice.net_from_std_address(std_a);
try std.testing.expect(libdice.CandidateAddress.eql(a, back));
```

### 28.2 Consent tracker quick check

```zig
var t = libdice.ConsentTracker.init(.{
    .enabled = true,
    .interval_ms = 10,
    .response_timeout_ms = 5,
    .max_missed_probes = 0,
});
t.arm(42, 0);
try t.on_probe_sent(10);
try std.testing.expect(t.on_tick(15));
try std.testing.expectEqual(libdice.ConsentState.failed, t.state);
```

### 28.3 TURN TCP framing quick check

```zig
var framed: [128]u8 = undefined;
const f = try libdice.turn_tcp_encode_framed_payload(&framed, "payload");

var framer = libdice.TurnTcpFramer.init(std.testing.allocator);
defer framer.deinit();
try framer.push(f);

var out: [128]u8 = undefined;
_ = try framer.pop_payload(&out);
```

### 28.4 Bytestream dispatcher quick check

```zig
var d = libdice.BytestreamDispatcher.init(.opportunistic);
d.emit_ready(1, 1);
d.emit_data(1, 1, "abc");
d.emit_closed(1, 1);
```

## 29) Testing command reference

Fast core:

```bash
make test
make build
```

Extra local confidence:

```bash
zig build test-dual-mode-regression --summary all
zig build test-examples-smoke --summary all
```

Integration:

```bash
make integration-coturn
make coturn-down
```

## 30) Summary

If you only remember one thing:

- `Agent` manages inventory
- `IceRuntime` manages protocol state
- `IceUdpRuntimeBridge` executes network progress
- examples show real usage patterns
- coturn integration validates TURN behavior against a real server

For day-to-day work, run:

```bash
make test && make build
```

For TURN/runtime changes, add:

```bash
zig build test-examples-smoke --summary all && make integration-coturn
```
