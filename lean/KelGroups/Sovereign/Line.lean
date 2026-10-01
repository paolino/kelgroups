/-
  KelGroups.Sovereign.Line — a single hash-linked line: the shape of a member
  KEL (linked by `p`) and of a group chain (linked by `prev`).
-/
import KelGroups.Sovereign.Types

namespace KelGroups.Sovereign

open KERI.Crypto

/-- `Line link d first later l`: l is one linked line, oldest first. Its first
    element satisfies `first` and links to nothing; every later element
    satisfies `later` and links to the digest `d` of its predecessor. -/
inductive Line {α : Type} (link : α → Option Digest) (d : α → Digest)
    (first later : α → Prop) : List α → Prop
  | nil : Line link d first later []
  | one (a : α) : first a → link a = none → Line link d first later [a]
  | snoc (l : List α) (a b : α) : Line link d first later l → l.getLast? = some a →
      later b → link b = some (d a) → Line link d first later (l ++ [b])

/-- Shape of a member KEL: an inception, then events each linking by `p` to
    the digest of the previous one. -/
def KelLine (C : Assumptions) (kel : List Event) : Prop :=
  Line Event.p C.digest (fun _ => True) (fun _ => True) kel

/-- Shape of a group chain: genesis first with no `prev`, every later action
    a non-genesis whose `prev` is the digest of its predecessor. -/
def ChainLine (C : Assumptions) (chain : List Action) : Prop :=
  Line Action.prev (fun a => C.digest (.ixn a))
    (fun a => a.payload = .genesis) (fun a => a.payload ≠ .genesis) chain

section
variable {α : Type} {link : α → Option Digest} {d : α → Digest} {first later : α → Prop}

/-- With injective digests a line has no repeated element, every link points
    into the line, and nothing in it links to its last element. -/
theorem Line.props (hd : ∀ x y, d x = d y → x = y) {l : List α}
    (h : Line link d first later l) :
    l.Nodup ∧
    (∀ x ∈ l, link x = none ∨ ∃ w ∈ l, link x = some (d w)) ∧
    (∀ z, l.getLast? = some z → ∀ x ∈ l, link x ≠ some (d z)) := by
  induction h with
  | nil => simp
  | one a _ ha =>
    refine ⟨by simp, ?_, ?_⟩
    · intro x hx; simp at hx; subst hx; exact .inl ha
    · intro z _ x hx; simp at hx; subst hx; simp [ha]
  | snoc l a b _ hlast _ hb ih =>
    obtain ⟨hnd, hq, hp⟩ := ih
    have hal : a ∈ l := List.mem_of_getLast? hlast
    have hbl : b ∉ l := fun hbl => hp a hlast b hbl hb
    refine ⟨?_, ?_, ?_⟩
    · rw [List.nodup_append]
      exact ⟨hnd, by simp, by intro x hx y hy; simp at hy; subst hy; intro e; subst e; exact hbl hx⟩
    · intro x hx
      rcases List.mem_append.mp hx with hx | hx
      · rcases hq x hx with h0 | ⟨w, hw, hw'⟩
        · exact .inl h0
        · exact .inr ⟨w, List.mem_append_left _ hw, hw'⟩
      · simp at hx; subst hx; exact .inr ⟨a, List.mem_append_left _ hal, hb⟩
    · intro z hz x hx
      simp at hz; subst hz
      rcases List.mem_append.mp hx with hx | hx
      · rcases hq x hx with h0 | ⟨w, hw, hw'⟩
        · simp [h0]
        · intro e; rw [hw'] at e
          have := hd _ _ (Option.some.inj e); subst this; exact hbl hw
      · simp at hx; subst hx; intro e; rw [hb] at e
        have := hd _ _ (Option.some.inj e); subst this; exact hbl hal

end

end KelGroups.Sovereign
