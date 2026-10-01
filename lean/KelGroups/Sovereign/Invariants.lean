/-
  KelGroups.Sovereign.Invariants — effects of each server step and the state
  invariant every reachable state satisfies.
-/
import KelGroups.Sovereign.Admission
import KelGroups.Sovereign.Line

namespace KelGroups.Sovereign

open KERI.Crypto

variable (C : Assumptions)

@[simp] theorem upd_same {β : Type} (f : Nat → β) (i : Nat) (v : β) : upd f i v i = v := by
  simp [upd]

theorem upd_other {β : Type} (f : Nat → β) {i j : Nat} (v : β) (h : j ≠ i) :
    upd f i v j = f j := by
  simp [upd, h]

theorem admit_some {s s' : State} {a : Action} :
    admit C s a = some s' ↔ Admissible C s a ∧ s' = s.append a := by
  unfold admit
  by_cases h : Admissible C s a <;> simp [h, eq_comm]

theorem admit_none {s : State} {a : Action} :
    admit C s a = none ↔ ¬ Admissible C s a := by
  unfold admit
  by_cases h : Admissible C s a <;> simp [h]

theorem rotate_some {s s' : State} {r : Rotation} (h : rotate C s r = some s') :
    tip C (s.kel r.pfx) = some r.p ∧
    s' = { s with kel := upd s.kel r.pfx (s.kel r.pfx ++ [.rot r]) } := by
  unfold rotate at h
  split at h
  · rename_i hc
    simp at hc h
    exact ⟨hc.2, h.symm⟩
  · cases h

theorem host_some {s s' : State} {e : Inception} (h : host C s e = some s') :
    s.kel e.pfx = [] ∧ s' = { s with kel := upd s.kel e.pfx [.icp e] } := by
  unfold host at h
  split at h
  · rename_i hc
    simp at hc h
    exact ⟨hc.1, h.symm⟩
  · cases h

theorem tip_append (l : List Event) (e : Event) : tip C (l ++ [e]) = some (C.digest e) := by
  simp [tip]

theorem head_append (l : List Action) (a : Action) :
    head C (l ++ [a]) = some (C.digest (.ixn a)) := by
  simp [head]

theorem roster_append (l : List Action) (a : Action) :
    roster (l ++ [a]) = applyCore (roster l) a := by
  simp [roster, List.foldl_append]

theorem tip_some {l : List Event} {t : Digest} (h : tip C l = some t) :
    ∃ e, l.getLast? = some e ∧ C.digest e = t := by
  simp [tip] at h; exact h

/-- A chain whose roster has a member is not empty. -/
theorem chain_ne_nil_of_member {l : List Action} {x : Ident}
    (h : x ∈ (roster l).members) : l ≠ [] := by
  rintro rfl; simp [roster] at h

/-- The genesis rule forces an empty chain; any other admissible action has
    a member signer and so a non-empty chain. -/
theorem admissible_genesis {s : State} {a : Action} (h : Admissible C s a)
    (hg : a.payload = .genesis) : s.chain a.gid = [] := by
  have := h.2.2.2.2
  simp [membershipOk, hg] at this
  exact this.2.1

/-- Every step only appends to KELs and chains. -/
theorem step_prefix (s : State) (op : Op) :
    (∀ i, s.kel i <+: (step C s op).kel i) ∧ (∀ g, s.chain g <+: (step C s op).chain g) := by
  cases op with
  | host e =>
    simp only [step]
    cases h : host C s e with
    | none => simp
    | some s' =>
      obtain ⟨he, rfl⟩ := host_some C h
      simp only [Option.getD_some]
      refine ⟨fun i => ?_, fun g => by simp⟩
      by_cases hi : i = e.pfx
      · subst hi; simp [he]
      · simp [upd_other _ _ hi]
  | rotate r =>
    simp only [step]
    cases h : rotate C s r with
    | none => simp
    | some s' =>
      obtain ⟨_, rfl⟩ := rotate_some C h
      refine ⟨fun i => ?_, fun g => by simp⟩
      by_cases hi : i = r.pfx
      · subst hi; simp
      · simp [upd_other _ _ hi]
  | admit a =>
    simp only [step]
    cases h : admit C s a with
    | none => simp
    | some s' =>
      obtain ⟨_, rfl⟩ := (admit_some C).mp h
      refine ⟨fun i => ?_, fun g => ?_⟩
      · by_cases hi : i = a.signer
        · subst hi; simp [State.append]
        · simp [State.append, upd_other _ _ hi]
      · by_cases hg : g = a.gid
        · subst hg; simp [State.append]
        · simp [State.append, upd_other _ _ hg]

theorem steps_prefix {s s' : State} (h : Steps C s s') :
    (∀ i, s.kel i <+: s'.kel i) ∧ (∀ g, s.chain g <+: s'.chain g) := by
  induction h with
  | refl => exact ⟨fun _ => List.prefix_refl _, fun _ => List.prefix_refl _⟩
  | tail op _ ih =>
    exact ⟨fun i => ih.1 i |>.trans ((step_prefix C _ op).1 i),
           fun g => ih.2 g |>.trans ((step_prefix C _ op).2 g)⟩

theorem steps_trans {s t u : State} (h1 : Steps C s t) (h2 : Steps C t u) : Steps C s u := by
  induction h2 with
  | refl => exact h1
  | tail op _ ih => exact .tail op ih

/-- The invariant of reachable states. -/
structure Inv (s : State) : Prop where
  kel_line : ∀ i, KelLine C (s.kel i)
  chain_line : ∀ g, ChainLine C (s.chain g)
  chain_gid : ∀ g, ∀ a ∈ s.chain g, a.gid = g
  chain_in_kel : ∀ g, ∀ a ∈ s.chain g, Event.ixn a ∈ s.kel a.signer
  guard : ∀ g, (roster (s.chain g)).members ≠ [] → (roster (s.chain g)).admins ≠ []
  admins_members : ∀ g, ∀ y ∈ (roster (s.chain g)).admins, y ∈ (roster (s.chain g)).members

theorem inv_empty : Inv C State.empty where
  kel_line _ := .nil
  chain_line _ := .nil
  chain_gid _ _ h := by simp [State.empty] at h
  chain_in_kel _ _ h := by simp [State.empty] at h
  guard _ h := by simp [State.empty, roster] at h
  admins_members _ _ h := by simp [State.empty, roster] at h

/-- The roster after one admitted action keeps admins among members. -/
theorem applyCore_admins_members (C : Assumptions) (hosted : Ident → Bool)
    (l : List Action) (a : Action)
    (hm : membershipOk C hosted l a = true)
    (h : ∀ y ∈ (roster l).admins, y ∈ (roster l).members) :
    ∀ y ∈ (applyCore (roster l) a).admins, y ∈ (applyCore (roster l) a).members := by
  intro y hy
  cases hp : a.payload with
  | genesis => simp [applyCore, hp] at hy ⊢; exact hy
  | add x => simp [applyCore, hp] at hy ⊢; exact .inr (h y hy)
  | remove x =>
    simp [applyCore, hp, List.mem_filter] at hy ⊢; exact ⟨h y hy.1, hy.2⟩
  | grant x =>
    simp [membershipOk, hp] at hm
    simp [applyCore, hp] at hy ⊢
    rcases hy with rfl | hy
    · exact hm.2.1.2
    · exact h y hy
  | revoke x =>
    simp [applyCore, hp, List.mem_filter] at hy ⊢; exact h y hy.1
  | leave =>
    simp [applyCore, hp, List.mem_filter] at hy ⊢; exact ⟨h y hy.1, hy.2⟩
  | app _ => simp [applyCore, hp] at hy ⊢; exact h y hy

theorem guardOk_spec {r : Roster} (h : guardOk r = true) : r.members ≠ [] → r.admins ≠ [] := by
  simp [guardOk] at h
  intro hm ha
  rcases h with h | h
  · exact hm h
  · exact h ha

theorem inv_admit {s : State} {a : Action} (hi : Inv C s) (h : Admissible C s a) :
    Inv C (s.append a) := by
  obtain ⟨_, htip, hhead, hmem, hcore⟩ := h
  have hkel : KelLine C (s.kel a.signer ++ [.ixn a]) := by
    obtain ⟨e, he, hd⟩ := tip_some C htip
    exact .snoc _ e _ (hi.kel_line _) he trivial (by simp [Event.p, hd])
  have hchain : ChainLine C (s.chain a.gid ++ [a]) := by
    by_cases hg : a.payload = .genesis
    · have hnil := admissible_genesis C ⟨‹_›, htip, hhead, hmem, hcore⟩ hg
      rw [hnil] at hhead ⊢
      exact .one a hg (by rw [← hhead]; rfl)
    · have hm := hmem.resolve_left hg
      cases hl : (s.chain a.gid).getLast? with
      | none => simp at hl; exact absurd hl (chain_ne_nil_of_member hm)
      | some z =>
        refine .snoc _ z _ (hi.chain_line _) hl hg ?_
        simp [head, hl] at hhead; exact hhead.symm
  have hguard : guardOk (applyCore (roster (s.chain a.gid)) a) = true := by
    simp [membershipOk] at hcore; exact hcore.1
  refine ⟨fun i => ?_, fun g => ?_, fun g b hb => ?_, fun g b hb => ?_, fun g => ?_, fun g => ?_⟩
  · by_cases hi' : i = a.signer
    · subst hi'; simpa [State.append] using hkel
    · simpa [State.append, upd_other _ _ hi'] using hi.kel_line i
  · by_cases hg : g = a.gid
    · subst hg; simpa [State.append] using hchain
    · simpa [State.append, upd_other _ _ hg] using hi.chain_line g
  · by_cases hg : g = a.gid
    · subst hg; simp [State.append] at hb
      rcases hb with hb | rfl
      · exact hi.chain_gid _ b hb
      · rfl
    · simp [State.append, upd_other _ _ hg] at hb; exact hi.chain_gid g b hb
  · have hin : b ∈ s.chain g ∨ (g = a.gid ∧ b = a) := by
      by_cases hg : g = a.gid
      · subst hg; simp [State.append] at hb; rcases hb with hb | rfl
        · exact .inl hb
        · exact .inr ⟨rfl, rfl⟩
      · simp [State.append, upd_other _ _ hg] at hb; exact .inl hb
    by_cases hs : b.signer = a.signer
    · simp only [State.append, hs, upd_same, List.mem_append]
      rcases hin with hin | ⟨_, rfl⟩
      · exact .inl (hs ▸ hi.chain_in_kel g b hin)
      · simp
    · simp only [State.append, upd_other _ _ hs]
      rcases hin with hin | ⟨_, rfl⟩
      · exact hi.chain_in_kel g b hin
      · exact absurd rfl hs
  · by_cases hg : g = a.gid
    · subst hg; simp only [State.append, upd_same, roster_append]; exact guardOk_spec hguard
    · simp only [State.append, upd_other _ _ hg]; exact hi.guard g
  · by_cases hg : g = a.gid
    · subst hg; simp only [State.append, upd_same, roster_append]
      exact applyCore_admins_members C _ _ a hcore (hi.admins_members _)
    · simp only [State.append, upd_other _ _ hg]; exact hi.admins_members g

theorem inv_step {s : State} (hi : Inv C s) (op : Op) : Inv C (step C s op) := by
  cases op with
  | host e =>
    simp only [step]
    cases h : host C s e with
    | none => exact hi
    | some s' =>
      obtain ⟨he, rfl⟩ := host_some C h
      simp only [Option.getD_some]
      refine ⟨fun i => ?_, hi.chain_line, hi.chain_gid, fun g b hb => ?_, hi.guard,
        hi.admins_members⟩
      · by_cases hi' : i = e.pfx
        · subst hi'; simp only [upd_same]; exact .one _ trivial rfl
        · simp only [upd_other _ _ hi']; exact hi.kel_line i
      · have := hi.chain_in_kel g b hb
        by_cases hs : b.signer = e.pfx
        · rw [hs, he] at this; simp at this
        · simp only [upd_other _ _ hs]; exact this
  | rotate r =>
    simp only [step]
    cases h : rotate C s r with
    | none => exact hi
    | some s' =>
      obtain ⟨ht, rfl⟩ := rotate_some C h
      simp only [Option.getD_some]
      refine ⟨fun i => ?_, hi.chain_line, hi.chain_gid, fun g b hb => ?_, hi.guard,
        hi.admins_members⟩
      · by_cases hi' : i = r.pfx
        · subst hi'; simp only [upd_same]
          obtain ⟨e, he, hd⟩ := tip_some C ht
          exact .snoc _ e _ (hi.kel_line _) he trivial (by simp [Event.p, hd])
        · simp only [upd_other _ _ hi']; exact hi.kel_line i
      · have := hi.chain_in_kel g b hb
        by_cases hs : b.signer = r.pfx
        · simp only [hs, upd_same, List.mem_append]; exact .inl (hs ▸ this)
        · simp only [upd_other _ _ hs]; exact this
  | admit a =>
    simp only [step]
    cases h : admit C s a with
    | none => exact hi
    | some s' =>
      obtain ⟨ha, rfl⟩ := (admit_some C).mp h
      simp only [Option.getD_some]
      exact inv_admit C hi ha

theorem inv_steps {s s' : State} (hi : Inv C s) (h : Steps C s s') : Inv C s' := by
  induction h with
  | refl => exact hi
  | tail op _ ih => exact inv_step C ih op

theorem inv_reachable {s : State} (h : Reachable C s) : Inv C s :=
  inv_steps C (inv_empty C) h

theorem chain_digest_inj : ∀ x y : Action, C.digest (.ixn x) = C.digest (.ixn y) → x = y := by
  intro x y h; have := C.digest_inj _ _ h; cases this; rfl

end KelGroups.Sovereign
