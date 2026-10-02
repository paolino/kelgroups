# Plan — 41

Base: the planning commit on `origin/main` e380d11. Topology: OWNER (one commit owner, one
persistent auditor; operator team "3 opus"; draft=NONE).

## Strategy

The server gains two read-only, non-evidence endpoints (desk A-001): the group index and the KEL
suffix. Everything else is client: a pure core (KEL rule, walk, fold, sign) re-checking what the
server's `KelGroups.Kel`/`KelGroups.Group` check, then an effectful sync over an injectable
transport. Acceptance runs the client against the real `kelgroups-server` on a fresh database;
adversarial rows (omitted event, omitted KEL, lost response) wrap the real HTTP transport and
alter or drop real responses — the server itself is never patched or seeded.

Harness (cheapest real one): a PureScript end-to-end suite run under node, started by a
`justfile` recipe that builds and spawns `kelgroups-server <port> <tmpdb>`, passes the URL, and
stops the server; `just ci` runs it. Recipe names are fixed: `e2e-client` (spawn + run + stop)
and `e2e-client-against url` (run against a given URL; an empty URL must fail).

Wire compatibility: client-built events must be admitted by the real server (keri-hs re-serializes
anchors with sorted keys), and server-built KELs must validate in the client; both are established
by the /e2e rows, not assumed. A byte-level divergence in keri-purs (external, pinned) is a
BLOCKED question, never a local workaround.

## Commits (bisect-safe; each passes `just ci`)

- C1 `feat: group index and KEL suffix read endpoints` — R1, R2, server docs (T001).
- C2 `feat: client validation, replay and fold of the group` — R3–R7 pure core and its /unit
  rows; old client untouched (T002, T003).
- C3 `feat!: client sync against the server, replacing the L1/L2 client` — R8–R13: sync,
  refresh, submit, HTTP transport, e2e harness and rows, removal of the old client path,
  viewer adaptation, docs (T004–T006).

## Old path removed in C3 (swap rule)

`client/kelgroups-client/src/KelGroups/Client/{Event,State,Fold,Message,Types,Codec}.purs`,
the old `/events`/`/info` calls of `KelGroups/Client/Api.purs` (module replaced), `src/FFI/SSE.{purs,js}`;
tests `test/{InvariantsSpec,TransitionInvariantsSpec,FoldSpec,Generators}.purs`;
`kelgroups-trivial/src/View/{Bootstrap,Proposals,Members}.purs` (rewritten or deleted).
Kept: `KelGroups.Client.Jwk` + `JwkSpec` (key export, #42), `FFI.Fetch`, `FFI.KeyBytes`.
A module left with no importer and no test after the swap is deleted (e.g. `FFI.Storage` if the
viewer does not use it). No new runtime npm dependency.

## Budgets

Cheap tier (counted): `spago build`/`spago test` and focused `cabal test --match` inside one
`nix develop .#ci` shell. Expensive tier (tight): full `just ci` once per GREEN checkpoint, the
per-commit CI (G3) once at pre-push. Host load is high.
