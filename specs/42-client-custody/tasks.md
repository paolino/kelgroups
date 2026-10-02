# Tasks — 42

## S1 (OWNER)

C1 `feat: client key custody with a separately backed-up next key`
- [ ] T001 M1 F1–F6, M3 F7/F9 `postKel`, INV-42-COMMIT/unit, INV-42-SPLIT/unit, INV-42-GUARD/unit, INV-42-ADMIT/unit, INV-42-LOST/unit
- [ ] T002 /e2e rows INV-42-COMMIT/e2e, INV-42-LOST/e2e, INV-42-RESTORE/e2e; docs custody section

C2 `feat: re-sign a stale action with the rotated key`
- [ ] T003 M2 F8 (`act` over the device signer, `NoDeviceKey`), callers moved, INV-42-STALE/unit, INV-42-STALE/e2e
- [ ] T004 M4 identity panel and browser device store; docs rotation and stale action
