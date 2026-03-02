# libdice

`libdice` is a Zig ICE/TURN networking library built from the ground up.

It includes:
- ICE candidate/checklist/runtime flow
- TURN UDP and TURN TCP support
- consent freshness handling
- integration tests against coturn

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

See `docs/` for architecture, examples, and testing details.
