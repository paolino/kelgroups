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
-- Hash chain: singleton is valid
-- ============================================================

/-- A single inception event is a valid hash chain. -/
theorem singleton_chain_valid {α : Type}
    (payload : α) (sk : Key) (sigV : Signature) :
    hashChainValid
      [KELEvent.mk 0 none payload sk sigV] := by
  simp [hashChainValid]

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

end KelGroups
