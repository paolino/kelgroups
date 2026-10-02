# Modules — 41

Dependency direction: M2 ← M3 ← M4 ← {M5, M6, M7}; M1 server-only. Client modules depend on
keri-purs and the existing FFI only; no new runtime npm package.

- M1 `KelGroups.Server` (+ a pure index derivation next to `head`/`roster` in `KelGroups.Group`):
  `GET /groups/<gid>` (D2) and `GET /kel/<prefix>?after=<sn>` (D3). Reads the store's in-memory
  KELs and chains; writes nothing. Owns R1, R2.
- M2 `KelGroups.Client.Kel`: decode of the signed-event wire form (as `KelGroups.Kel.Codec`) and
  the KERI rule of `KelGroups.Kel` (D3k `ValidatedKel`), whole-KEL and suffix extension. Owns R3,
  the KEL half of R9.
- M3 `KelGroups.Client.Group`: Lean vocabulary (`Payload`, `Action`, `Roster`, `applyCore`,
  `roster`, `guardOk`, `membershipOk`), anchor decode/encode (wire form of `KelGroups.Group`),
  walk from the head, fold, and signing against a view. Pure. Owns R4–R7.
- M4 `KelGroups.Client.Sync`: the `Transport` abstraction, sync, refresh, submit with identical
  resend, the 409 re-sign loop, own-history rule. Owns R8–R10.
- M5 `KelGroups.Client.Api`: the HTTP `Transport` over `FFI.Fetch` (replaces the old module).
- M6 `kelgroups-trivial`: read-only viewer over M4/M5 (R11).
- M7 end-to-end suite (a test entry or a workspace package under `client/`) over M4/M5 and the
  real server; adversarial transports wrap M5. Owns R12 rows.
