/-
  KelGroups.Sovereign.Membership — membership derived from a group chain by
  replaying its core actions, and the core membership rules.
-/
import KelGroups.Sovereign.Types

namespace KelGroups.Sovereign

/-- Members and admins of a group. -/
structure Roster where
  members : List Ident
  admins : List Ident
  deriving Repr

/-- Effect of one admitted action on the roster. -/
def applyCore (r : Roster) (a : Action) : Roster :=
  match a.payload with
  | .genesis => ⟨[a.signer], [a.signer]⟩
  | .add x => ⟨x :: r.members, r.admins⟩
  | .remove x => ⟨r.members.filter (· != x), r.admins.filter (· != x)⟩
  | .grant x => ⟨r.members, x :: r.admins⟩
  | .revoke x => ⟨r.members, r.admins.filter (· != x)⟩
  | .leave => ⟨r.members.filter (· != a.signer), r.admins.filter (· != a.signer)⟩
  | .app _ => r

/-- Membership of a chain: replay of its actions in admission order. -/
def roster (chain : List Action) : Roster :=
  chain.foldl applyCore ⟨[], []⟩

/-- Last-admin guard: the roster after the action has no members, or has an admin. -/
def guardOk (r : Roster) : Bool :=
  r.members.isEmpty || !r.admins.isEmpty

/-- Core membership rules for an action against the chain it would extend.
    `hosted x` says x's KEL is hosted. The rule "signer is a current member,
    or the action is the genesis" is admission's, not repeated here. -/
def membershipOk (C : Assumptions) (hosted : Ident → Bool)
    (chain : List Action) (a : Action) : Bool :=
  let r := roster chain
  guardOk (applyCore r a) &&
  match a.payload with
  | .genesis => chain.isEmpty && a.gid == C.said a
  | .add x => r.admins.contains a.signer && !r.members.contains x && hosted x
  | .remove x => r.admins.contains a.signer && r.members.contains x
  | .grant x => r.admins.contains a.signer && r.members.contains x && !r.admins.contains x
  | .revoke x => r.admins.contains a.signer && r.admins.contains x
  | .leave => true
  | .app _ => true

end KelGroups.Sovereign
