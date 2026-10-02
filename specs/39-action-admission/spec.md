# 39 — Group genesis and atomic action admission

Issue: #39 (epic #45). Contract: `docs/docs/security-design.md` (design + "Rulings after the
design") and the Lean model `lean/KelGroups/Sovereign/*.lean` (#37). Code follows the model;
a divergence is a question to the desk, never a silent fork. Member KEL hosting (#38) is the
base: `KelGroups.Kel` (rule), `KelGroups.Kel.Codec`, `KelGroups.Kel.Store`.

## Story

As a member, I create a group with a genesis action in my own KEL and then act in it with
interaction events that pin my KEL tip and the group head; the server admits each action
atomically or stores nothing, a lost response is retried with identical bytes, and a stale
action is refused so I re-sign it.

## Requirements

- R1 Group action (Lean `Action`): an interaction event (`ixn`) in the signer's hosted KEL
  whose `a` holds exactly one group anchor (data-model D1) naming group id, payload and `prev`.
  Signer = the event's `i`; `p` = the event's `p`.
- R2 Genesis: anchor payload `genesis`, no group id field, no `prev` (Lean `prev = none`).
  Its group id is the event's own `d` (the SAID of that event; Lean `gid = said a`). The
  creator becomes the sole member and admin (Lean `applyCore .genesis`). Refused if a chain
  already exists for that id (Lean `membershipOk .genesis`: `chain.isEmpty`).
- R3 Admission (Lean `Admissible`): admitted iff
  - R3a the signer's KEL is hosted and the event passes the #38 KEL rule for an interaction
    (SAID, `i`/`p`/`s` extend the tip, signatures by the current keys meet the threshold) —
    this is Lean `sigOk` and `tip = some p`;
  - R3b `prev` equals the group head (Lean `head`), none for a genesis;
  - R3c the signer is a current member (Lean `roster`), or the action is the genesis;
  - R3d the core membership rule holds (Lean `membershipOk`): in this ticket the payloads are
    `genesis` and `app` only; `app` is opaque and always passes. The other core payloads are
    #40 and are not decodable here.
- R4 Atomicity (Lean `State.append`, `admit_atomic`): an admitted action is appended to the
  signer's KEL and advances its group's head in one step; a refused one stores nothing
  (database and memory). No partial state is observable, including after a crash or an
  asynchronous exception at any point of the admission.
- R5 Retry: a submission whose event bytes and signatures are identical to an event already in
  the signer's KEL returns the same success body as its admission and stores nothing, at any
  later time. Any other submission is judged by R3; a stale one is refused with 409.
- R6 The chain is the `prev` links. The server's per-group head is an index derived from the
  admitted interactions and is not persisted as separate evidence. Opening the database
  rebuilds every chain from the hosted KELs and refuses to open when a chain is not one
  `prev`-linked line from its genesis (Lean `ChainLine`) or an action's signer was not a member
  at its position.
- R7 Endpoint: `POST /actions` takes one signed interaction (#38 wire form, data-model D3) and
  answers per data-model D4. Admissions and member KEL submissions (`POST /kel`) are serialized
  by one lock, so a rotation and an action of one member never interleave.
- R8 Coexistence (desk A-001, option B): the old L1/L2 group path (`/events`, `/condition`,
  `/stream`, bootstrap, voting, the old store) stays unchanged, compiling and tested. The new
  admission code imports none of its modules, so #40 deletes it mechanically.

## Invariants (acceptance rows A1–A4 are the issue's; all BLOCKING)

| ID | Holds when | Fails when |
|---|---|---|
| INV-39-TAMPER (A1) | a signed action with its group id, payload, `p` or `prev` altered — (i) `d` left as signed (422), (ii) `d` recomputed (422 for group id, payload, `prev`; 409 for `p`, whose tip check precedes signatures, D4 order) — is refused; KEL, chain and database unchanged | admitted, or anything stored |
| INV-39-LINK (A1) | an action correctly signed with `p` not the signer's tip (409), `prev` not the head (409), or a group id with no chain (404) is refused; nothing stored | admitted or stored |
| INV-39-CONTEND (A2) | two actions signed against one head, submitted concurrently, repeated: exactly one 200 and one 409 each round; the refused one, re-signed against the new tip and head, is admitted | both or neither admitted, or the re-signed one refused |
| INV-39-RETRY (A3) | identical bytes resubmitted after admission (immediately, and after later actions) return 200 with the same body; the event is stored once; the same event with a different signature set is not a retry and is refused | a second store, a different body, or a refusal of the identical retry |
| INV-39-ATOMIC (A4) | a write failure or an asynchronous exception at any point of an admission leaves the KEL tip and the group head both advanced or both unchanged, in memory and after reopen; an admitted action survives reopen | one advanced without the other |
| INV-39-GENESIS | a genesis by a hosted signer is admitted; group id = head = its `d`; roster = signer as sole member and admin | anything else |
| INV-39-REGENESIS | a genesis whose group id already has a chain is refused (409), at the pure rule | admitted |
| INV-39-MEMBER | an action by a hosted non-member, with correct `p` and `prev`, is refused (403); nothing stored | admitted or stored |
| INV-39-UNHOSTED | an action whose signer has no hosted KEL is refused (404) | admitted |
| INV-39-SHAPE | an `ixn` whose `a` is not exactly one well-formed anchor (none, two, extra keys, unknown payload tag, a genesis carrying group id or `prev`) is refused (400); a non-`ixn` at `POST /actions` is refused (422); `POST /kel` still refuses every `ixn` | accepted or stored |
| INV-39-STALE-ROT | an action signed before an admitted rotation of its signer is refused (409); re-signed with the new keys and tip it is admitted | the stale one admitted, or the re-signed one refused |
| INV-39-FRAME | an admission changes only the signer's KEL and its group's chain; a rotation changes no chain | any other KEL or chain changes |
| INV-39-LOAD | reopening rebuilds identical chains and heads; a database holding a KERI-valid interaction that breaks R6 (unresolved `prev`, two actions with one `prev`, non-member signer, not a group anchor) refuses to open | it opens |

A1–A3 rows have two layers in test descriptions: `/rule` (pure decision; `/store` for
CONTEND and RETRY) and `/http`. ATOMIC is `/store`. Test descriptions carry the ID (and layer)
verbatim; the gate filters on them. Expected outcomes come from this table, not from the code.
Every check is seen to fail (RED from the behaviour absent, or a fault in the rule, not the
test). Events are built by legitimate signing with real Ed25519 keys and commitments (the #38
fixtures), never by seeding stored rows — except INV-39-LOAD, which stores a row on purpose.

## Lean correspondence (rung 0/1)

| Lean (`KelGroups.Sovereign`) | Haskell realization |
|---|---|
| `Action` (signer, gid, p, payload, prev, sig) | a signed `ixn` with one group anchor |
| `Payload.genesis`, `Payload.app` | anchor payloads `genesis`, `app` (others: #40) |
| `said a` for a genesis | the genesis event's `d`; no group id field is signed at genesis |
| `State.kel`, `State.chain` | hosted KELs; chains derived from admitted `ixn`s |
| `tip`, `head`, `roster`, `applyCore` | same names |
| `Admissible`, `admit` | R3, the admission decision |
| `State.append`, `admit_atomic` | R4, INV-39-ATOMIC, INV-39-FRAME |
| `admitted_prev_is_head`, `chain_is_line` | R3b, R6, INV-39-LOAD |
| `stale_p_refused`, `stale_after_rotation`, `stale_after_action` | INV-39-LINK, INV-39-STALE-ROT, INV-39-CONTEND |
| `nonmember_refused`, `admitted_signer_member` | INV-39-MEMBER |
| `rotate_effect` | INV-39-FRAME (rotation side) |
| `resend_refused` / `replay_refused` | the step is refused and the state unchanged; R5 answers an identical resend with its original success body instead of an error. State effect identical to the model; only the response differs |

## Out of scope (named residuals)

- Core membership payloads (add, remove, grant, revoke, leave), admin rules, last-admin guard:
  #40, which also deletes the old L1/L2 group path (desk A-001).
- Read access to chains and heads (members only, challenge-signed): #44. No group read
  endpoint is added here; `GET /kel/<prefix>` stays open (#38 residual).
- Client validation, replay and signing: #41, #42.
