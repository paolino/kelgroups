/-
  KelGroups.Sovereign.Axioms — every theorem of T0–T6, and the concrete
  witness of the assumptions structure, depends on Lean's standard axioms
  only: no `sorryAx`, no keri-lean axiom. A change in any list fails the build.
-/
import KelGroups.Sovereign.Theorems
import KelGroups.Sovereign.Example

namespace KelGroups.Sovereign

/-- info: 'KelGroups.Sovereign.admit_iff' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in #print axioms admit_iff

/-- info: 'KelGroups.Sovereign.admit_atomic' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in #print axioms admit_atomic

/-- info: 'KelGroups.Sovereign.rotate_effect' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in #print axioms rotate_effect

/-- info: 'KelGroups.Sovereign.admitted_prev_is_head' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in #print axioms admitted_prev_is_head

/-- info: 'KelGroups.Sovereign.chain_is_line' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in #print axioms chain_is_line

/-- info: 'KelGroups.Sovereign.replay_refused' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in #print axioms replay_refused

/-- info: 'KelGroups.Sovereign.resend_refused' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in #print axioms resend_refused

/-- info: 'KelGroups.Sovereign.stale_p_refused' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in #print axioms stale_p_refused

/-- info: 'KelGroups.Sovereign.stale_after_rotation' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in #print axioms stale_after_rotation

/-- info: 'KelGroups.Sovereign.stale_after_action' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in #print axioms stale_after_action

/-- info: 'KelGroups.Sovereign.stale_forever' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in #print axioms stale_forever

/-- info: 'KelGroups.Sovereign.admitted_signer_member' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in #print axioms admitted_signer_member

/-- info: 'KelGroups.Sovereign.admitted_admin_signer' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in #print axioms admitted_admin_signer

/-- info: 'KelGroups.Sovereign.leave_only_signer' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in #print axioms leave_only_signer

/-- info: 'KelGroups.Sovereign.removed_not_member' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in #print axioms removed_not_member

/-- info: 'KelGroups.Sovereign.nonmember_refused' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in #print axioms nonmember_refused

/-- info: 'KelGroups.Sovereign.member_gained_only_by_add' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in #print axioms member_gained_only_by_add

/-- info: 'KelGroups.Sovereign.admin_guard' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in #print axioms admin_guard

/-- info: 'KelGroups.Sovereign.concrete' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms concrete

end KelGroups.Sovereign
