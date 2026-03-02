# Overview

## Project layout

- `lib/core/` — ICE model, candidate pairing, runtime state, consent
- `lib/net/` — UDP/TCP sockets, runtime bridge, TURN socket wrappers
- `lib/protocol/stun/` — STUN/TURN encoding, parsing, integrity helpers
- `lib/protocol/turn/` — TURN ChannelData framing helpers
- `lib/integration/` — coturn and system-level integration tests
- `examples/` — runnable demos and smoke scenarios

## Main flow

1. Create `Agent` and stream/components.
2. Add local and remote candidates.
3. Build/populate checklist through `IceRuntime`.
4. Drive traffic through `IceUdpRuntimeBridge` ticks.
5. Exchange connectivity checks until nomination/completion.
6. Keep consent fresh and maintain TURN allocations as needed.

## TURN support

- TURN UDP: allocate, refresh, permission, channel bind, relayed payloads
- TURN TCP: framed stream handling, auth challenge/retry, maintenance and relayed data

## Testing strategy

- Unit tests live near implementation in each Zig file.
- Example smoke tests are run with `zig build test-examples-smoke`.
- coturn integration runs with `make integration-coturn`.
