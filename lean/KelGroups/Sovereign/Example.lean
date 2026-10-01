/-
  KelGroups.Sovereign.Example — a concrete instance of the assumptions
  structure (so the theorems' hypotheses are satisfiable) and an evaluated
  trace through admission.
-/
import KelGroups.Sovereign.Admission

namespace KelGroups.Sovereign

open KERI.Crypto

/-- An injective pairing of naturals: `a + b` is recoverable as the integer
    square root, since `a ≤ a + b`. -/
def pair (a b : Nat) : Nat := (a + b) * (a + b) + a

/-- Injective encoding of a list; every element is below the code. -/
def encList : List Nat → Nat
  | [] => 0
  | x :: xs => pair x (encList xs) + 1

def encOpt : Option Nat → Nat
  | none => 0
  | some d => d + 1

def encPayload : Payload → Nat
  | .genesis => encList [0]
  | .add x => encList [1, x]
  | .remove x => encList [2, x]
  | .grant x => encList [3, x]
  | .revoke x => encList [4, x]
  | .leave => encList [5]
  | .app d => encList [6, d]

/-- Events are told apart by list length (2, 3, 6); digest-valued fields come
    first, where they are squared least, to keep codes small. -/
def encEvent : Event → Nat
  | .icp e => encList [e.pfx, e.body]
  | .rot r => encList [r.p, r.pfx, r.body]
  | .ixn a => encList [a.p, encOpt a.prev, a.signer, a.gid, encPayload a.payload, a.sig]

theorem pair_lt {a b t : Nat} (h : a + b < t) : pair a b < t * t := by
  unfold pair
  have h1 : (a + b + 1) * (a + b + 1) ≤ t * t := Nat.mul_self_le_mul_self h
  have h2 : (a + b + 1) * (a + b + 1) = (a + b) * (a + b) + 2 * (a + b) + 1 := by
    simp only [Nat.add_mul, Nat.mul_add, Nat.mul_one, Nat.one_mul]; omega
  generalize (a + b) * (a + b) = q at h2
  omega

theorem pair_inj {a b c d : Nat} (h : pair a b = pair c d) : a = c ∧ b = d := by
  have hst : a + b = c + d := by
    rcases Nat.lt_trichotomy (a + b) (c + d) with hl | he | hg
    · have := pair_lt (b := b) hl; unfold pair at h this
      generalize (c + d) * (c + d) = q at h this; omega
    · exact he
    · have := pair_lt (a := c) (b := d) hg; unfold pair at h this
      generalize (a + b) * (a + b) = q at h this; omega
  unfold pair at h; rw [hst] at h
  generalize (c + d) * (c + d) = q at h
  omega

theorem le_pair_left (a b : Nat) : a ≤ pair a b := by unfold pair; omega

theorem le_pair_right (a b : Nat) : b ≤ pair a b := by
  unfold pair; have := Nat.le_mul_self (a + b); omega

theorem encList_inj : ∀ l l' : List Nat, encList l = encList l' → l = l'
  | [], [], _ => rfl
  | [], _ :: _, h => by simp [encList] at h
  | _ :: _, [], h => by simp [encList] at h
  | x :: xs, y :: ys, h => by
    simp only [encList, Nat.add_right_cancel_iff] at h
    obtain ⟨rfl, h'⟩ := pair_inj h
    rw [encList_inj xs ys h']

theorem lt_encList : ∀ {x : Nat} {l : List Nat}, x ∈ l → x < encList l
  | x, y :: ys, h => by
    simp only [encList]
    rcases List.mem_cons.mp h with rfl | h
    · have := le_pair_left x (encList ys); omega
    · have := lt_encList h; have := le_pair_right y (encList ys); omega

theorem encOpt_inj {o o' : Option Nat} (h : encOpt o = encOpt o') : o = o' := by
  cases o <;> cases o' <;> simp_all [encOpt]

theorem encPayload_inj {p p' : Payload} (h : encPayload p = encPayload p') : p = p' := by
  cases p <;> cases p' <;>
    first | rfl | (simp only [encPayload] at h; have := encList_inj _ _ h; simp_all)

theorem encEvent_inj (e e' : Event) (h : encEvent e = encEvent e') : e = e' := by
  cases e with
  | icp i =>
    cases e' <;> (simp only [encEvent] at h; have := encList_inj _ _ h; simp_all)
    cases i; simp_all
  | rot r =>
    cases e' <;> (simp only [encEvent] at h; have := encList_inj _ _ h; simp_all)
    cases r; simp_all
  | ixn a =>
    cases e' with
    | ixn a' =>
      simp only [encEvent] at h
      have := encList_inj _ _ h
      simp only [List.cons.injEq] at this
      obtain ⟨h1, h2, h3, h4, h5, h6, -⟩ := this
      cases a; cases a'
      simp only at h1 h3 h4 h6
      subst h1 h3 h4 h6
      simp only at h2 h5
      rw [encOpt_inj h2, encPayload_inj h5]
    | _ => simp only [encEvent] at h; have := encList_inj _ _ h; simp_all

theorem encEvent_no_self_p (e : Event) : e.p ≠ some (encEvent e) := by
  cases e with
  | icp _ => simp [Event.p]
  | rot r =>
    have hlt : r.p < encEvent (.rot r) := lt_encList (l := [r.p, r.pfx, r.body]) (by simp)
    intro h; rw [Option.some.inj h] at hlt; exact Nat.lt_irrefl _ hlt
  | ixn a =>
    have hlt : a.p < encEvent (.ixn a) :=
      lt_encList (l := [a.p, encOpt a.prev, a.signer, a.gid, encPayload a.payload, a.sig])
        (by simp)
    intro h; rw [Option.some.inj h] at hlt; exact Nat.lt_irrefl _ hlt

theorem encEvent_no_self_prev (a : Action) : a.prev ≠ some (encEvent (.ixn a)) := by
  intro h
  have hlt : encOpt a.prev < encEvent (.ixn a) :=
    lt_encList (l := [a.p, encOpt a.prev, a.signer, a.gid, encPayload a.payload, a.sig])
      (by simp)
  generalize encEvent (.ixn a) = E at hlt h
  rw [h] at hlt
  simp only [encOpt] at hlt; omega

/-- A concrete witness: injective digests; a signature verifies iff it is the
    signer's own (abstract) key; every KERI event valid; a SAID that omits the
    group id and signature. -/
def concrete : Assumptions where
  digest := encEvent
  said a := encList [a.signer, a.p, encPayload a.payload, encOpt a.prev]
  sigOk a := a.sig == a.signer
  icpOk _ := true
  rotOk _ _ := true
  digest_inj := encEvent_inj
  no_self_p := encEvent_no_self_p
  no_self_prev := encEvent_no_self_prev

/-! ## Evaluated trace

Alice creates a group and adds Bob; Bob acts, rotates, and re-signs a stale
action; a forged signature (refused for that reason alone), a replay and
Alice's self-demotion as last admin are refused, and the
same self-demotion is admitted once Bob is an admin. -/

namespace Trace

def C := concrete
def alice : Ident := 1
def bob : Ident := 2
def icpA : Inception := ⟨alice, 10⟩
def icpB : Inception := ⟨bob, 20⟩
def tipOf (s : State) (i : Ident) : Digest := (tip C (s.kel i)).getD 0
def headOf (s : State) (g : GroupId) : Option Digest := head C (s.chain g)

def s1 : State := step C (step C State.empty (.host icpA)) (.host icpB)

def gen0 : Action := ⟨alice, 0, tipOf s1 alice, .genesis, none, alice⟩
def gen : Action := { gen0 with gid := C.said gen0 }
def g : GroupId := gen.gid
def s2 : State := step C s1 (.admit gen)

def addBob : Action := ⟨alice, g, tipOf s2 alice, .add bob, headOf s2 g, alice⟩
def s3 : State := step C s2 (.admit addBob)

def bobAct : Action := ⟨bob, g, tipOf s3 bob, .app 7, headOf s3 g, bob⟩
def s4 : State := step C s3 (.admit bobAct)

def rotB : Rotation := ⟨bob, tipOf s4 bob, 21⟩
def s5 : State := step C s4 (.rotate rotB)

/-- Bob's next action, signed against his tip from before the rotation. -/
def bobStale : Action := ⟨bob, g, tipOf s4 bob, .app 8, headOf s5 g, bob⟩
/-- The same action re-signed against the new tip. -/
def bobFresh : Action := { bobStale with p := tipOf s5 bob }
def s6 : State := step C s5 (.admit bobFresh)

/-- `bobFresh` carrying a signature that is not Bob's. -/
def bobForged : Action := { bobFresh with sig := alice }
/-- The same instance with every signature accepted: admission under it differs
    from admission under `C` only in the signature condition. -/
def anySig : Assumptions := { concrete with sigOk := fun _ => true }

/-- Alice drops her own admin while she is the only admin. -/
def demote6 : Action := ⟨alice, g, tipOf s6 alice, .revoke alice, headOf s6 g, alice⟩

def grantBob : Action := ⟨alice, g, tipOf s6 alice, .grant bob, headOf s6 g, alice⟩
def s7 : State := step C s6 (.admit grantBob)
def demote7 : Action := ⟨alice, g, tipOf s7 alice, .revoke alice, headOf s7 g, alice⟩
def s8 : State := step C s7 (.admit demote7)

#guard (host C State.empty icpA).isSome
#guard (admit C s1 gen).isSome
#guard (admit C s2 addBob).isSome
#guard (admit C s3 bobAct).isSome
#guard (rotate C s4 rotB).isSome
#guard (s5.chain g).length == 3
#guard (admit C s5 bobStale).isNone
#guard (admit C s5 bobFresh).isSome
#guard (admit C s5 bobForged).isNone
#guard (admit anySig s5 bobForged).isSome
#guard (admit C s6 addBob).isNone
#guard (admit C s6 bobAct).isNone
#guard (admit C s6 demote6).isNone
#guard (admit C s7 demote7).isSome
#guard (roster (s8.chain g)).admins == [bob]
#guard (roster (s8.chain g)).members == [bob, alice]

end Trace

end KelGroups.Sovereign
