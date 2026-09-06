{- |
Module      : KelGroups.Vote.State
Description : Vote payload shapes mirrored from the Lean model
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

Declarations only: the open-question set and the append-only closure
log. No membership lives here, no clock, no time-like field. No
transitions, no verdict logic, no fold wiring: those are later slices
and are out of scope here.
-}
module KelGroups.Vote.State
    ( Question (..)
    , ClosureRecord (..)
    , VoteState (..)
    ) where

import Data.Text (Text)
import KelGroups.Vote.Types
    ( ClosureCause
    , QuestionId
    , QuestionKind
    , Verdict
    )

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
