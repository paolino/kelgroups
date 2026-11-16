{- |
Module      : KelGroups.Vote.State
Description : Vote payload shapes mirrored from the Lean model
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

The vote payload (open-question set and append-only closure log) and
the single verdict site. No membership lives here, no clock, no
time-like field: the franchise is read from the GroupView on every
call.
-}
module KelGroups.Vote.State
    ( Question (..)
    , ClosureRecord (..)
    , VoteState (..)
    , emptyVoteState
    , franchise
    , franchiseSize
    , isResponsabile
    , verdictOf
    , lookupQuestion
    , closureCauseOf
    ) where

import Data.Text (Text)
import KelGroups.GroupView (GroupView, adminCount, admins, isAdmin)
import KelGroups.Vote.Types
    ( ClosureCause (..)
    , QuestionId
    , QuestionKind (..)
    , Threshold
    , Verdict (..)
    )
import Numeric.Natural (Natural)

{- | A question as it stands while open: kind fixed at opening,
proposer recorded, and the two tallies. No time-like field exists.
-}
data Question = Question
    { questionKind :: QuestionKind
    -- ^ Fixed at opening; a permission kind carries its designee
    , questionProposer :: Text
    -- ^ Substrate member key of the proposer
    , questionAssents :: [Text]
    -- ^ Substrate member keys recorded for assent
    , questionDissents :: [Text]
    -- ^ Substrate member keys recorded for dissent
    }
    deriving stock (Eq, Ord, Show)

{- | A closure record: the question as it stood when it left the open
set, the verdict it closed under (never 'Open'), and the observable
cause. It carries no member snapshot.
-}
data ClosureRecord = ClosureRecord
    { closureQuestionId :: QuestionId
    -- ^ Which question left the open set
    , closureQuestion :: Question
    -- ^ The question as it stood at closure
    , closureVerdict :: Verdict
    -- ^ The verdict it closed under (never 'Open')
    , closureCause :: ClosureCause
    -- ^ The observable cause
    }
    deriving stock (Eq, Ord, Show)

{- | The vote payload. 'closed' is append-only: closing a question is
removing it from the open set and appending a closure record, as one
operation, never a silent deletion.
-}
data VoteState = VoteState
    { openQuestions :: [(QuestionId, Question)]
    -- ^ The open-question set
    , closed :: [ClosureRecord]
    -- ^ Append-only closure log
    }
    deriving stock (Eq, Ord, Show)

-- | The empty payload: no open questions, no closures.
emptyVoteState :: VoteState
emptyVoteState = VoteState{openQuestions = [], closed = []}

{- | The franchise: the keys of the current responsabili, members
holding the admin grant. Read from the view, never stored.
-}
franchise :: GroupView -> [Text]
franchise = admins

{- | Number of current responsabili: the argument a threshold policy
is read at.
-}
franchiseSize :: GroupView -> Natural
franchiseSize = adminCount

-- | A key is a responsabile iff it is a member holding the admin grant.
isResponsabile :: Text -> GroupView -> Bool
isResponsabile = isAdmin

{- | The only place a verdict is decided. The threshold is consulted
only for collective questions, at the current franchise size, on both
sides: recorded assents against it, then recorded dissents against the
same count, then open. A permission question's verdict never consults
the threshold or a tally count: the designee's recorded assent makes
it positive, their recorded dissent negative, absence of both open.
-}
verdictOf :: Threshold -> GroupView -> Question -> Verdict
verdictOf threshold view question = case questionKind question of
    Collective
        | count (questionAssents question) >= required -> Positive
        | count (questionDissents question) >= required -> Negative
        | otherwise -> Open
      where
        required = threshold (franchiseSize view)
        count :: [Text] -> Natural
        count = fromIntegral . length
    Permission designee
        | designee `elem` questionAssents question -> Positive
        | designee `elem` questionDissents question -> Negative
        | otherwise -> Open

-- | The open question with the given id, if any; the first of its id.
lookupQuestion :: QuestionId -> VoteState -> Maybe Question
lookupQuestion qid = lookup qid . openQuestions

{- | The observable closure cause, decided from the view at closure
time. A tally is stale exactly when the deciding side records a key
the current franchise no longer counts: that closure is a franchise
change, otherwise a plain tally.
-}
closureCauseOf :: GroupView -> Question -> Verdict -> ClosureCause
closureCauseOf view question = \case
    Positive
        | all (`isResponsabile` view) (questionAssents question) -> Tally
        | otherwise -> FranchiseChange
    Negative
        | all (`isResponsabile` view) (questionDissents question) -> Tally
        | otherwise -> FranchiseChange
    Open -> Tally
