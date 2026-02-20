# kelgroups

A polymorphic Haskell library for **KEL-based group management**.

kelgroups provides the infrastructure layer for managing groups via a Key Event Log (KEL) — an append-only, hash-chained, signed event log. The library is generic over application event types: the base system handles members, roles, voting, and bootstrap, while applications supply domain-specific semantics.

## Packages

| Package | Language | Role |
|---|---|---|
| `kelgroups` | Haskell | Polymorphic base system library |
| `kelgroups-server` | Haskell | Server parameterized by application plugin |
| `kelgroups-ps` | PureScript | Client-side KEL handling and identity |
| `kelgroups-app` | PureScript | UI client, parameterized by plugins |

## Documentation

- [Design Document](design.md) — system invariants, base events, bootstrap mode, architecture
- [Implementation Plan](implementation.md) — modules, types, store, Lean proofs, QuickCheck properties
