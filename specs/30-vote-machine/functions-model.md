# Functions — 30 vote machine

Each function computes the Lean namesake on master 73e9440. Where a Haskell name differs, the
Lean name is in the last column.

| id | module | signature | Lean |
|---|---|---|---|
| fn-group-view | GroupView | `groupView :: Roster -> GroupView` | (projection; franchise = `admins` of the roster) |
| fn-view-is-member | GroupView | `isMember :: Text -> GroupView -> Bool` | `GroupView.isMember` |
| fn-view-is-admin | GroupView | `isAdmin :: Text -> GroupView -> Bool` | `GroupView.isAdmin` |
| fn-view-admins | GroupView | `admins :: GroupView -> [Text]` | `GroupView.admins` |
| fn-view-admin-count | GroupView | `adminCount :: GroupView -> Natural` | `GroupView.adminCount` |
| fn-empty-state | Vote.State | `emptyVoteState :: VoteState` | `emptyVoteState` |
| fn-franchise | Vote.State | `franchise :: GroupView -> [Text]` | `franchise` |
| fn-franchise-size | Vote.State | `franchiseSize :: GroupView -> Natural` | `franchiseSize` |
| fn-is-responsabile | Vote.State | `isResponsabile :: Text -> GroupView -> Bool` | `isResponsabile` |
| fn-verdict-of | Vote.State | `verdictOf :: Threshold -> GroupView -> Question -> Verdict` | `verdictOf` |
| fn-lookup-question | Vote.State | `lookupQuestion :: QuestionId -> VoteState -> Maybe Question` | `lookupQuestion` |
| fn-closure-cause | Vote.State | `closureCauseOf :: GroupView -> Question -> Verdict -> ClosureCause` | `closureCause` (renamed: the record field `closureCause` exists) |
| fn-validate | Vote.Validate | `validateVoteEvent :: Threshold -> GroupView -> VoteState -> Text -> VoteEvent -> Either VoteError ()` | `validateVoteEvent` |
| fn-place-ballot | Vote.Fold | `placeBallot :: Text -> Ballot -> Question -> Question` | `placeBallot` |
| fn-sweep-step | Vote.Fold | `sweepStep :: Threshold -> GroupView -> (QuestionId, Question) -> Maybe ClosureRecord` | `sweepStep` |
| fn-sweep | Vote.Fold | `sweepClosures :: Threshold -> GroupView -> VoteState -> VoteState` | `sweepClosures` |
| fn-effect | Vote.Fold | `effectedState :: VoteState -> Text -> VoteEvent -> VoteState` | `effectedState` |
| fn-departure | Vote.Fold | `closeProposerQuestions :: Text -> VoteState -> VoteState` | `closeProposerQuestions` |
| fn-step-checked | Vote.Fold | `applyVoteEventChecked :: Threshold -> GroupView -> VoteState -> Text -> VoteEvent -> Either VoteError VoteState` | `applyVoteEventChecked` |
| fn-step | Vote.Fold | `applyVoteEvent :: Threshold -> GroupView -> VoteState -> Text -> VoteEvent -> VoteState` | `applyVoteEvent` |
| fn-fold | Vote.Fold | `foldVote :: Threshold -> GroupView -> [(Text, VoteEvent)] -> VoteState` | `foldVote` |
| fn-fold-from | Vote.Fold | `foldFrom :: Threshold -> GroupView -> VoteState -> [(Text, VoteEvent)] -> VoteState` | `foldFrom` |

Effects: all pure. Lean `Nat` lengths are `Natural` where they meet `Threshold`.
