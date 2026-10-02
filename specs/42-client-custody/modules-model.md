# Modules — 42

Dependency direction: M2 (`Sync`) ← M1 (`Custody`) ← {M3, M4, tests}; M1 also depends on
`KelGroups.Client.{Kel,Jwk,Group}` and keri-purs. `Sync` does not import `Custody` (the signer
reaches `act` as an effect). No new runtime npm package.

- M1 `KelGroups.Client.Custody` (new): the device store abstraction and its in-memory and
  `localStorage` instances, the device record (D1) and backup document (D2) codecs, inception
  (R1), rotation (R2), split custody (R3), device update on admission (R4), local refusals (R5),
  lost-answer decision (R6), the device signer for `act`. Owns INV-42-COMMIT/SPLIT/GUARD/ADMIT/
  LOST/RESTORE. A browser storage FFI next to it if needed (`FFI.*`).
- M2 `KelGroups.Client.Sync` (changed): `Transport` gains `postKel`; `act` takes the signer as
  an effect read every round (R8). Owns INV-42-STALE.
- M3 `KelGroups.Client.Api` (changed): `postKel` = `POST /kel`.
- M4 `kelgroups-trivial` (changed): identity panel (R9) over M1 with the `localStorage` store;
  file download/upload in its own view code.
- M5 tests: unit rows over M1/M2 with fake or in-memory transports; /e2e rows in the existing
  real-server suite.
