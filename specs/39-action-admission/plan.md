# Plan — 39

Haskell library `kelgroups` (lib/), server executable (app/), hspec suite `invariants`
(test/). Builds on #38: `KelGroups.Kel` (KEL rule incl. `appendInteraction`),
`KelGroups.Kel.Codec` (signed-event wire form), `KelGroups.Kel.Store` (hosted KELs in SQLite
under one append lock, memory published after commit under a mask).

## Strategy

- A pure admission module over the hosted state (KELs + chains), in Lean words: decode a
  group action from an `ixn`, then `admit` = the #38 interaction rule on the signer's KEL plus
  the group conditions; returns the extended state or a typed refusal.
- The hosted state in `KelGroups.Kel.Store` grows chains next to KELs, held as one value, so a
  KEL append and a head advance are published in one step after the single SQLite INSERT of
  the interaction row. No new table: chains are rebuilt from KEL rows on open (R6).
- `POST /actions` beside `POST /kel` in `kelApp`; refusal classes map to statuses (D4).
- No import of any old-path module from new or changed admission code (R8).

## Live boundaries

HTTP (`POST /actions`), SQLite rows (unchanged schema), the anchor wire form (D1) — a contract
for the client tickets #41/#42.

## Slices (one OWNER campaign, one bisect-safe commit passing `just ci`)

- C1 `feat: admit group genesis and actions` — R1–R8, every INV-39 row; docs: group action
  section in docs/docs/implementation.md.

## Constraints

- Clean break, no shim. Old path untouched (A-001).
- Host load is high: iterate with `cabal build`/`cabal test --match` inside one dev shell; the
  full `nix develop .#ci -c just ci` runs at checkpoints.
