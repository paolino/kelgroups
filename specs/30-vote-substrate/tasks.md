# Tasks — #30 vote substrate

Slice decomposition per `T30-CONTRACT-r9.md` §4. The compiler boundary is
reached at slice 0, before any Vote code exists, so a toolchain fault surfaces
there rather than at demonstration time. Client, integration, replay and
closure are slices in this sequence, not deferred past it.

## S30-0 — toolchain preflight (no product behaviour)

- [x] **T30-0a** Cold build plus `.hi` selection, freshness and
      `--show-iface` emission on the existing module set
      (`KelGroups.Event`, and `KelGroups.Server.JSON` as the nested-module
      analogue of `Vote/Types`).
- [x] **T30-0b** Independent cold export build; two-tree comparison of the
      emitted interface bytes.

## S30-1 — extent declarations

- [x] **T30-1** Declare `lib/KelGroups/Vote/Types.hs` and
      `lib/KelGroups/Vote/State.hs` with the Lean-mirrored identities and add
      them to `exposed-modules`. Declarations only: no transitions, no verdict
      logic, no fold wiring. `Verdict` has exactly three constructors with
      `Open` distinct; `QuestionKind`'s permission arm carries its designee so
      an undesigneed permission is not representable; `ClosureCause` carries
      all four causes as data; `Threshold` is a parameter type over a natural
      domain, with `legacyThreshold`/`zeroThreshold` unexported exhibits and no
      shipped default.

## S30-2 … S30-n — behavioural rows

- [ ] **T30-2** R30-1 openQuestion: collective and permission-with-designee.
- [ ] **T30-3** R30-2 placement, switch, recast, idempotence.
- [ ] **T30-4** R30-3 sweep, closure, retention and non-duplication.
- [ ] **T30-5** R30-4 `verdictOf`: threshold a parameter everywhere.
- [ ] **T30-6** R30-5 refusals produced.
- [ ] **T30-7** R30-6 canonical-view franchise.
- [ ] **T30-8** R30-7/14 negative delivery at the boundary.
- [ ] **T30-9** R30-8 route separation.
- [ ] **T30-10** R30-10 mechanism surface only.
- [ ] **T30-11** R30-12 client adapt-only.

## S30-final — closure

- [ ] **T30-12** Replay and closure evidence, `Trivial` presence, full
      `just ci`, tracked-clean both ends, founding guard.

## Recorded dependencies, not delivered scope

R30-9 rebind is gated on `#68`; R30-10U/R30-11 stay unscheduled and
evidence-only; R30-13 is Lean-owned. `#33`/`#34` remain downstream.
