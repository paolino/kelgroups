# Modules — 38

| ID | Module | Change | Responsibility | Depends on |
|---|---|---|---|---|
| M1 | `KelGroups.Kel` | new, pure | member KEL type, `tip`, the R3 rule (`host`, `rotate`, interaction append), typed refusals | keri-hs (Event, Serialize, SAID, PreRotation, Verify) |
| M2 | `KelGroups.Kel.Codec` | new, pure | JSON wire form of a signed event (KERI field labels + indexed signatures) to and from keri-hs `Event` | M1, aeson |
| M3 | `KelGroups.Kel.Store` | new, IO | SQLite table of member KEL events in the server database; load with R6 re-check; atomic host/rotate | M1, M2, sqlite-simple, stm |
| M4 | `KelGroups.Server` | changed | `POST /kel`, `GET /kel/<prefix>`; refusal → HTTP status (data-model D4); `/info` without `serverKey` | M2, M3 |
| M5 | `KelGroups.Store` | changed | server identity deleted (table, fields, open variants, inception, integrated-store keypair) | — |
| M6 | `app/Main.hs` | changed | opens the member KEL store with the server; `export-key`/`import-key` deleted | M3, M4, M5 |
| M7 | `KelGroups.Jwk`, `test/JwkSpec.hs` | deleted | last caller (server identity) removed | — |

Dependency direction: M1 ← M2 ← M3 ← M4 ← M6. M1 and M2 import no IO module. M3 shares the
database connection/lock policy of M5 but M5 does not import M1–M3. Data rows: data-model.md;
signatures: functions-model.md.
