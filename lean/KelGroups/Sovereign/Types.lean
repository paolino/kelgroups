/-
  KelGroups.Sovereign.Types — member KEL events, group actions, and the
  explicit cryptographic assumptions every definition is parameterised by.

  Digests and signatures are the scalar types of `KERI.Crypto`. The event
  shapes of `KERI.Event` are not reused: `KELEvent` has one uniform
  `priorDigest` and a `Key` signer, and `EventPayload.Ixn` anchors only a
  digest list, so neither can carry a group action's group id, payload and
  `prev`.
-/
import KERI.Crypto

namespace KelGroups.Sovereign

open KERI.Crypto

/-- A member identifier: the prefix (SAID) of a hosted KEL. -/
abbrev Ident := SAID

/-- A group identifier: the SAID of the group's genesis action. -/
abbrev GroupId := SAID

/-- Group action payload. Opaque to the core except the membership vocabulary. -/
inductive Payload where
  | genesis
  | add (x : Ident)
  | remove (x : Ident)
  | grant (x : Ident)
  | revoke (x : Ident)
  | leave
  /-- Application data, opaque to the core. -/
  | app (data : Nat)
  deriving DecidableEq, Repr

/-- A group action: an interaction event in the signer's own KEL. `p` links
    the signer's KEL, `prev` links the group chain (none at genesis). -/
structure Action where
  signer : Ident
  gid : GroupId
  p : Digest
  payload : Payload
  prev : Option Digest
  sig : Signature
  deriving DecidableEq, Repr

/-- Inception of a member KEL. Key material and next-key commitment are the
    opaque `body`, judged only by the abstract KERI validity predicate. -/
structure Inception where
  pfx : Ident
  body : Nat
  deriving DecidableEq, Repr

/-- Rotation of a member KEL; `body` is opaque as for inception. -/
structure Rotation where
  pfx : Ident
  p : Digest
  body : Nat
  deriving DecidableEq, Repr

/-- An event of a member KEL. -/
inductive Event where
  | icp (e : Inception)
  | rot (r : Rotation)
  | ixn (a : Action)
  deriving DecidableEq, Repr

/-- The KERI `p` link of an event; inception has none. -/
def Event.p : Event → Option Digest
  | .icp _ => none
  | .rot r => some r.p
  | .ixn a => some a.p

/-- Every cryptographic assumption of the model, as data plus named
    properties. Nothing here is a Lean `axiom`; theorems take it as a
    parameter. -/
structure Assumptions where
  /-- Digest of a member KEL event. -/
  digest : Event → Digest
  /-- SAID of an action, as used for a genesis action's group id. -/
  said : Action → SAID
  /-- Signature validity of a group action. -/
  sigOk : Action → Bool
  /-- KERI validity of an inception. -/
  icpOk : Inception → Bool
  /-- KERI validity of a rotation against the KEL it extends. -/
  rotOk : List Event → Rotation → Bool
  /-- Distinct events have distinct digests. -/
  digest_inj : ∀ e e', digest e = digest e' → e = e'
  /-- No event carries its own digest as its `p`. -/
  no_self_p : ∀ e, e.p ≠ some (digest e)
  /-- No group action carries its own digest as its `prev`. -/
  no_self_prev : ∀ a : Action, a.prev ≠ some (digest (.ixn a))

end KelGroups.Sovereign
