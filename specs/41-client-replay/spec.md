# 41 — Client: local validation, replay and sync of the group

Issue: #41 (epic #45). Contract: `docs/docs/security-design.md` ("Admission and retry", "Group
chain and replay", "Rulings after the design") and the Lean model `lean/KelGroups/Sovereign/*.lean`
(#37): `Line`/`ChainLine`, `KelLine`, `Roster`, `applyCore`, `roster`, `guardOk`,
`membershipOk`, `Admissible`, `head`, `tip`. The server rule the client re-checks is
`KelGroups.Kel` (KERI rule) and `KelGroups.Group` (`decodeAction`, `extend`, `rebuildChains`).
Code follows the model; a divergence is a question to the desk, never a silent fork.
Desk rulings: t41 A-001 (suffix fetch `GET /kel/:prefix?after=<sn>` and the group index, both
read-only and open until #44); one head per group id; genesis is a core action, group id = its
SAID; `p` is the member's KEL tip across all groups; sole-member exception covers leave only.

## Story

As a member, my client fetches every member KEL of my group from the server, validates each
locally, walks `prev` from the head back to genesis by local lookup and folds the roster. Two
clients with the same KELs see the same group. If any link is missing the client reports the
gap and will not sign. When my action loses the race (409) the client fetches only what is new,
re-validates and signs again against the new head; when a response is lost it resends the same
bytes, and it counts my action as history only once it has seen it admitted.

## Requirements

- R1 Group index (server, non-evidence): `GET /groups/<gid>` answers 200 with the group head and
  every prefix that signed an action of the group or was the target of an `add` (former members
  included), each with its KEL tip; 404 `noSuchGroup` for an unknown id. Wire form data-model D2.
- R2 Suffix fetch (server): `GET /kel/<prefix>?after=<sn>` answers the hosted events with
  `s > sn`, oldest first, in the wire form of `GET /kel/<prefix>`; without `after` the whole KEL
  (unchanged). D3 for the query and its refusals.
- R3 KEL validation (client): every fetched KEL is re-checked with the KERI rule of
  `KelGroups.Kel` (`host`, `rotate`, `appendInteraction`): SAID, inception prefix = SAID and
  `s` = 0, mandatory next commitment, thresholds in range, no witnesses, each later event's
  `i`/`p`/`s` extend the tip, a rotation reveals exactly the committed keys, signatures at
  distinct indices of canonical Ed25519 keys meet the threshold (a rotation also the prior `nt`).
  Any failure refuses the whole sync, naming the prefix and `s` (D5 `KelInvalid`).
- R4 Walk (client): starting from the index head, every `prev` is resolved by local digest lookup
  among the group actions of the validated KELs, back to the genesis whose `d` is the group id
  (Lean `ChainLine`). An unresolved digest — the head itself, any `prev`, or a `p` inside a KEL
  — is a gap (D5 `Gap`): reported with the missing digest, no state is produced. Group actions of
  the group that extend the index head are followed to the line's end (the head moved); a group
  action of the group that is on no single line from genesis is a refusal (D5 `NotOnLine`).
- R5 Fold (client): the roster is Lean `roster` over the walked chain; at each position the
  action must meet the group conditions of Lean `Admissible` as `KelGroups.Group.extend`
  checks them on rebuild: signer a current member, `prev` the head, `membershipOk` with
  `guardOk (applyCore r a)`, an added identity counting as hosted when its KEL is among the
  validated ones. A violation refuses the sync (D5 `RuleViolation`). Result D4.
- R6 Determinism: the group view is a function of the KEL set alone — independent of fetch order,
  client instance and index ordering.
- R7 Signing: an action is signed only against a view from a sync that produced no refusal:
  `p` = the signer's KEL tip as validated from the server, `prev` = the view head, anchor in the
  wire form of #39/#40 (`KelGroups.Group` module header). A sync refusal (gap included) yields
  no signature and sends nothing.
- R8 Submit: `POST /actions`. On no response (transport failure) the client resends the
  identical bytes (bounded attempts) and never re-signs before the outcome is known. On 409
  (`prevNotHead`, `notTipSuccessor`) it refreshes (R9), re-validates, re-walks and signs again
  against the new head and tip. Other refusals are reported, not retried.
- R9 Refresh: the client re-reads the index and, for each known prefix whose tip moved, fetches
  only `?after=<local sn>`; the suffix must chain onto the local tip and validate (else D5
  `HistoryRewritten`); new prefixes are fetched whole. Validated history is never re-fetched or
  rewritten.
- R10 Own history: the signer's own action is part of its KEL history (usable as `p`, counted in
  the view) only once a sync has seen it in the server-hosted KEL and on the chain; a 200 alone
  or a pending submission changes nothing locally.
- R11 Swap: the client modules of the deleted L1/L2 path and their tests are removed
  (plan.md); `kelgroups-trivial` is adapted to the new API as a read-only group viewer (group id
  → sync → head and roster, or the refusal with its gap). Signing UI and key custody are #42.
- R12 Harness: `just e2e-client` (part of `just ci`) runs the client end-to-end suite against the
  real `kelgroups-server` on a fresh database; the suite cannot pass without a server.
- R13 Docs: `docs/docs/implementation.md` describes the two read endpoints and the client
  (validation, walk, fold, sync, gap, retry) as they are after this ticket.

## Invariants (A1–A3 are the issue's acceptance rows; all BLOCKING)

Layers: `/e2e` = PureScript client against the real server over HTTP (adversarial cases through
a transport wrapper over the real server's responses); `/unit` = PureScript client functions on
legitimately signed fixtures; `/http` = Haskell hspec against `kelApp`.

| ID | Holds when | Fails when |
|---|---|---|
| INV-41-SAME (A1) /e2e /unit | two client instances syncing one group (KELs fetched in different orders) produce equal views; /unit: every permutation of a KEL set gives the equal view | views differ, or depend on order |
| INV-41-GAP (A2) /e2e /unit | (a) an interior group action removed from its member KEL in the fetched response, (b) the KEL of a signer of an interior action omitted from the index: the sync reports `Gap` with the missing digest; signing is refused and no `POST` is sent | a view is produced, a signature made, or a request sent |
| INV-41-RETRY (A3) /e2e | the response to an admitted `POST /actions` is lost; the client resends identical bytes, gets the same admission; after sync the action is on the chain exactly once and both clients' views are equal | a second admission, a re-signed variant sent before the outcome is known, or views differ |
| INV-41-RACE /e2e | two clients sign against one head: one admitted, the other gets 409, fetches only `?after=` suffixes of moved KELs, re-signs against the new head and is admitted; final views equal | the loser stalls, re-fetches whole known KELs, or views differ |
| INV-41-KEL /unit | each tampering is refused `KelInvalid` at the right prefix and `s`: bad signature, under-threshold, duplicate index, SAID mismatch, inception prefix ≠ SAID, missing next commitment, rotation not revealing the commitment, wrong `s`, wrong `p` | any tampered KEL accepted |
| INV-41-RULE /unit | valid KELs whose chain holds a non-member's action, a non-admin's add, an add of an unvalidated prefix, or a last-admin leave with other members: `RuleViolation` at that action | a view produced |
| INV-41-LINE /unit | a group action of the group off the line (second action on one `prev`) is refused `NotOnLine`; actions past the index head are followed | accepted, or the moved head ignored |
| INV-41-REWRITE /unit | a refreshed suffix that does not chain onto the local tip, or fails validation, is refused `HistoryRewritten`; local state unchanged | accepted, or local state changed |
| INV-41-OWN /unit /e2e | after a 200 without a sync, and after a lost response, the next signature's `p` is the server-validated tip and the view is unchanged; after a sync showing the action, it is history | a pending action used as `p` or counted |
| INV-41-INDEX /http | index answers the head and every signer and add target with tips (former members included); 404 `noSuchGroup` | a prefix missing, a wrong head or tip |
| INV-41-AFTER /http | `?after=<sn>` answers exactly the events with `s > sn`; no `after` = whole KEL; `after` past the tip = `[]`; a non-canonical value = 400 `badQuery`; unhosted = 404 | other events, or another status |
| INV-41-NOSERVER | the end-to-end suite exits non-zero when given no server URL | it passes |

Each check is seen to fail (RED from the subject absent or a deliberate fault in the subject, not
in the test). Expected outcomes come from this table and the Lean model, never from the client's
own output. Fixtures are built by legitimate signing with real Ed25519 keys and commitments.

## Lean correspondence (rung 1)

| Lean | Client |
|---|---|
| `KelLine`, `tip` | R3 validated KEL, its tip |
| `ChainLine`, `head`, `Line.props` (no repeat, every link resolves) | R4 walk, `Gap`, `NotOnLine` |
| `roster`, `applyCore`, `guardOk`, `membershipOk`, `Admissible` (group part) | R5 fold, `RuleViolation` |
| `admit` refuses stale `p`/`prev` (`stale_p_refused`, `admitted_prev_is_head`) | R8 409 → refresh, re-sign |
| `resend_refused` + server `retried` | R8 identical resend lands once |

Interpretation, not Lean: `hosted` on replay = KEL among the validated ones (as `rebuildChains`).

## Residuals

- Read endpoints (`GET /kel`, `?after=`, `GET /groups`) are open; member-only access is #44.
- A server that serves a consistent stale snapshot (old head with KELs truncated after it) is
  not detectable by replay; freshness is not a protocol guarantee.
- Anchor `app` data is re-serialized by the client as received; data whose JSON form differs
  between aeson and the browser (e.g. `1.0`) fails SAID verification — fail-closed.
