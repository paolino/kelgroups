# kelgroups

A Haskell server and library for **groups of KERI identities**.

The server hosts each member's own Key Event Log (KEL). A group action is an interaction event
in the signer's own KEL; a group's chain is the `prev` links between its actions, and its
membership — add, remove, grant, revoke, leave, under admin rules — is the replay of that
chain. The server holds no key: every action is signed by a member. The rules follow the Lean
4 model in `lean/KelGroups/Sovereign`.

## Packages

| Package | Language | Role |
|---|---|---|
| `kelgroups` | Haskell | Member KELs, group actions and membership, store, WAI application |
| `kelgroups-server` | Haskell | Executable: `kelgroups-server <port> <db>` |
| `kelgroups-client` | PureScript | Client-side KEL handling, API, and state |
| `kelgroups-trivial` | PureScript | Halogen reference UI |

## Dependencies

| Dependency | Language | Provides |
|---|---|---|
| [keri-hs](https://github.com/paolino/keri-hs) | Haskell | KERI events, CESR encoding, Ed25519 crypto, KEL primitives |
| [keri-purs](https://github.com/paolino/keri-purs) | PureScript | KERI events, CESR encoding, Ed25519 crypto, KEL replay |
| [keri-lean](https://github.com/paolino/keri-lean) | Lean 4 | Generic KERI types (`Digest`, `SAID`, `Key`, `KELEvent`, `hashChainValid`) |

## Documentation

- [Security Design](security-design.md) — what the server can and cannot do, what members sign, key loss and theft
- [Implementation](implementation.md) — modules, member KELs, group actions, membership, store, endpoints
- [Key Export](key-export.md) — member keys as JWK
- [Roadmap](roadmap.md)
