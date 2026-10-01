# Plan — 38

Haskell library `kelgroups` (lib/), server executable (app/), hspec suite `invariants`
(test/). keri-hs is a flake input (`flake.nix`, `flake.lock`).

## Strategy

- Reuse keri-hs for event types (`Keri.Event`), canonical bytes (`Keri.Event.Serialize`),
  SAID (`Keri.Crypto.SAID.verifySaid`), commitments (`Keri.KeyState.PreRotation`) and
  signatures (`Keri.KeyState.Verify`). Bump the keri-hs pin to its `main` (8674b05, adds
  `Keri.Crypto.SAID`). Do not use `Keri.Kel.Append` (see spec residuals).
- The R3 rule is one pure function over a hosted KEL and a signed event, total over
  icp/rot/ixn, returning the extended KEL or a typed refusal.
- Member KELs live in the server's SQLite database, next to the old group tables, so #39 can
  append an interaction and advance a group head in one transaction. Every append is
  validate-then-persist under the store's append lock in one SQLite transaction; memory is
  updated only after commit.
- The server identity is deleted, not hidden: types, tables, functions, commands, the JSON
  field, the ephemeral integrated-store keypair, and the server-only JWK codec that loses its
  last caller (lib/KelGroups/Jwk.hs, test/JwkSpec.hs; the client's own JWK is untouched).

## Live boundaries

HTTP (`POST /kel`, `GET /kel/<prefix>`, `/info`), SQLite schema, keri-hs version.

## Slices (one OWNER campaign, two bisect-safe commits, each passing `just ci`)

- C1 `feat: host member KELs with KERI validation on append` — R1–R6, R8, keri-hs bump,
  INV-38-* rows except NO-SERVER-KEY and OLD-PATH; docs: member KEL section in
  docs/docs/implementation.md.
- C2 `feat!: remove the server identity` — R7, R9; INV-38-NO-SERVER-KEY, INV-38-OLD-PATH;
  docs: key-export.md and implementation.md lose the server identity.

## Constraints

- Clean break: no migration, no compatibility shim, no dual path.
- Domain words follow the Lean model (`host`, `rotate`, `tip`, `hosted`, KEL, prefix).
- Host load is high: iterate with `cabal build`/`cabal test` inside the dev shell; the full
  `nix develop .#ci -c just ci` runs at checkpoints.
