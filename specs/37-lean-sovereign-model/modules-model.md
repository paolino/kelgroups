# Modules — 37

| ID | Module | Responsibility | Depends on |
|---|---|---|---|
| M1 | KelGroups.Sovereign.Types (or split) | identifiers, member KEL events, group action, core payload vocabulary, assumptions structure (data-model D1–D5) | KERI.Crypto, KERI.Event |
| M2 | KelGroups.Sovereign.Admission | server state, hosting, rotation, admission, step, reachability (functions F1–F6) | M1, M3 |
| M3 | KelGroups.Sovereign.Membership | membership derived from a group chain; core rules and last-admin guard (F7–F8) | M1 |
| M4 | KelGroups.Sovereign.Theorems (or split per theorem) | T0–T6 | M2, M3 |
| M5 | KelGroups.Sovereign.Axioms | `#guard_msgs` axiom assertions for T0–T6 | M4 |
| M6 | KelGroups.Sovereign | aggregator; imported by KelGroups.lean | M1–M5 |

Direction: M1 ← M3 ← M2 ← M4 ← M5. No module imports the old KelGroups modules.
Exact file split inside lean/KelGroups/Sovereign/ is the commit owner's.
