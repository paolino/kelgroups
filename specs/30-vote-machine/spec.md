# 30 — vote machine over the sovereign roster

Issue: paolino/kelgroups#30 (epic #29); reactivegas#73. Ruling: reactivegas M2 desk A-001
(2026-11-16, option A). Lean source: paolino/reactivegas `origin/master` 73e9440,
`lean/KelGroups/Vote/{Types,State,Event,Validate,Fold}.lean` and `lean/KelGroups/Types.lean`
(`GroupView`, `setInsert`, `assocLookup`, `assocErase`, `assocInsert`).

Class: changes behaviour (new library behaviour; no existing behaviour changed).
Model position: Inside — the Lean Vote subtree on master specifies every function below.

## User stories

- As the reactivegas Haskell implementation (#67), I fold a list of signed vote events into a
  vote payload with exactly the verdicts, closures and refusals the Lean `foldVote` and
  `applyVoteEventChecked` produce, given a threshold policy I choose and a group roster.
- As a group, I choose the threshold policy when I set the group up; the library ships none.

## Requirements

- **vote-machine-follows-lean**: every exported function computes the same value as its Lean
  namesake for every input, including list order of open questions, tallies and closure log.
- **threshold-is-explicit**: every verdict-deciding function takes a `Threshold` argument; the
  library exports no threshold value (no default, no named instance).
- **franchise-is-roster-admins**: the franchise is the admins of a read-only view projected from
  the sovereign `Roster`; the vote payload stores no membership.
- **refusals-are-typed**: an inadmissible event yields one of four distinct errors, first error in
  the Lean order (not a responsabile, then question not found, then not the designee / not the
  proposer); a refused event changes no state.
- **proposer-is-not-an-assent** (#68): a new question opens with both tallies empty.
- **renounce-and-departure-close-negatively** (V-5): a proposer's renounce closes the question
  negatively with cause renounced; `closeProposerQuestions` closes every open question of a
  departing proposer negatively with cause proposerDeparted.
- **non-proposer-renounce-and-non-designee-ballot-refused** (S-12).
- **one-position-per-responsabile** (V-4): casting a ballot moves the voter out of the other tally.
- **closure-is-never-silent**: a question leaves the open set only with a closure record appended.
- **no-wiring**: no server route, client, store or action-line code changes.

## Observable success

`cabal test` runs a vote suite that (a) reproduces every executed witness of
`lean/KelGroups/Vote/Tests.lean` on master, and (b) checks as QuickCheck properties the Lean
theorems of `lean/KelGroups/Vote/Invariants.lean` that are statements about `foldVote`,
`applyVoteEvent`, `sweepClosures` and `validateVoteEvent` (list in tasks.md). Hosted CI
(`just ci`) is green on the PR head.
