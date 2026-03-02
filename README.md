# libdice

`libdice` is a Zig ICE/TURN networking library built from the ground up.

It includes:
- ICE candidate/checklist/runtime flow
- TURN UDP and TURN TCP support
- consent freshness handling
- integration tests against coturn

## When to use libdice

Use `libdice` when you need low-level control over ICE/TURN behavior in Zig, for example:
- custom media or data transport stacks
- server-side connectivity agents
- protocol experiments where browser-only WebRTC APIs are too restrictive

If you need a complete browser-compatible WebRTC stack with SDP/session/media layers fully managed,
you will likely need additional layers on top of this library.

## Quick start

1. Create an `Agent` and stream/components.
2. Add local and remote candidates.
3. Create `IceRuntime` and attach stream(s).
4. Use `IceUdpRuntimeBridge` to send/receive checks in a loop.
5. Monitor selected pairs, nomination, and consent state.

## Build and test

```bash
make test
make build
zig build test-examples-smoke --summary all
```

For coturn-backed integration:

```bash
make integration-coturn
```

## Simple example

Run the simple smoke example:

```bash
zig build run-simple-example
```

Or through the demo selector:

```bash
zig build run-ice-demo -- simple --summary
```

## More docs

See `docs/DOCUMENTATION.md` for architecture, usage patterns, snippets, examples, testing, and troubleshooting.
