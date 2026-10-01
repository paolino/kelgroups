# 37 — Lean model of admission, group chain and core membership

Issue: #37 (epic #45). Source of truth: the security design page
`docs/docs/security-design.md` (accepted design + "Rulings after the design") and the
rulings recorded below. Lean governs the Haskell (#38–#40) and client (#41, #42, #44).

## Story

As the implementer of the server and client, I have a Lean model of member KELs, group
actions and admission whose theorems state the guarantees the design promises, so the code
follows one proved contract.

## Requirements

- R1 Member KELs: each member identifier has a hosted KEL (inception first), extended by
  rotations and by group actions (`ixn`) of any group.
- R2 Group action fields: group id, KERI `p`, payload, `prev`. Payload is opaque except the
  core vocabulary: genesis, add, remove, grant admin, revoke admin, leave.
- R3 Admission iff: signature valid; `p` is the signer's KEL tip; `prev` is the current head
  of the action's group; signer is a current member, or the action is the genesis; core
  membership rules hold. Admission appends to the signer's KEL and advances that group's head
  in one step; a refusal stores nothing.
- R4 Genesis: `prev` = none, payload = genesis, group id = the action's own SAID; refused if a
  group with that id exists. The signer becomes the sole member and sole admin.
- R5 Rotations append to the member KEL on an abstract KERI-validity predicate and change no
  group head. `p` is the KEL tip across all groups: an admitted action or rotation of a member
  makes that member's in-flight action (in any group) stale.
- R6 Membership (rulings Q-001/A-001):
  - add x: signer admin; x not a current member; x's KEL hosted. Re-adding an identifier that
    was removed or left is allowed.
  - remove x: signer admin; x a current member (may be an admin, may be the signer).
  - grant x: signer admin; x a current member and not admin.
  - revoke x: signer admin; x admin.
  - leave: any current member, for itself.
  - Last-admin guard: no admitted action leaves a group with at least one member and no admin.
    The last admin may leave only when it is the sole member (group becomes empty);
    self-demotion of the last admin is refused in every case.
- R7 Digests and signatures are abstract. Every assumption on them is a field of an explicit
  structure passed to the theorems (digest/SAID injectivity, no action embeds its own digest,
  opaque signature / KERI validity predicates) — never a Lean `axiom`.

## Theorems (issue #37) and anchors

| ID | Statement (meaning; exact Lean statement is the commit owner's, as strong as this) |
|---|---|
| T1 | For every state and action: admission either refuses with the state unchanged, or yields a state whose signer KEL is the old one extended by exactly that action, every other KEL unchanged, that group's head = the action's digest, every other group's head (and chain) unchanged. |
| T2 | An admitted action's `prev` equals its group's head before admission; and on every reachable state, each group's admitted chain is a single `prev`-linked line ending at genesis (`prev` none). |
| T3 | On every reachable state, an action already in a group's chain is refused if submitted again (identical bytes) — at any later time, not only immediately. |
| T4 | An action whose `p` is not the signer's current KEL tip is refused; in particular, an action built against tip t is refused after any admitted rotation (or other admitted action) of that signer. |
| T5 | Every admitted non-genesis action's signer is a current member before admission; every admitted add/remove/grant/revoke has an admin signer; leave concerns only its signer. A removed member's later actions are refused. |
| T6 | On every reachable state, no group has members and no admin (and admins ⊆ members). |
| T0 | Anti-vacuity: admission is exactly R3 — every action satisfying all R3 conditions is admitted (completeness), and every admitted action satisfied every R3 condition, signature validity included (soundness); plus a concrete instantiated trace in which genesis, add, a member's opaque action and a rotation are admitted and a stale action, a replay, an action with an invalid signature and a last-admin self-demotion are refused, checked by evaluation. |

## Out of scope (named residuals)

- Old Lean modules (`lean/KelGroups/{Basic,KEL,Validate,Transitions,...}.lean`) still model the
  old design and stay untouched: the Haskell still corresponds to them; their removal belongs
  to the ticket that replaces that Haskell.
- Member-side local validation ("refuse to sign on a gap") — owned by #41.
- Read-access ruling (#44), fork/withholding detection, multi-signature, host replacement.
