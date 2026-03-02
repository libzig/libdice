# Changelog

## [0.0.3] - 2026-03-02

### <!-- 0 -->⛰️  Features

- Add stable API facade for 1.0 freeze path
- Add sdp-style example flow and smoke coverage
- Add explicit public API version compatibility exports
- Init
- Expose consent probe and response totals in drive loop
- Drive consent probes and responses through UDP runtime tick
- Sign TURN refresh requests and verify maintenance auth
- Add coturn challenge integration and signed allocate request
- Add two-agent loopback harness helpers
- Add candidate exchange text codec for integration
- Add optional bytestream callback hook dispatcher
- Add ICE-TCP role action helpers and signaling coverage
- Add ICE-TCP role compatibility in pair generation
- Integrate TURN TCP relay path into ICE bridge
- Add nonblocking TURN TCP client wrapper
- Add nonblocking TCP candidate listener and stream
- Add TURN-over-TCP framing and reassembly module
- Add force-relay options to runtime expansion helpers
- Add force-relay checklist population policy
- Add TURN maintenance status snapshot API
- Expose TURN maintenance diagnostics in tick and loop summaries
- Add per-binding TURN maintenance diagnostics
- Add bounded TURN maintenance backoff on hard errors
- Surface non-retryable TURN errors in bridge telemetry
- Retry TURN allocate and refresh with stale-nonce challenge
- Add TURN stale-nonce challenge retry plumbing
- Handle TURN permission and channel refresh successes
- Support TURN allocate bootstrap in maintenance cycle
- Apply TURN refresh success updates in bridge loop
- Add TURN maintenance scheduling into bridge tick
- Add pair-aware payload send routing for relay candidates
- Add TURN permission and channel refresh scheduling
- Route relay connectivity checks through TURN bindings
- Add TURN relayed-data parsing and peer send helper
- Add ICE UDP bridge runtime and TURN UDP transport
- Add nonblocking UDP dispatcher for stream components
- Add UDP socket substrate and net address helpers
- Add signaling descriptions and remote apply APIs
- Add candidate copy APIs and batch trickle expansion
- Add event draining and telemetry across ICE runtime
- Add runtime stats snapshots for ICE orchestration
- Add nomination modes across connectivity runtimes
- Add consent freshness and runtime consent ticking
- Add restart reset flow across ICE runtimes
- Add global ICE runtime for stream orchestration
- Add checklist pair builder from stream candidates
- Add stream-level connectivity runtime orchestrator
- Add component-level connectivity check engine
- Add host candidate discovery and agent gather flow
- Add candidate model and stream candidate stores
- Add agent stream component runtime scaffolding
- Add candidate pair checklist ordering helpers
- Add connectivity check tracker runtime helper
- Add STUN response classification and tx matching
- Add STUN retry policy and transaction store
- Add TURN create-permission and channel-data helpers
- Add TURN peer relayed address and channel/send helpers
- Add XOR-MAPPED-ADDRESS binding response support
- Add ICE connectivity-check request response helpers
- Support embedded STUN integrity and fingerprint checks
- Add TURN allocate-refresh usage helpers
- Add STUN ICE usage attribute helpers
- Add STUN binding usage helpers
- Add STUN integrity and fingerprint helpers
- Add HMAC-SHA1 and MD5 crypto helpers
- Add STUN transaction id utilities
- Add STUN message builder scaffold
- Add STUN message parser iterator scaffold
- Add STUN attribute header scaffold
- Add STUN header parser-encoder scaffold
- Add M0 feature flags and timer scaffold
- Rename `libfast` to `libdice` and update examples
- Init

### <!-- 1 -->🐛 Bug Fixes

- Align STUN integrity framing with coturn challenge retry

### <!-- 2 -->🚜 Refactor

- Remove API guidance metadata and compatibility helpers
- Migrate sdp example flow to StableApi facade

### <!-- 3 -->📚 Documentation

- Add advanced entrypoint inventory for API pruning prep
- Expose recommended entrypoint metadata for API guidance
- Add public API compatibility note in libdice entrypoint

### <!-- 6 -->🧪 Testing

- Embed translated libnice parity tests into implementation modules
- Add translated libnice parity suite and wire into test step
- Ignore spoofed consent response in udp bridge path
- Verify drive-loop consent probe and response totals
- Accept consent response from selected remote
- Reject spoofed consent responses from wrong remote
- Assert consent_failed event on automated consent timeout
- Cover automated consent failure transition in io tick
- Add coturn tcp relayed data integration flow
- Add coturn tcp permission and channel bind integration
- Add coturn tcp refresh integration after allocate auth
- Add coturn tcp allocate integration and tcp fixture port
- Cover coturn relayed data path across allocations
- Add coturn permission and channel bind integration coverage
- Add coturn refresh integration after authenticated allocate
- Cover TURN relayed response completion in ICE bridge

### <!-- 7 -->⚙️ Miscellaneous Tasks

- Add coturn fixture bootstrap and wait scripts
- Export TURN data indication helpers

### <!-- 9 -->◀️ Revert

- Remove StableApi facade and sdp example usage

