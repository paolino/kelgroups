/-
  KelGroups.Sovereign.Theorems — the guarantees of admission, group chain and
  core membership (T0–T6), for every choice of the assumptions structure.
-/
import KelGroups.Sovereign.Invariants

namespace KelGroups.Sovereign

open KERI.Crypto

variable (C : Assumptions)

/-! ## T0 — admission is exactly the admission conditions -/

/-- T0: an action is admitted iff the signature is valid, `p` is the signer's
    KEL tip, `prev` is the group head, the signer is a current member or the
    action is a genesis, and the core membership rules hold; the admitted
    state is the old one with the action appended. -/
theorem admit_iff (s s' : State) (a : Action) :
    admit C s a = some s' ↔
      (C.sigOk a = true ∧
       tip C (s.kel a.signer) = some a.p ∧
       head C (s.chain a.gid) = a.prev ∧
       (a.payload = .genesis ∨ a.signer ∈ (roster (s.chain a.gid)).members) ∧
       membershipOk C (hosted s) (s.chain a.gid) a = true) ∧
      s' = s.append a := by
  exact admit_some C

/-! ## T1 — atomic admission -/

/-- T1: admission either refuses and the step leaves the state unchanged, or
    extends the signer's KEL by exactly the action and its group's chain by
    exactly the action, moving that group's head to the action's digest and
    leaving every other KEL and every other group untouched. -/
theorem admit_atomic (s : State) (a : Action) :
    (admit C s a = none ∧ step C s (.admit a) = s) ∨
    ∃ s', admit C s a = some s' ∧ step C s (.admit a) = s' ∧
      s'.kel a.signer = s.kel a.signer ++ [.ixn a] ∧
      (∀ i, i ≠ a.signer → s'.kel i = s.kel i) ∧
      s'.chain a.gid = s.chain a.gid ++ [a] ∧
      head C (s'.chain a.gid) = some (C.digest (.ixn a)) ∧
      (∀ g, g ≠ a.gid → s'.chain g = s.chain g) := by
  cases h : admit C s a with
  | none => exact .inl ⟨rfl, by simp [step, h]⟩
  | some s' =>
    obtain ⟨_, rfl⟩ := (admit_some C).mp h
    refine .inr ⟨_, rfl, by simp [step, h], by simp [State.append], fun i hi => ?_,
      by simp [State.append], by simp [State.append, head_append], fun g hg => ?_⟩
    · simp [State.append, upd_other _ _ hi]
    · simp [State.append, upd_other _ _ hg]

/-- Rotation extends only the rotating KEL and changes no group. -/
theorem rotate_effect (s s' : State) (r : Rotation) (h : rotate C s r = some s') :
    s'.kel r.pfx = s.kel r.pfx ++ [.rot r] ∧
    (∀ i, i ≠ r.pfx → s'.kel i = s.kel i) ∧
    s'.chain = s.chain := by
  obtain ⟨_, rfl⟩ := rotate_some C h
  exact ⟨by simp, fun i hi => by simp [upd_other _ _ hi], rfl⟩

/-! ## T2 — single-line chain -/

/-- T2 (step): an admitted action's `prev` is its group's head before admission. -/
theorem admitted_prev_is_head (s s' : State) (a : Action) (h : admit C s a = some s') :
    head C (s.chain a.gid) = a.prev :=
  ((admit_some C).mp h).1.2.2.1

/-- T2 (reachable): every group's chain is a single `prev`-linked line from
    its genesis, all of whose actions carry that group's id. -/
theorem chain_is_line (s : State) (hs : Reachable C s) (g : GroupId) :
    ChainLine C (s.chain g) ∧ ∀ a ∈ s.chain g, a.gid = g :=
  let hi := inv_reachable C hs
  ⟨hi.chain_line g, hi.chain_gid g⟩

/-! ## T3 — at most once -/

/-- T3: an action in a group's chain on a reachable state is refused at that
    state and at every later state. -/
theorem replay_refused (s s' : State) (a : Action) (g : GroupId)
    (hs : Reachable C s) (ha : a ∈ s.chain g) (hss' : Steps C s s') :
    admit C s' a = none := by
  have hi := inv_reachable C (steps_trans C hs hss')
  have ha' : a ∈ s'.chain g := ((steps_prefix C hss').2 g).subset ha
  have hg := hi.chain_gid g a ha'
  rw [admit_none]
  intro h'
  have hh := h'.2.2.1
  rw [hg] at hh
  cases hl : (s'.chain g).getLast? with
  | none => simp at hl; rw [hl] at ha'; simp at ha'
  | some z =>
    simp [head, hl] at hh
    exact (Line.props (chain_digest_inj C) (hi.chain_line g)).2.2 z hl a ha' hh.symm

/-- T3 (immediate, any state): an action just admitted is refused if resent. -/
theorem resend_refused (s s' : State) (a : Action) (h : admit C s a = some s') :
    admit C s' a = none := by
  obtain ⟨_, rfl⟩ := (admit_some C).mp h
  rw [admit_none]
  intro h'
  have hh := h'.2.2.1
  simp [State.append, head_append] at hh
  exact C.no_self_prev a hh.symm

/-! ## T4 — stale `p` -/

/-- T4: an action whose `p` is not its signer's current KEL tip is refused. -/
theorem stale_p_refused (s : State) (a : Action) (h : tip C (s.kel a.signer) ≠ some a.p) :
    admit C s a = none := by
  rw [admit_none]
  exact fun h' => h h'.2.1

/-- T4: an action built against tip t is refused after an admitted rotation
    of its signer, in any group. -/
theorem stale_after_rotation (s s' : State) (r : Rotation) (a : Action) (t : Digest)
    (hr : rotate C s r = some s') (ht : tip C (s.kel r.pfx) = some t)
    (hsig : a.signer = r.pfx) (hp : a.p = t) :
    admit C s' a = none := by
  obtain ⟨htr, rfl⟩ := rotate_some C hr
  rw [ht] at htr
  rw [admit_none]
  intro h'
  have htip := h'.2.1
  rw [hsig] at htip
  simp [tip_append] at htip
  apply C.no_self_p (.rot r)
  simp [Event.p]
  rw [htip, hp]; exact (Option.some.inj htr).symm

/-- T4: an action built against tip t is refused after any other admitted
    action of its signer, in any group. -/
theorem stale_after_action (s s' : State) (b a : Action) (t : Digest)
    (hb : admit C s b = some s') (ht : tip C (s.kel b.signer) = some t)
    (hsig : a.signer = b.signer) (hp : a.p = t) :
    admit C s' a = none := by
  obtain ⟨hb', rfl⟩ := (admit_some C).mp hb
  have htb := hb'.2.1
  rw [ht] at htb
  rw [admit_none]
  intro h'
  have htip := h'.2.1
  rw [hsig] at htip
  simp [State.append, tip_append] at htip
  apply C.no_self_p (.ixn b)
  simp [Event.p]
  rw [htip, hp]; exact (Option.some.inj htb).symm

/-- T4 (reachable): once the signer's KEL has grown past tip t, an action
    built against t is refused at every later state. -/
theorem stale_forever (s s' : State) (i : Ident) (a : Action) (t : Digest)
    (hs : Reachable C s) (ht : tip C (s.kel i) = some t) (hss' : Steps C s s')
    (hgrow : (s.kel i).length < (s'.kel i).length)
    (hsig : a.signer = i) (hp : a.p = t) :
    admit C s' a = none := by
  have hi := inv_reachable C (steps_trans C hs hss')
  obtain ⟨u, hu⟩ := (steps_prefix C hss').1 i
  obtain ⟨e, he, hde⟩ := tip_some C ht
  rw [admit_none]
  intro h'
  have htip := h'.2.1
  rw [hsig, ← hu] at htip
  have hune : u ≠ [] := by
    rintro rfl; rw [← hu] at hgrow; simp at hgrow
  obtain ⟨e', he', hde'⟩ := tip_some C htip
  have hee : e' = e := C.digest_inj _ _ (by rw [hde', hp, hde])
  have hu' : e' ∈ u := by
    rw [List.getLast?_append] at he'
    cases hl : u.getLast? with
    | none => exact absurd (List.getLast?_eq_none_iff.mp hl) hune
    | some y => rw [hl] at he'; simp at he'; subst he'; exact List.mem_of_getLast? hl
  have hnd := (Line.props C.digest_inj (hi.kel_line i)).1
  rw [← hu, List.nodup_append] at hnd
  exact hnd.2.2 e (List.mem_of_getLast? he) e' hu' hee.symm

/-! ## T5 — membership and admin authorisation -/

/-- T5: the signer of an admitted non-genesis action is a current member. -/
theorem admitted_signer_member (s s' : State) (a : Action) (h : admit C s a = some s')
    (hg : a.payload ≠ .genesis) :
    a.signer ∈ (roster (s.chain a.gid)).members := by
  exact ((admit_some C).mp h).1.2.2.2.1.resolve_left hg

/-- T5: the signer of an admitted add/remove/grant/revoke is a current admin. -/
theorem admitted_admin_signer (s s' : State) (a : Action) (x : Ident)
    (h : admit C s a = some s')
    (hk : a.payload = .add x ∨ a.payload = .remove x ∨
          a.payload = .grant x ∨ a.payload = .revoke x) :
    a.signer ∈ (roster (s.chain a.gid)).admins := by
  have hc := ((admit_some C).mp h).1.2.2.2.2
  rcases hk with hk | hk | hk | hk <;> simp [membershipOk, hk] at hc <;> simp [hc]

/-- T5: an admitted leave removes its signer and changes nobody else. -/
theorem leave_only_signer (s s' : State) (a : Action) (h : admit C s a = some s')
    (hl : a.payload = .leave) :
    a.signer ∉ (roster (s'.chain a.gid)).members ∧
    a.signer ∉ (roster (s'.chain a.gid)).admins ∧
    ∀ y, y ≠ a.signer →
      (y ∈ (roster (s'.chain a.gid)).members ↔ y ∈ (roster (s.chain a.gid)).members) ∧
      (y ∈ (roster (s'.chain a.gid)).admins ↔ y ∈ (roster (s.chain a.gid)).admins) := by
  obtain ⟨_, rfl⟩ := (admit_some C).mp h
  simp only [State.append, upd_same, roster_append, applyCore, hl, List.mem_filter]
  refine ⟨by simp, by simp, fun y hy => by simp [hy]⟩

/-- T5: an admitted remove of x leaves x neither member nor admin. -/
theorem removed_not_member (s s' : State) (a : Action) (x : Ident)
    (h : admit C s a = some s') (hr : a.payload = .remove x) :
    x ∉ (roster (s'.chain a.gid)).members ∧ x ∉ (roster (s'.chain a.gid)).admins := by
  obtain ⟨_, rfl⟩ := (admit_some C).mp h
  simp [State.append, roster_append, applyCore, hr, List.mem_filter]

/-- T5: every action of a non-member in an existing group is refused. -/
theorem nonmember_refused (s : State) (a : Action)
    (hm : a.signer ∉ (roster (s.chain a.gid)).members) (hne : s.chain a.gid ≠ []) :
    admit C s a = none := by
  rw [admit_none]
  intro h
  rcases h.2.2.2.1 with hg | hm'
  · exact hne (admissible_genesis C h hg)
  · exact hm hm'

/-- T5: membership of a group is gained only by an admitted add of that
    identifier into that group, or by its own genesis of the group. -/
theorem member_gained_only_by_add (s : State) (op : Op) (g : GroupId) (x : Ident)
    (hx : x ∉ (roster (s.chain g)).members)
    (hx' : x ∈ (roster ((step C s op).chain g)).members) :
    ∃ a, op = .admit a ∧ a.gid = g ∧
      (a.payload = .add x ∨ (a.payload = .genesis ∧ a.signer = x)) := by
  cases op with
  | host e =>
    exfalso; apply hx
    cases h : host C s e with
    | none => simpa [step, h] using hx'
    | some s' => obtain ⟨_, rfl⟩ := host_some C h; simpa [step, h] using hx'
  | rotate r =>
    exfalso; apply hx
    cases h : rotate C s r with
    | none => simpa [step, h] using hx'
    | some s' => obtain ⟨_, rfl⟩ := rotate_some C h; simpa [step, h] using hx'
  | admit a =>
    cases h : admit C s a with
    | none => exfalso; simp [step, h] at hx'; exact hx hx'
    | some s' =>
      obtain ⟨_, rfl⟩ := (admit_some C).mp h
      simp only [step, h, Option.getD_some] at hx'
      by_cases hg : g = a.gid
      · subst hg
        simp only [State.append, upd_same, roster_append] at hx'
        refine ⟨a, rfl, rfl, ?_⟩
        cases hp : a.payload <;> simp [applyCore, hp, List.mem_filter] at hx' <;> simp_all
      · simp only [State.append, upd_other _ _ hg] at hx'; exact absurd hx' hx

/-! ## T6 — last-admin guard -/

/-- T6: on every reachable state no group has members and no admin, and
    every admin is a member. -/
theorem admin_guard (s : State) (hs : Reachable C s) (g : GroupId) :
    ((roster (s.chain g)).members ≠ [] → (roster (s.chain g)).admins ≠ []) ∧
    ∀ y ∈ (roster (s.chain g)).admins, y ∈ (roster (s.chain g)).members := by
  let hi := inv_reachable C hs
  exact ⟨hi.guard g, hi.admins_members g⟩

end KelGroups.Sovereign
