# Plan — 42

Base: the planning commit on `origin/main` e476356. Topology: OWNER (one commit owner, one
persistent auditor; operator team "3 opus"; draft=NONE).

## Strategy

Client only. A new custody module builds and signs inception and rotation events with keri-purs
constructors and keys from tweetnacl, posts them through the #41 `Transport` (which gains
`POST /kel`), and owns two documents: the device record (current key, in an injectable device
store) and the next-key backup (returned as a file text, never stored). Rotation first validates
the hosted KEL with the #41 rule and checks the backup key against the committed next keys, so a
wrong backup is refused before anything is sent. `act` stops taking a fixed signer and reads the
device on every round, so the #41 409 loop re-signs with the rotated key. The trivial UI gains
the identity panel and a `localStorage` device store.

Harness: the #41 real-server suite (`just e2e-client`, `just e2e-client-against url`, run by
`just ci`). Lost answers wrap the real HTTP transport (the request reaches the server, the
answer is dropped), as #41 `Test.Transports`. The stale action is made in flight by a transport
wrapper that admits the signer's rotation through the real server between the signing and the
first `POST /actions`. Test-side fixtures (`Test.Fixtures`, `Test.World`) stay independent of the
custody module: they remain the oracle for commitments and signatures.

## Commits (bisect-safe; each passes `just ci`)

- C1 `feat: client key custody with a separately backed-up next key` — R1–R7, R10 (custody
  section): custody module, device store, backup document, `POST /kel` in the transport and the
  HTTP transport, INV-42-COMMIT/SPLIT/GUARD/ADMIT/LOST/RESTORE rows (T001–T002).
- C2 `feat: re-sign a stale action with the rotated key` — R8, R9, R10 (rotation and stale
  action): `act` over the device signer, INV-42-STALE rows, trivial UI identity panel and the
  browser device store (T003–T004).

## Swap

`act`'s fixed `Signer` argument is replaced, not overloaded: callers (tests, UI) move to the
device signer in C2. `Signer` and `signAction` stay (pure core). Nothing else of the client is
replaced. A module left with no importer and no test is deleted.

## Budgets

Cheap tier (counted): `spago build`/`spago test`, a direct e2e run against a server you spawn,
inside one `nix develop .#ci` shell. Expensive tier (tight): `just ci` (G2) at most once per GREEN
checkpoint; G3 (per-commit CI) once at pre-push. Host load is high.
