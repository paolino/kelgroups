/-
  KelGroups.Sovereign.Admission — server state, hosting, rotation, admission
  of group actions, and the states reachable from the empty server.
-/
import KelGroups.Sovereign.Membership

namespace KelGroups.Sovereign

open KERI.Crypto

/-- Server state: hosted member KELs (oldest event first) and, per group id,
    the admitted chain in admission order. An empty KEL is an unhosted
    identifier; an empty chain is an absent group. -/
structure State where
  kel : Ident → List Event
  chain : GroupId → List Action

/-- The server before anything is hosted. -/
def State.empty : State := ⟨fun _ => [], fun _ => []⟩

/-- Point update of a function. -/
def upd {β : Type} (f : Nat → β) (i : Nat) (v : β) : Nat → β :=
  fun j => if j = i then v else f j

section
variable (C : Assumptions)

/-- Tip of a KEL: digest of its last event; none when unhosted. -/
def tip (kel : List Event) : Option Digest :=
  kel.getLast?.map C.digest

/-- Head of a group: digest of its latest admitted action; none when absent. -/
def head (chain : List Action) : Option Digest :=
  chain.getLast?.map (fun a => C.digest (.ixn a))

/-- Whether an identifier's KEL is hosted. -/
def hosted (s : State) (x : Ident) : Bool :=
  !(s.kel x).isEmpty

/-- Host a new KEL from a KERI-valid inception of an unhosted identifier. -/
def host (s : State) (e : Inception) : Option State :=
  if (s.kel e.pfx).isEmpty && C.icpOk e then
    some { s with kel := upd s.kel e.pfx [.icp e] }
  else none

/-- Append a KERI-valid rotation whose `p` is the KEL tip. No group changes. -/
def rotate (s : State) (r : Rotation) : Option State :=
  if C.rotOk (s.kel r.pfx) r && tip C (s.kel r.pfx) == some r.p then
    some { s with kel := upd s.kel r.pfx (s.kel r.pfx ++ [.rot r]) }
  else none

/-- The admission conditions: signature valid; `p` is the signer's KEL tip;
    `prev` is the group head; signer a current member or the action a
    genesis; core membership rules hold. -/
def Admissible (s : State) (a : Action) : Prop :=
  C.sigOk a = true ∧
  tip C (s.kel a.signer) = some a.p ∧
  head C (s.chain a.gid) = a.prev ∧
  (a.payload = .genesis ∨ a.signer ∈ (roster (s.chain a.gid)).members) ∧
  membershipOk C (hosted s) (s.chain a.gid) a = true

instance (s : State) (a : Action) : Decidable (Admissible C s a) := by
  unfold Admissible; infer_instance

/-- The state after admitting `a`: appended to its signer's KEL and to its
    group's chain, in one step. -/
def State.append (s : State) (a : Action) : State :=
  { kel := upd s.kel a.signer (s.kel a.signer ++ [.ixn a])
    chain := upd s.chain a.gid (s.chain a.gid ++ [a]) }

/-- Admission: the extended state, or none (refused, nothing stored). -/
def admit (s : State) (a : Action) : Option State :=
  if Admissible C s a then some (s.append a) else none

/-- An operation submitted to the server. -/
inductive Op where
  | host (e : Inception)
  | rotate (r : Rotation)
  | admit (a : Action)

/-- One server step; a refused operation leaves the state unchanged. -/
def step (s : State) : Op → State
  | .host e => (host C s e).getD s
  | .rotate r => (rotate C s r).getD s
  | .admit a => (admit C s a).getD s

/-- `Steps s t`: t follows from s by zero or more server steps. -/
inductive Steps : State → State → Prop
  | refl (s : State) : Steps s s
  | tail {s t : State} (op : Op) : Steps s t → Steps s (step C t op)

/-- States reachable from the empty server. -/
def Reachable (s : State) : Prop := Steps C State.empty s

end

end KelGroups.Sovereign
