# Modules — 39

| ID | Module | Change | Responsibility | Depends on |
|---|---|---|---|---|
| M1 | `KelGroups.Group` | new, pure | `Action`, `Payload`, anchor codec (D1) from/to a keri-hs `ixn`; `Chain`, `head`, `Roster`, `roster`, `applyCore` (genesis, app); the hosted state (KELs + chains) and `admit`; chain rebuild for load (R6); typed refusals | M-Kel (`KelGroups.Kel`), keri-hs Event, aeson |
| M2 | `KelGroups.Kel.Store` | changed | hosted state holds chains; `admitAction` under the existing append lock (decide, INSERT, publish KEL and chain in one step); R5 retry lookup; open rebuilds chains and refuses on R6 violation | M1 |
| M3 | `KelGroups.Server` | changed (`kelApp` only) | `POST /actions`; refusal → status (D4) | M1, M2 |
| M4 | `docs/docs/implementation.md` | changed | group action section | — |

Dependency direction: `KelGroups.Kel` ← M1 ← M2 ← M3. M1 imports no IO module. M1–M3's new
code imports none of `KelGroups.{Store,Fold,State,Validate,Event,Vote.*,Bootstrap,Trivial,Types,Server.JSON}`.
`app/Main.hs` needs no change (it already mounts `kelApp`); the owner may touch it only if the
store's open signature changes. Data: data-model.md; signatures: functions-model.md.
