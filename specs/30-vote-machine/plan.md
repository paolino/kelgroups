# Plan — 30 vote machine

One pull request, one slice (`vote-machine`), OWNER topology. Team (A-001): ticket owner
claude opus 5.5 high; commit owner claude sonnet 5.5 high; persistent auditor codex
gpt-6.1-sol high. draft=NONE. gate-authors=NONE (operator team 2026-11-08, A-001).

Strategy: transcribe the Lean definitions one for one into Haskell modules that mirror the Lean
file split; keep Lean list operations' order (prepend on insert, append on closure). Tests port
the Lean executed witnesses as unit cases and the fold/sweep/validate theorems as QuickCheck
properties over generated rosters, thresholds and event traces.

Constraints: kelgroups main e476356 is the base. Out of scope: #42-#45, PR52, server, client,
store, action line, Lean edits in either repository, reactivegas. The old branch
feat/30-verdict-site (bdeba37, pre-sovereign tree) is read-only seed only.

Re-count for the PR body: of the 26 Integration.lean names, present after this PR = the 7 vote
names (Verdict, Ballot, ClosureRecord, foldVote, sweepClosures, Question, Threshold) plus
GroupView = 8; the other 18 were deleted by kelgroups #40 (729d497) and are recorded as
superseded pending a Lean re-specification of Integration.lean.
