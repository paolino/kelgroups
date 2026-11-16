# Tasks — 30 vote machine

## Slice vote-machine (OWNER)

- [ ] **group-view-projection** `KelGroups.GroupView` per fn-group-view … fn-view-admin-count.
- [ ] **vote-event-and-errors** `VoteEvent`, `VoteError` per data-vote-event, data-vote-error.
- [ ] **verdict-site** `emptyVoteState`, franchise functions, `verdictOf`, `lookupQuestion`,
      `closureCauseOf`.
- [ ] **validation** `validateVoteEvent` with S-12 refusals.
- [ ] **fold** `placeBallot`, `sweepStep`, `sweepClosures`, `effectedState`,
      `closeProposerQuestions`, `applyVoteEventChecked`, `applyVoteEvent`, `foldVote`, `foldFrom`.
- [ ] **lean-witnesses** every executed witness of `Vote/Tests.lean` reproduced as a unit case.
- [ ] **lean-theorems-as-properties** QuickCheck properties for: ballots_nodup_disjoint,
      open_questions_are_open, questions_partition, no_expiry, inadmissible_is_noop,
      nonresponsabile_event_noop, unfranchised_cast_noop, franchise_of_tallies,
      sweepClosures_idempotent, foldVote_wellFormed, verdictOf_threshold_congr; plus
      proposer-is-not-an-assent, renounce-and-departure-close-negatively and
      checked-step-agrees-with-step (`applyVoteEventChecked` is `Right (applyVoteEvent …)` exactly
      when `validateVoteEvent` is `Right ()`).
