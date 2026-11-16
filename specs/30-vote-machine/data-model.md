# Data — 30 vote machine

| id | type | shape | invariant |
|---|---|---|---|
| data-group-view | `GroupView` | abstract (constructor not exported); built only by `groupView` from a `Roster` | read-only: no exported function returns a modified view or a `Roster` |
| data-vote-event | `VoteEvent` | `OpenQuestion QuestionId QuestionKind` \| `Cast QuestionId Ballot` \| `Renounce QuestionId` | no membership constructor; carries no signer |
| data-vote-error | `VoteError` | `NotResponsabile` \| `QuestionNotFound` \| `NotDesignee` \| `NotProposer` | four distinct constructors, Lean order |
| data-question | `Question` (exists) | unchanged | opened with empty `questionAssents` and `questionDissents` |
| data-closure-record | `ClosureRecord` (exists) | unchanged | `closureVerdict` is never `Open` |
| data-vote-state | `VoteState` (exists) | unchanged | a question id is in at most one of open set and closure log; closure log append-only |
| data-threshold | `Threshold` (exists) | `Natural -> Natural` | never given a value inside the library |

Keys stay `Text` (Lean `Key = String`). Lists keep Lean order: `setInsert` prepends when absent,
`assocInsert` erases then prepends, closure records are appended.
