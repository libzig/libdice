# Testing

## Fast local checks

```bash
make test
make build
zig build test-dual-mode-regression --summary all
zig build test-examples-smoke --summary all
```

## coturn integration

```bash
make integration-coturn
```

This brings up a coturn container, waits for readiness, runs integration tests,
then you can tear it down with:

```bash
make coturn-down
```

## Scope of integration coverage

- TURN UDP: allocate/auth/retry, refresh, permission, channel bind, relayed data
- TURN TCP: allocate/auth/retry, refresh, permission, channel bind, relayed data
- ICE consent: probe scheduling, response acceptance/rejection, failure transition
