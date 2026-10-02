# Modules — 40

- M1 `KelGroups.Group` (changed, pure): owns the payload vocabulary (D1), roster replay
  (R2), the membership rule and last-admin guard (R3) as the `membershipOk` seam called by
  admission, and rebuild (R5). Depends on `KelGroups.Kel`, `KelGroups.Kel.Codec`, keri-hs.
  Functions F1–F4.
- M2 `KelGroups.Kel.Store` (changed): owns the SQLite connection (open/close of the database
  file, D5) in addition to hosted KELs and chains. Depends on M1. F5.
- M3 `KelGroups.Server` (changed): only `kelApp` and its handlers remain; refusal → status
  (D4); everything else in the module (old routes, `mkApp`, `ServerEnv`, `?key=`) is deleted.
  Fallback application (static client files) unchanged.
- M4 `app/Main.hs` (changed): `<port> <db>`; opens M2 directly; no bootstrap, no fold.
- M5 Deleted: `KelGroups.{Store,Fold,State,Validate,Event,Bootstrap,Trivial,Types,
  Server.JSON}`; tests `E2ESpec, FoldSpec, Generators, InvariantsSpec,
  MultiClientSpec, S28AppApiSpec, S28DemoApp, ServerSpec, StoreInvariantsSpec, StoreSpec,
  StoreTestDSL, TestHelpers, TransitionInvariantsSpec, ValidateSpec`; Lean
  `KelGroups.{Basic,KEL,Validate,Transitions,Invariants,FoldInvariants,KELInvariants,
  TransitionInvariants,ValidateInvariants}`. `ServerIdentitySpec`, `MemberKelStoreSpec`,
  `MemberKelServerSpec` are kept and re-pointed at M2 (their old-path legs removed per spec).
  Any library dependency left unused by the deletion is dropped from `kelgroups.cabal`.

Dependency direction: M4 → M3 → M2 → M1 → `KelGroups.Kel`. Nothing depends on M5. Kept unchanged: `KelGroups.Vote.{Types,State}` and `specs/30-vote-substrate`
(held #30 substrate, not old path).
