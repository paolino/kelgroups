# 38 — Host member KELs and remove the server identity

Issue: #38 (epic #45). Contract: `docs/docs/security-design.md` (design + "Rulings after the
design") and the Lean model `lean/KelGroups/Sovereign/*.lean` (#37). Code follows the model;
a divergence is a question to the desk, never a silent fork.

## Story

As a member, I submit my inception and my rotations to the server and anyone can fetch my KEL;
the server checks KERI rules on every append, requires a next-key commitment, admits a rotation
on KERI validity alone, and holds no key of its own.

## Requirements

- R1 Hosting (Lean `host`): an inception is hosted iff its prefix is not hosted and it is KERI
  valid (R3). Its prefix is its own SAID. A hosted KEL starts with exactly that inception.
- R2 Rotation (Lean `rotate`): a rotation is appended iff it is KERI valid against the KEL it
  extends (R3) and its `p` is the digest of the KEL tip. It changes no other KEL and no group
  state (`rotate_effect`). No group condition is consulted.
- R3 KERI validity on append, for every event kind:
  - R3a the event's `d` is its SAID (keri-hs SAID rule); an inception's `i` equals its `d`;
  - R3b `p` is the digest of the KEL tip, `s` is the tip's `s` + 1, `i` is the KEL prefix
    (rotation, interaction);
  - R3c mandatory pre-rotation: inception and rotation carry a non-empty next-key commitment
    `n` with 1 <= `nt` <= |`n`|, and 1 <= `kt` <= |`k`|;
  - R3d a rotation reveals the committed keys: its `k` matches the previous establishment
    event's `n`, count and every digest;
  - R3e signatures (indexed, over the keri-hs canonical serialization) meet the threshold of
    the keys that control the event: inception and rotation by their own `k` (a rotation is
    signed by the revealed next keys); interaction by the current keys (last establishment
    event's `k`);
  - R3f no witnesses (`b` empty, `bt` 0): the server cannot check receipts.
- R4 Interaction events are part of a member KEL and the R3 rule covers them (used by group
  admission, #39). In this ticket no endpoint accepts them.
- R5 A refused submission stores nothing. An accepted one is durable: visible to fetch and
  identical after the server reopens its database.
- R6 Stored KELs are not trusted: opening the database re-checks every stored KEL with the R3
  rule and refuses to open on a violation.
- R7 No server identity: no server keypair is generated or stored, no server inception (old L1
  event 0), no `server_identity` table, no `export-key`/`import-key` commands, no `serverKey`
  in `/info`. Clean break: no migration of existing databases.
- R8 Endpoints: `POST /kel` submits an inception or a rotation; `GET /kel/<prefix>` returns
  the hosted KEL, oldest first, each event with its signatures, as submitted.
- R9 The old group path (`/events`, `/condition`, `/stream`, bootstrap, voting, integrated
  store) keeps compiling and passing its tests without the server key: its first stored event
  is now the first member submission. It is replaced by #39/#40, not here.

## Invariants (acceptance rows marked A1–A4 are the issue's)

| ID | Holds when | Fails when |
|---|---|---|
| INV-38-ICP-NEXT (A1) | inception without next-key commitment (`n` empty or `nt` 0) refused, nothing stored | it is hosted |
| INV-38-ROT-REVEAL (A2) | rotation whose `k` does not match the prior `n` (wrong key, wrong count) refused, nothing stored | it is appended |
| INV-38-OLD-KEY (A3) | after an accepted rotation, an event signed with the superseded key (a rotation; an interaction at the R3 rule) refused | it is appended / passes the rule |
| INV-38-ROT-SIGNER | a rotation signed by the prior current key instead of the revealed keys refused | it is appended |
| INV-38-ROT-NEXT | a rotation without a next-key commitment refused | it is appended |
| INV-38-SAID | event whose `d` is not its SAID, or inception whose `i` != `d`, refused | accepted |
| INV-38-SIG | missing, wrong-key, under-threshold, or altered-event signatures refused | accepted |
| INV-38-TIP | rotation with `p` not the tip digest, `s` not tip+1, or foreign `i` refused | appended |
| INV-38-HOST-ONCE | inception of an already hosted prefix refused (identical resend included), KEL unchanged | a second inception lands or the KEL changes |
| INV-38-UNHOSTED | rotation for an unhosted prefix refused | accepted |
| INV-38-ROT-FRAME | an accepted rotation changes only its own KEL; other KELs and the group store unchanged | anything else changes |
| INV-38-ATOMIC | every refusal leaves database and in-memory state unchanged; every acceptance is visible to fetch and survives reopen | partial or lost writes |
| INV-38-LOAD | reopening refuses a database holding a KEL that breaks the R3 rule | it opens |
| INV-38-IXN-ENDPOINT | an interaction submitted to `POST /kel` refused, nothing stored | stored |
| INV-38-FETCH | `GET /kel/<prefix>` returns exactly the hosted events and signatures, oldest first; 404 when unhosted | anything else |
| INV-38-NO-SERVER-KEY (A4) | a freshly opened database has no key table and no row; `/info` has no `serverKey`; the key commands are gone | key material is generated or stored |
| INV-38-OLD-PATH | the old group path's suites pass with only the event-numbering and server-signer adaptations | any other behaviour change |

Each acceptance row A1–A4 has two layers: the pure R3 rule and the HTTP endpoint. Every other
row has at least one executed check. Each check has been seen to fail (RED evidence).
Test descriptions carry the invariant ID verbatim (the gate filters on it).

## Lean correspondence (rung 0/1; conformance machinery is not climbed here)

| Lean (`KelGroups.Sovereign`) | Haskell realization |
|---|---|
| `Ident`, `Event.icp/rot/ixn`, `State.kel` | KEL prefix, keri-hs `Event`, hosted KEL map |
| `icpOk`, `rotOk` | the R3 rule (abstract in Lean) |
| `host` (unhosted ∧ `icpOk`) | hosting an inception |
| `rotate` (`rotOk` ∧ `p` = `tip`) | appending a rotation |
| `tip`, `hosted` | digest of last event; prefix has a KEL |
| `rotate_effect` | INV-38-ROT-FRAME |
| `step` leaves state unchanged on refusal | INV-38-ATOMIC |

## Out of scope (named residuals)

- Group genesis and admission of interactions (#39); core membership (#40).
- Read access: `GET /kel/<prefix>` is open; member-only reads with proof of key possession are #44.
- Client signing/custody (#41, #42). keri-hs `Kel.Append` checks rotation signatures against the
  prior keys (not KERI's revealed keys) and does not require a next-key commitment, so the R3
  rule is kelgroups' own, built on keri-hs event types, serialization, SAID, pre-rotation and
  signature primitives.
- Old Lean modules (`KEL`, `KELInvariants`, ...) still describe the old L1; untouched.
