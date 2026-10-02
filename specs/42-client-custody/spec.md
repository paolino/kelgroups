# 42 — Client: key custody and rotation

Issue: #42 (epic #45). Contract: `docs/docs/security-design.md` ("Identity": pre-rotation
mandatory, split custody, stolen current key; "Admission and retry": a stale action is refused
and signed again) and the Lean model `lean/KelGroups/Sovereign/*.lean` (#37): `host`, `rotate`
(`p` = the KEL tip, no group change), `Admissible` (`p` = the signer's tip), trace
`Example.lean` `bobStale`/`bobFresh`. Key material is opaque to the model (`Inception.body`,
`Rotation.body`); the KERI rule the server applies is `KelGroups.Kel` (#38: inception with a
mandatory next commitment, rotation revealing the committed key). Code follows the model; a
divergence is a question to the desk, never a silent fork.
Building blocks on main: `KelGroups.Client.Jwk` (#11, JWK export/import), `KelGroups.Client.Kel`
and `KelGroups.Client.Sync` (#41: validation, replay, sync, submit, 409 re-sign).
Out of scope: encryption of stored keys at rest (#10), read access control (#44), any server
change (none is needed: `POST /kel` and `GET /kel/<prefix>` exist).

## Story

As a member, my client creates my identity with two keys: the current key stays on my device,
the next key is handed to me as a backup file and is not kept on the device. To rotate — routinely,
or because my current key was stolen, or because my device was wiped — I give the client my
backup file; it rotates to that key, commits a fresh next key and hands me the new backup file.
My identifier never changes and my old and new history both verify. An action I signed just
before a rotation is refused by the server and my client signs it again with the new key.

## Requirements

- R1 Inception: the client generates a current and a next Ed25519 key pair from a
  cryptographically secure source (tweetnacl), builds an inception with `k` = [current public
  key], `kt` = 1, `n` = [the commitment to the next public key], `nt` = 1, no witnesses, signs
  it with the current key and posts it with `POST /kel`. The prefix is the inception's SAID.
- R2 Rotation: from a next-key backup (D2) the client fetches its own KEL (`GET /kel/<prefix>`),
  validates it with `validateKel` (#41), checks that the backup's public key is the one committed
  by the tip's establishment state, generates a fresh next key pair, builds a rotation with
  `p` = the validated tip, `s` = tip `s` + 1, `k` = [backup public key], `kt` = 1,
  `n` = [commitment to the fresh next key], `nt` = 1, no witnesses, signs it with the backup key
  and posts it with `POST /kel`.
- R3 Split custody: after an admitted inception or rotation the device record (D1) holds exactly
  the prefix and the current key; the next key's private material is never written to the device
  store, in any encoding. The backup (D2) holds exactly the prefix and the next key; never the
  current key. The client returns the backup document for export; it keeps no copy.
- R4 Device update only on admission: the device record is written only once the server has
  admitted the event (an answer of 200, or the event seen in the hosted KEL, R6). A refused
  inception or rotation leaves the device store unchanged, and after a refused rotation the
  imported backup is still the committed next key.
- R5 Local refusals, before anything is posted: a malformed backup document; a backup key that is
  not the committed next key of the hosted KEL (another identity's backup, an already used
  backup); a hosted KEL that does not validate or whose prefix differs from the backup's; an
  inception on a device that already holds an identity; a rotation whose backup names a prefix
  different from the identity the device holds. Errors never contain key material.
- R6 Lost answer: the event is resent with identical bytes (bounded, as `submit`); when no
  admission answer arrives, or the resend is refused because the first copy already landed
  (`alreadyHosted`, `notTipSuccessor`), the outcome is decided by the hosted KEL: the event is
  present ⇒ admitted (R3, R4 apply); absent ⇒ refused (R4). When the KEL cannot be read either,
  the outcome is undecided and carries every key generated for the event, so nothing that may
  have been committed is lost; the device store is unchanged.
- R7 Restore: after the device store is cleared, a rotation from the last exported backup (R2)
  succeeds without any device state; the prefix is unchanged; the whole hosted KEL (old events
  and the rotation) validates with `validateKel`; the identity keeps acting in its groups with the
  new current key, and rotates again from the newly exported backup.
- R8 Stale re-sign: `act` reads the signer from the device on every signing round. An action
  signed before a rotation of its signer and refused by the server (409 `notTipSuccessor`) is
  refreshed (#41 R9), signed again with the rotated key against the new tip and head, and
  admitted. An empty device signs nothing and sends nothing (D4 `NoDeviceKey`).
- R9 Trivial UI (minimal wiring): create an identity and download its backup file; rotate from an
  uploaded backup file and download the new backup file; show the device's prefix. The device
  store in the browser is `window.localStorage`, unencrypted (#10). Nothing else in the UI.
- R10 Docs: the client section of `docs/docs/implementation.md` states custody (device record,
  backup file, rotation flow, restore) and that stored keys are not encrypted at rest (#10).

## Invariants (all BLOCKING)

Test output contract as #41: one line `PASS <ID>/<layer> <description> cases=<n>` per passing
check (n executed cases ≥ 1), a line starting `FAIL ` and a non-zero exit otherwise. /e2e rows run
against the real `kelgroups-server` on a fresh database (`just e2e-client`), identities created by
the client's own inception through `POST /kel`; adversarial cases wrap the real HTTP transport
and never patch or seed the server.

| ID | Layer | Fails when |
|---|---|---|
| INV-42-COMMIT | unit, e2e | an inception or rotation built by the client lacks the next commitment, commits to a key other than the one exported, or is not admitted by the real server; or the resulting KEL does not validate with `validateKel` |
| INV-42-SPLIT | unit | after an inception or a rotation the raw device store contains the next key's private material (seed or secret key, any encoding the client uses) or lacks the current key; or the exported backup contains the current key |
| INV-42-GUARD | unit | any R5 case posts anything, changes the device store, or yields an error text containing key material |
| INV-42-ADMIT | unit | a refused inception or rotation changes the device store, or after a refused rotation the imported backup no longer rotates |
| INV-42-LOST | unit, e2e | an admitted event whose answer is lost is not recognised as admitted (device not updated, new backup not returned); a lost event that did not land is reported admitted; or an undecided outcome drops a generated key |
| INV-42-RESTORE | e2e | after clearing the device store, rotating from the backup fails, changes the prefix, leaves a KEL that does not validate, or the identity cannot act and rotate again |
| INV-42-STALE | unit, e2e | an action made stale by a rotation is not refused by the server first, is not re-signed and admitted, or its admitted signature does not verify under the rotated key alone; or `act` with an empty device sends anything |

INV-41-* rows (#41) keep passing unchanged.

## Lean correspondence

Inception = `host` of an unhosted identifier; rotation = `rotate` (`p` = tip, the group chain
unchanged); stale action = `Admissible` second clause failing (`tip ≠ a.p`), trace `bobStale`
refused and `bobFresh` admitted after `rotB`. Key custody itself is outside the model (key
material is the opaque `body`); R3–R6 and R9 are client obligations with no model counterpart.

## Residuals

- Keys at rest in the browser are not encrypted (#10).
- One identity per device store; several identities per device are not in scope.
- Thresholds are single-key (`kt` = `nt` = 1); multi-key custody is not in scope.
