# Examples

## Available demos

- `pump` — basic started/completed flow
- `timeout` — timeout and retransmit behavior
- `drive` — quiescent/deadline drive loop behavior
- `sdp` — local/remote description exchange and checklist population
- `simple` — minimal setup smoke flow

Run with selector:

```bash
zig build run-ice-demo -- <mode>
zig build run-ice-demo -- <mode> --summary
```

## Simple example behavior

`simple_example.zig` creates an `Agent`, adds one stream, sets local credentials,
adds one local host candidate, and prints a compact summary.

It is intended as the quickest sanity check before running heavier demos.

## Example smoke suite

The smoke suite runs all selector modes in summary mode:

```bash
zig build test-examples-smoke --summary all
```
