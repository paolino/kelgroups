/-
  KelGroups.KELInvariants — Proofs for L1/L2 invariants

  Proves key properties of the L1/L2 architecture:
  - Enactment events carry sufficient proof
  - Threshold is correctly computed
  - Chain operations preserve validity
-/
import KelGroups.Basic
import KelGroups.KEL

namespace KelGroups

open KERI.Crypto
open KERI.Event
open KERI.KEL (hashChainValid)

-- ============================================================
-- INV 10: Threshold properties
-- ============================================================

/-- With 3 admins and 2 approvals, threshold is met. -/
theorem threshold_3_admins_2_approvals :
    thresholdMet 2 3 := by
  simp [thresholdMet, majority]

/-- With 3 admins, 1 approval is insufficient. -/
theorem threshold_3_admins_1_insufficient :
    ¬ thresholdMet 1 3 := by
  simp [thresholdMet, majority]

/-- With 1 admin, 1 approval suffices. -/
theorem threshold_1_admin_1_approval :
    thresholdMet 1 1 := by
  simp [thresholdMet, majority]

/-- In bootstrap (0 admins), 0 approvals suffice. -/
theorem threshold_bootstrap :
    thresholdMet 0 0 := by
  simp [thresholdMet, majority]

-- ============================================================
-- INV 4 + 12: Self-contained enactment
-- ============================================================

/-- An enacted event with enough proofs is complete. -/
theorem enacted_with_enough_proofs_complete
    (seqN : Nat) (pd : Option Digest)
    (said : SAID) (proofs : List ApprovalProof)
    (adminCnt : Nat) (sk : Key) (sigV : Signature)
    (_hsaid : said ≠ 0)
    (hlen : proofs.length ≥ majority adminCnt) :
    l1EnactmentComplete
      (KELEvent.mk seqN pd (.enacted said proofs) sk sigV)
      adminCnt := by
  simp [l1EnactmentComplete, thresholdMet, hlen]

/-- An enacted event is self-contained if it has proofs. -/
theorem enacted_self_contained
    (seqN : Nat) (pd : Option Digest)
    (said : SAID) (proofs : List ApprovalProof)
    (sk : Key) (sigV : Signature)
    (hsaid : said ≠ 0)
    (hnonempty : proofs.length > 0) :
    l1EnactedSelfContained
      (KELEvent.mk seqN pd (.enacted said proofs) sk sigV) := by
  simp [l1EnactedSelfContained, hsaid, hnonempty]

/-- Inception events are trivially self-contained. -/
theorem inception_self_contained
    (k : Key) (sk : Key) (sigV : Signature) :
    l1EnactedSelfContained
      (KELEvent.mk 0 none (.inception k) sk sigV) := by
  simp [l1EnactedSelfContained]

/-- Expired events are trivially self-contained. -/
theorem expired_self_contained
    (seqN : Nat) (pd : Option Digest)
    (said : SAID) (sk : Key) (sigV : Signature) :
    l1EnactedSelfContained
      (KELEvent.mk seqN pd (.expired said) sk sigV) := by
  simp [l1EnactedSelfContained]

-- ============================================================
-- INV 6: SAID uniqueness
-- ============================================================

/-- Empty SAID list is trivially unique. -/
theorem empty_saids_unique : proposalSAIDsUnique [] := by
  exact List.nodup_nil

/-- A single SAID is trivially unique. -/
theorem single_said_unique (s : SAID) :
    proposalSAIDsUnique [s] := by
  simp [proposalSAIDsUnique, List.Nodup]

/-- Adding a fresh SAID preserves uniqueness. -/
theorem fresh_said_preserves_unique
    (s : SAID) (saids : List SAID)
    (huniq : proposalSAIDsUnique saids)
    (hfresh : s ∉ saids) :
    proposalSAIDsUnique (s :: saids) := by
  exact List.nodup_cons.mpr ⟨hfresh, huniq⟩

-- ============================================================
-- INV 9: No duplicate approvals
-- ============================================================

/-- An L2 with only inception has no duplicate approvals. -/
theorem inception_only_no_duplicates
    (prop : Proposal) (nonce : Nonce) (timeout : Nat)
    (sk : Key) (sigV : Signature) :
    l2NoDuplicateApprovals
      [KELEvent.mk 0 none (.inception prop nonce timeout) sk sigV]
    := by
  simp [l2NoDuplicateApprovals, List.filterMap]

-- ============================================================
-- L2 timeout
-- ============================================================

/-- An L2 with inception carrying positive timeout has a
timeout. -/
theorem l2_inception_has_timeout
    (prop : Proposal) (nonce : Nonce) (timeout : Nat)
    (sk : Key) (sigV : Signature)
    (ht : timeout > 0) :
    l2HasTimeout
      [KELEvent.mk 0 none (.inception prop nonce timeout) sk sigV]
    := by
  simp [l2HasTimeout, List.getLast?, ht]

-- ============================================================
-- Transition preservation: mkL2
-- ============================================================

/-- Creating an L2 produces a valid hash chain. -/
theorem mkL2_chain_valid
    (prop : Proposal) (nonce : Nonce) (timeout : Nat)
    (adminKey : Key) (sig : Signature) :
    hashChainValid (mkL2 prop nonce timeout adminKey sig) := by
  simp [mkL2, hashChainValid]

/-- Creating an L2 has no duplicate approvals. -/
theorem mkL2_no_duplicate_approvals
    (prop : Proposal) (nonce : Nonce) (timeout : Nat)
    (adminKey : Key) (sig : Signature) :
    l2NoDuplicateApprovals (mkL2 prop nonce timeout adminKey sig) := by
  simp [mkL2, l2NoDuplicateApprovals, List.filterMap]

/-- Creating an L2 satisfies onlyApprovals. -/
theorem mkL2_only_approvals
    (prop : Proposal) (nonce : Nonce) (timeout : Nat)
    (adminKey : Key) (sig : Signature) :
    l2OnlyApprovals (mkL2 prop nonce timeout adminKey sig) := by
  simp [mkL2, l2OnlyApprovals]

/-- Creating an L2 with positive timeout has a timeout. -/
theorem mkL2_has_timeout
    (prop : Proposal) (nonce : Nonce) (timeout : Nat)
    (adminKey : Key) (sig : Signature)
    (ht : timeout > 0) :
    l2HasTimeout (mkL2 prop nonce timeout adminKey sig) := by
  simp [mkL2, l2HasTimeout, List.getLast?, ht]

/-- Creating an L2 with admin signer satisfies inceptionByAdmin. -/
theorem mkL2_inception_by_admin
    (prop : Proposal) (nonce : Nonce) (timeout : Nat)
    (adminKey : Key) (sig : Signature)
    (serverK : Key) (admins : List Key)
    (hnotserver : adminKey ≠ serverK)
    (hadmin : adminKey ∈ admins) :
    l2InceptionByAdmin
      (mkL2 prop nonce timeout adminKey sig) serverK admins := by
  simp [mkL2, l2InceptionByAdmin, List.getLast?, hnotserver, hadmin]

/-- Creating an L2 has approvals matching any SAID (vacuously). -/
theorem mkL2_approvals_match
    (prop : Proposal) (nonce : Nonce) (timeout : Nat)
    (adminKey : Key) (sig : Signature) (proposalSAID : SAID) :
    l2ApprovalsMatchSAID
      (mkL2 prop nonce timeout adminKey sig) proposalSAID := by
  simp [mkL2, l2ApprovalsMatchSAID]

-- ============================================================
-- Transition preservation: appendApproval
-- ============================================================

/-- Appending an approval with matching SAID preserves
approvalsMatchSAID. -/
theorem appendApproval_preserves_approvals_match
    (l2 : L2) (adminKey : Key) (sig : Signature)
    (proposalSAID : SAID) (tipDigest : Digest)
    (hmatch : l2ApprovalsMatchSAID l2 proposalSAID) :
    l2ApprovalsMatchSAID
      (appendApproval l2 adminKey sig proposalSAID tipDigest)
      proposalSAID := by
  intro e he
  simp [appendApproval] at he
  cases he with
  | inl h => subst h; simp
  | inr h => exact hmatch e h

/-- Appending an approval with a fresh signer preserves
noDuplicateApprovals. -/
theorem appendApproval_fresh_preserves_no_duplicates
    (l2 : L2) (adminKey : Key) (sig : Signature)
    (proposalSAID : SAID) (tipDigest : Digest)
    (hnodup : l2NoDuplicateApprovals l2)
    (hfresh : adminKey ∉ l2.filterMap fun e =>
      match e.payload with
      | .approval _ => some e.signer
      | _ => none) :
    l2NoDuplicateApprovals
      (appendApproval l2 adminKey sig proposalSAID tipDigest) := by
  simp only [appendApproval, l2NoDuplicateApprovals, List.filterMap]
  exact List.nodup_cons.mpr ⟨hfresh, hnodup⟩

-- ============================================================
-- Transition preservation: mkL1
-- ============================================================

/-- Creating an L1 produces a valid hash chain. -/
theorem mkL1_chain_valid (serverK : Key) (sig : Signature) :
    hashChainValid (mkL1 serverK sig) := by
  simp [mkL1, hashChainValid]

/-- Creating an L1 starts with inception. -/
theorem mkL1_starts_with_inception (serverK : Key) (sig : Signature) :
    l1StartsWithInception (mkL1 serverK sig) := by
  simp [mkL1, l1StartsWithInception, List.getLast?]

/-- Creating an L1 is server-only. -/
theorem mkL1_server_only (serverK : Key) (sig : Signature) :
    l1ServerOnly (mkL1 serverK sig) := by
  simp [mkL1, l1ServerOnly, serverKey, List.getLast?]

/-- Creating an L1 has all events self-contained. -/
theorem mkL1_self_contained (serverK : Key) (sig : Signature) :
    ∀ e ∈ mkL1 serverK sig, l1EnactedSelfContained e := by
  simp [mkL1, l1EnactedSelfContained]

-- ============================================================
-- Transition preservation: appendEnacted
-- ============================================================

/-- Appending a self-contained enacted event preserves
selfContained for all events. -/
theorem appendEnacted_preserves_self_contained
    (l1 : L1) (serverK : Key) (sig : Signature)
    (proposalSAID : SAID) (proofs : List ApprovalProof)
    (tipDigest : Digest)
    (hprev : ∀ e ∈ l1, l1EnactedSelfContained e)
    (hsaid : proposalSAID ≠ 0)
    (hproofs : proofs.length > 0) :
    ∀ e ∈ appendEnacted l1 serverK sig proposalSAID proofs tipDigest,
      l1EnactedSelfContained e := by
  intro e he
  simp [appendEnacted] at he
  cases he with
  | inl h =>
    subst h
    simp [l1EnactedSelfContained, hsaid, hproofs]
  | inr h =>
    exact hprev e h

/-- Appending an expired event preserves selfContained. -/
theorem appendExpired_preserves_self_contained
    (l1 : L1) (serverK : Key) (sig : Signature)
    (proposalSAID : SAID) (tipDigest : Digest)
    (hprev : ∀ e ∈ l1, l1EnactedSelfContained e) :
    ∀ e ∈ appendExpired l1 serverK sig proposalSAID tipDigest,
      l1EnactedSelfContained e := by
  intro e he
  simp [appendExpired] at he
  cases he with
  | inl h =>
    subst h
    simp [l1EnactedSelfContained]
  | inr h =>
    exact hprev e h

end KelGroups
