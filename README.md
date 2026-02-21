# kelgroups

Polymorphic Haskell library for managing groups via a KERI hash-chained
Key Event Log (KEL). The library is generic over application event
types — the base system provides group infrastructure while applications
supply domain-specific semantics.

## Features

- **KERI event format** — events are KERI inception/interaction events
  with group events as JSON anchors, serialized via keri-hs
- **Hash-chained storage** — every event carries `priorDigest`, forming
  a tamper-evident chain backed by SQLite
- **Ed25519 signatures** — all submissions are signed and verified
  against CESR-encoded public keys
- **Admin majority voting** — proposals require majority approval;
  single-admin proposals are enacted immediately
- **Bootstrap mode** — passphrase-gated first admin introduction
- **Stale-tip detection** — concurrent submissions rejected with 409
  when `priorDigest` doesn't match the current chain tip
- **SSE streaming** — real-time event notifications via Server-Sent Events
- **Lean 4 proofs** — core invariants formally verified

## Documentation

- [Design document](https://paolino.github.io/kelgroups/design/)
- [Implementation plan](https://paolino.github.io/kelgroups/implementation/)
- [Roadmap](https://paolino.github.io/kelgroups/roadmap/)

## Quick start

```bash
nix develop -c just ci    # format + lint + build + test + lean
nix develop -c just serve # run server on port 10001
```

## License

Apache-2.0
