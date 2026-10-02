# Plan — 40

Haskell library `kelgroups` (lib/), server executable (app/), hspec suite `invariants`
(test/), Lean model (lean/). Builds on #39's admission substrate.

## Strategy

- Extend the pure admission module with the membership vocabulary: payload decoding,
  roster replay for every payload, and `membershipOk` (Lean words) as the last admission
  condition; rebuild on open applies the same conditions.
- Then delete the whole L1/L2 group path: old routes and handlers, old modules and tests,
  old Lean modules and docs pages; the member KEL store takes over the SQLite connection;
  the executable, `just serve`/`restart` and the docker image lose the passphrase.

## Consumers of the removed surface outside lib/test/app

`client/kelgroups-client/src/KelGroups/Client/Api.purs` and
`client/kelgroups-trivial/src/View/App.purs` (`/events`, `/info`, `/stream`, `?key=`): runtime
breakage until #41/#42; client CI builds and runs unit specs only (no HTTP), so it stays
green. `nix/docker-image.nix` and `justfile` (`serve`, `restart`) pass the passphrase:
updated here. Docs pages: updated or deleted here except `roadmap.md` (residual).

## Live boundaries

HTTP (`POST /actions` refusal classes, removed routes), the payload wire form (D1, contract
for #41/#42), SQLite file layout (D5), the executable command line (docker image).

## Slices (one OWNER campaign; two bisect-safe commits, each passing `just ci`)

- C1 `feat: core membership actions and admin rules` — R1–R5, INV-40-{ADMIN, LAST-ADMIN,
  ADD-HOSTED, REMOVED, ROSTER, STATE, LEAVE, GUARD, SHAPE, LOAD, ORDER, WRITE500}; docs:
  membership section of implementation.md. Old path untouched in this commit.
- C2 `feat!: remove the L1/L2 group path` — R6–R8, INV-40-{GONE, SCHEMA, CLI}; kept
  INV-38/INV-39 rows re-pointed.

## Constraints

- Clean break: no migration of old stores, no shims.
- Host load is high: iterate with `cabal build`/`cabal test --match` inside one dev shell;
  `nix develop .#ci -c just ci` at checkpoints.
