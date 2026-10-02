# kelgroups

Haskell server and library for groups of KERI identities. The server hosts
each member's own Key Event Log (KEL); a group action is an interaction
event in the signer's own KEL, and a group's chain is the `prev` links
between its actions. Membership — add, remove, grant, revoke, leave — and
the admin rules follow a Lean 4 model.

## Features

- **Member KELs** — inception and rotation with mandatory pre-rotation,
  the KERI rule checked on every append
  ([keri-hs](https://github.com/paolino/keri-hs)); `POST /kel`,
  `GET /kel/<prefix>`
- **Group actions** — `POST /actions` admits a signed interaction carrying
  one group anchor: genesis, add, remove, grant, revoke, leave or opaque
  application data
- **Admin rules** — only admins change membership; the group never ends up
  with members and no admin
- **No server identity** — the server holds no key; every action is signed
  by a member
- **SQLite storage** — one table of member KEL events; KELs and chains are
  re-checked when the database is opened
- **Lean 4 model** — `lean/KelGroups/Sovereign`, generic KERI types from
  [keri-lean](https://github.com/paolino/keri-lean)
- **PureScript client** — client library and Halogen reference UI
  using [keri-purs](https://github.com/paolino/keri-purs)

## Components

| Component | Description |
|---|---|
| `lib/` | Haskell library: member KELs, group actions and membership, store, server |
| `app/` | `kelgroups-server` executable (WAI/Warp + SQLite) |
| `test/` | Hspec and QuickCheck invariants: rule, store and HTTP |
| `client/kelgroups-client/` | PureScript client library |
| `client/kelgroups-trivial/` | Halogen reference UI |
| `lean/` | Lean 4 model of the server and its theorems |

## Documentation

- [Security design](https://paolino.github.io/kelgroups/security-design/)
- [Implementation](https://paolino.github.io/kelgroups/implementation/)
- [Roadmap](https://paolino.github.io/kelgroups/roadmap/)

## Quick start

```bash
nix develop -c just ci                  # format + lint + build + test + lean + client
nix develop -c just serve               # port 8080, database kelgroups.db
nix develop -c just serve 10001 my.db   # custom port and database
kelgroups-server <port> <db>            # the executable itself
```

## License

Apache-2.0
