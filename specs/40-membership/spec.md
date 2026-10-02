# 40 — Core membership actions and admin rules

Issue: #40 (epic #45). Contract: `docs/docs/security-design.md` ("Group membership" and
"Rulings after the design") and the Lean model `lean/KelGroups/Sovereign/*.lean` (#37),
in particular `Membership.lean` (`Roster`, `applyCore`, `roster`, `guardOk`,
`membershipOk`) and `Admission.lean` (`Admissible`). Code follows the model; a divergence is
a question to the desk, never a silent fork. Base: the admission substrate of #39
(`KelGroups.Group`, `KelGroups.Kel.Store`, `POST /actions`).

## Story

As a group admin, I add and remove members and grant and revoke admin with actions in my own
KEL; any member leaves by its own action; the group never ends up with members and no admin.
The old passphrase bootstrap and majority voting are gone with the whole L1/L2 group path.

## Requirements

- R1 Payloads (Lean `Payload`): `genesis`, `add x`, `remove x`, `grant x`, `revoke x`,
  `leave`, `app` (opaque). Wire form in data-model D1.
- R2 Roster (Lean `applyCore`, `roster`): replay of the chain in admission order, exactly as
  Lean: genesis → signer sole member and admin; add x → x member; remove x → x neither member
  nor admin; grant x → x admin; revoke x → x not admin; leave → signer neither member nor
  admin; app → unchanged.
- R3 Membership rule (Lean `membershipOk`), checked at admission after the #39 conditions:
  - add x: signer is an admin, x is not a member, x's KEL is hosted;
  - remove x: signer is an admin, x is a member;
  - grant x: signer is an admin, x is a member and not an admin;
  - revoke x: signer is an admin, x is an admin;
  - leave, app: no extra condition (the signer is a current member by #39 R3c);
  - every payload: the last-admin guard (Lean `guardOk (applyCore r a)`): after the action the
    roster has no members, or has an admin.
  Consequences fixed by the desk: the sole-member exception covers leave (and an admin's
  `remove` of itself) only — the last admin never self-demotes, not even as sole member.
- R4 A removed (or departed) member's admitted actions stay in the chain and verify on replay
  and reopen; its later actions are refused as from a non-member (#39 R3c). A removed member
  may be added again.
- R5 Reopen (extends #39 R6): rebuilding chains from the hosted KELs applies the full
  admission conditions of R3 at every position (hosted = present in the loaded KELs) and
  refuses to open on a violation.
- R6 Old path removed (desk ruling t39 A-001; swap rule): `POST /events`, `GET /events`,
  `GET /condition`, `GET /stream`, `GET /info` and the `?key=` guard; modules
  `KelGroups.{Store,Fold,State,Validate,Event,Bootstrap,Trivial,Types,Server.JSON}` and
  their tests; `mkApp`/`ServerEnv` in `KelGroups.Server`. The member KEL
  store owns the SQLite connection: it opens the database file itself and creates only its
  own table. Old tables in an existing file are neither read nor dropped (clean break, no
  migration). `KelGroups.Vote.{Types,State}` (the held #30 substrate, merged with #35, importing
  only `Data.Text`) and `specs/30-vote-substrate` are not part of the old path and are kept
  unchanged. The executable takes `<port> <db>`; `just serve`/`restart` and the docker image
  follow. Static files of the client are still served as the fallback.
- R7 Lean: the old model modules (`KelGroups.{Basic,KEL,Validate,Transitions,Invariants,
  FoldInvariants,KELInvariants,TransitionInvariants,ValidateInvariants}`) are deleted;
  `lean/KelGroups.lean` imports only `KelGroups.Sovereign`; `lean/KelGroups/Sovereign/**` is
  untouched; `just lean` stays green.
- R8 Docs: `docs/docs/implementation.md` describes the server as it is after this ticket
  (membership section; old-path sections removed); `docs/docs/design.md` and
  `docs/docs/properties.md` (the deleted L1/L2 design and its invariants) are deleted with
  their nav entries; README and `docs/docs/index.md` lose old-path claims and show the new
  command line.

## Invariants (A1–A4 are the issue's acceptance rows; all BLOCKING)

| ID | Holds when | Fails when |
|---|---|---|
| INV-40-ADMIN (A1) | a current non-admin member's add, remove, grant or revoke — otherwise valid — is refused 403 `notAnAdmin`; nothing stored | admitted or stored |
| INV-40-LAST-ADMIN (A2) | with other members and no other admin, the last admin's leave, revoke of itself, and remove of itself are refused 409 `lastAdmin`; as sole member its revoke of itself is refused and its leave is admitted (roster empty); with a second admin the same leave/revoke is admitted | any refused case admitted, or an admitted case refused |
| INV-40-ADD-HOSTED (A3) | an admin's add of an identity with no hosted KEL is refused 404 `memberNotHosted`; after that KEL is hosted the add, re-signed, is admitted | admitted unhosted, or refused once hosted |
| INV-40-REMOVED (A4) | after x is removed, x's earlier actions are still in the chain, the roster replays to the same result, and reopen rebuilds the identical chain; x's new action (correct `p`, `prev`) is refused 403 `notAMember` | an earlier action dropped or failing replay/reopen, or the new one admitted |
| INV-40-ROSTER | for every payload the admitted action changes the roster exactly as R2 and nothing else | any other roster change |
| INV-40-STATE | add of a member, remove of a non-member, grant of a non-member or of an admin, revoke of a non-admin are refused 409 (`alreadyMember`, `targetNotMember`, `alreadyAdmin`, `targetNotAdmin`); nothing stored | admitted or stored |
| INV-40-LEAVE | a non-admin member's leave is admitted; its later actions are refused 403; a non-member's leave is refused 403 | otherwise |
| INV-40-GUARD | over generated sequences of signed actions admitted through `admit`, every chain's roster has no members or an admin, and every admin is a member (Lean `admin_guard`); every admitted action satisfies R3 at its position | a reachable roster with members and no admin, or an admin not a member |
| INV-40-SHAPE | membership payloads with a missing or extra key, or a non-string member, are refused 400 `notAGroupAction`; nothing stored | accepted |
| INV-40-LOAD | a database whose history uses every payload reopens to identical chains and rosters; one holding a KERI-valid interaction that breaks R3 at its position (non-admin add, last-admin revoke) refuses to open | otherwise |
| INV-40-ORDER | with two violations at once, the status is the one of the earlier check in data-model D4 order (at least: member+admin, admin+target state, prev+admin, target state+guard) | the later check decides |
| INV-40-WRITE500 | a store write failure during `POST /actions` answers 500 and stores nothing (memory and reopen) | 200, or anything stored |
| INV-40-GONE | `POST /events`, `GET /events`, `GET /condition`, `GET /stream`, `GET /info` (with and without `?key=`) answer 404 from the server application | any other answer |
| INV-40-SCHEMA | a freshly opened database contains only the member KEL table and no row; opening a file that also holds old-path tables succeeds and leaves them untouched | other tables created, or old tables read/dropped |
| INV-40-CLI | the executable with `<port> <db>` arguments serves `POST /kel`; with the old three arguments it prints usage and exits | otherwise |

Layers in test descriptions: A1–A3 rows and SHAPE carry `/rule` and `/http`; REMOVED carries
`/rule`, `/store` and `/http`; LOAD, SCHEMA, WRITE500 are `/store` or `/http` as written;
GUARD and ROSTER are `/rule`; GONE and ORDER are `/http`. Descriptions carry the ID (and
layer) verbatim; the gate filters on them. Expected outcomes come from this table and D4, not
from the code. Every check is seen to fail (RED from the behaviour absent or a deliberate
fault in the RULE, not the test). Events are built by legitimate signing with real Ed25519
keys and commitments (the #38/#39 fixtures), never by seeding stored rows — except LOAD and
SCHEMA, which write rows or tables on purpose.

Kept invariants: every `INV-38-*` and `INV-39-*` ID with a test at the base keeps at least one
example and no failure, except `INV-38-OLD-PATH` and `INV-38-NO-SERVER-KEY/http` (`/info`),
deleted with their subject. Kept tests that used the old store are re-pointed at the member
KEL store, not weakened.

## Lean correspondence (rung 0/1)

| Lean (`KelGroups.Sovereign`) | Haskell realization |
|---|---|
| `Payload.add/remove/grant/revoke/leave` | anchor payloads (D1) |
| `applyCore`, `roster`, `Roster` | same names, R2 |
| `guardOk`, `membershipOk` | same names, R3; the refusal says which condition failed |
| `Admissible` conjunct `membershipOk` | admission after #39's conditions, D4 order |
| `admitted_admin_signer`, `nonmember_refused`, `removed_not_member` | INV-40-ADMIN, INV-40-REMOVED, INV-40-LEAVE |
| `leave_only_signer`, `member_gained_only_by_add` | INV-40-ROSTER |
| `admin_guard` | INV-40-GUARD |
| `chain_is_line` + membership at each position | R5, INV-40-LOAD |

## Out of scope (named residuals)

- Held app-level work #29, #30, #33 is not resumed or adapted here. Its substrate
  `KelGroups.Vote.*` (#35) stays in the library, used by nothing in the server; its fate is an
  operator decision outside this milestone. The old-path modules it was built beside are gone.
- Client: `client/kelgroups-client` `Api.purs` and the trivial UI call the removed endpoints;
  they break at runtime until #41/#42. Client CI (compile + unit specs, no HTTP) stays green.
- `docs/docs/roadmap.md` still describes the pre-#40 design; not refreshed here.
- The docker image command (`nix/docker-image.nix`) has no CI check.
- Second-genesis refusal stays checked at the pure rule: a second genesis of an existing id is
  the same event (its id is its own `d`), so over HTTP it is a retry or a stale `p`.
- Read access to chains (#44).
