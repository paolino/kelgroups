{- |
Module      : KelGroups.Vote.Fold
Description : The vote fold
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

One step function, 'applyVoteEvent', and the list fold 'foldVote' over
it. Every function takes the 'GroupView' explicitly: the franchise a
sweep recomputes against is read from the roster, not from the payload.

Three load-bearing shapes:

* 'placeBallot' is the one-position-per-responsabile placement: casting
  assent inserts into the assent list and erases from the dissent list;
  dissent is symmetric.
* 'sweepClosures' re-evaluates every open question against the supplied
  view and threshold and closes, in the same step, each one that has
  reached a verdict. 'applyVoteEvent' sweeps after every admitted
  event's effect, because the verdict depends on the current franchise.
  A rejected event reaches neither its effect nor the sweep.
* Closure is removal from the open set plus an appended closure
  record, as one operation. No branch erases a question without
  writing its record.

A proposer's renounce closes their question negatively with cause
'Renounced'; 'closeProposerQuestions' closes a departing proposer's
open questions negatively with cause 'ProposerDeparted'.

List order follows the Lean: a set insert prepends when absent, an
association insert erases and prepends, closure records are appended.
There is no clock and no time-like field: the sweep closes nothing by
the passage of anything.
-}
module KelGroups.Vote.Fold
    ( placeBallot
    , sweepStep
    , sweepClosures
    , effectedState
    , closeProposerQuestions
    , applyVoteEventChecked
    , applyVoteEvent
    , foldVote
    , foldFrom
    ) where

import Data.List (delete, foldl')
import Data.Maybe (isNothing, mapMaybe)
import Data.Text (Text)
import KelGroups.GroupView (GroupView)
import KelGroups.Vote.Event (VoteEvent (..))
import KelGroups.Vote.State
    ( ClosureRecord (..)
    , Question (..)
    , VoteState (..)
    , closureCauseOf
    , emptyVoteState
    , lookupQuestion
    , verdictOf
    )
import KelGroups.Vote.Types
    ( Ballot (..)
    , ClosureCause (..)
    , QuestionId
    , QuestionKind
    , Threshold
    , Verdict (..)
    )
import KelGroups.Vote.Validate (VoteError, validateVoteEvent)

-- | Insert in front unless already present.
setInsert :: Text -> [Text] -> [Text]
setInsert value values
    | value `elem` values = values
    | otherwise = value : values

-- | Remove the first entry under the key.
assocErase
    :: QuestionId -> [(QuestionId, Question)] -> [(QuestionId, Question)]
assocErase _ [] = []
assocErase key ((candidate, value) : rest)
    | candidate == key = rest
    | otherwise = (candidate, value) : assocErase key rest

-- | Erase the key, then put the entry in front.
assocInsert
    :: QuestionId
    -> Question
    -> [(QuestionId, Question)]
    -> [(QuestionId, Question)]
assocInsert key value entries = (key, value) : assocErase key entries

{- | The one-position-per-responsabile placement. Inserting into one
list erases from the other; re-casting the same position changes
neither tally; switching positions moves the voter.
-}
placeBallot :: Text -> Ballot -> Question -> Question
placeBallot voter ballot question = case ballot of
    Assent ->
        question
            { questionAssents = setInsert voter (questionAssents question)
            , questionDissents = delete voter (questionDissents question)
            }
    Dissent ->
        question
            { questionDissents = setInsert voter (questionDissents question)
            , questionAssents = delete voter (questionAssents question)
            }

{- | One open question's sweep outcome: 'Nothing' keeps the question
open, and a record closes it under the recorded verdict and its
observable cause.
-}
sweepStep
    :: Threshold
    -> GroupView
    -> (QuestionId, Question)
    -> Maybe ClosureRecord
sweepStep threshold view (questionId, question) =
    case verdictOf threshold view question of
        Open -> Nothing
        verdict ->
            Just
                ClosureRecord
                    { closureQuestionId = questionId
                    , closureQuestion = question
                    , closureVerdict = verdict
                    , closureCause = closureCauseOf view question verdict
                    }

{- | Evaluate every open question and close, in this same step, each
one whose verdict under the supplied view and threshold is positive or
negative. Closed questions move to the closure log with their verdict
and observable cause; nothing is dropped silently.
-}
sweepClosures :: Threshold -> GroupView -> VoteState -> VoteState
sweepClosures threshold view gs =
    gs
        { openQuestions =
            filter
                (\entry -> verdictOf threshold view (snd entry) == Open)
                (openQuestions gs)
        , closed =
            closed gs <> mapMaybe (sweepStep threshold view) (openQuestions gs)
        }

{- | The event's own effect on the payload, before the recompute-and-close
sweep. Effects assume an already-admitted event: all signer
authorization happens in 'validateVoteEvent'. An opening never
overwrites or revives an existing id: decided questions stay decided.
A renounce, admitted only for the proposer, closes the named question
negatively with cause 'Renounced', the record carrying the question as
it stood.
-}
effectedState :: VoteState -> Text -> VoteEvent -> VoteState
effectedState gs signer = \case
    OpenQuestion questionId kind
        | isNothing (lookupQuestion questionId gs)
        , not (any ((== questionId) . closureQuestionId) (closed gs)) ->
            gs
                { openQuestions =
                    assocInsert
                        questionId
                        (freshQuestion kind)
                        (openQuestions gs)
                }
        | otherwise -> gs
    Cast questionId ballot -> case lookupQuestion questionId gs of
        Just question ->
            gs
                { openQuestions =
                    assocInsert
                        questionId
                        (placeBallot signer ballot question)
                        (openQuestions gs)
                }
        Nothing -> gs
    Renounce questionId -> case lookupQuestion questionId gs of
        Just question ->
            VoteState
                { openQuestions = assocErase questionId (openQuestions gs)
                , closed =
                    closed gs
                        <> [ ClosureRecord
                                { closureQuestionId = questionId
                                , closureQuestion = question
                                , closureVerdict = Negative
                                , closureCause = Renounced
                                }
                           ]
                }
        Nothing -> gs
  where
    freshQuestion :: QuestionKind -> Question
    freshQuestion kind =
        Question
            { questionKind = kind
            , questionProposer = signer
            , questionAssents = []
            , questionDissents = []
            }

{- | Proposer departure. Every open question whose proposer is the
given key closes negatively with cause 'ProposerDeparted', in open-set
order, the record carrying the question as it stood; no other question
is touched. Not a tally: it reads no view and no threshold.
-}
closeProposerQuestions :: Text -> VoteState -> VoteState
closeProposerQuestions proposer gs =
    VoteState
        { openQuestions =
            filter ((/= proposer) . questionProposer . snd) (openQuestions gs)
        , closed =
            closed gs
                <> map
                    ( \(questionId, question) ->
                        ClosureRecord
                            { closureQuestionId = questionId
                            , closureQuestion = question
                            , closureVerdict = Negative
                            , closureCause = ProposerDeparted
                            }
                    )
                    (filter ((== proposer) . questionProposer . snd) (openQuestions gs))
        }

{- | Checked vote step: exactly one 'validateVoteEvent' decision. On
success that decision dominates 'effectedState' and 'sweepClosures'; on
refusal neither runs.
-}
applyVoteEventChecked
    :: Threshold
    -> GroupView
    -> VoteState
    -> Text
    -> VoteEvent
    -> Either VoteError VoteState
applyVoteEventChecked threshold view gs signer event =
    case validateVoteEvent threshold view gs signer event of
        Left err -> Left err
        Right () ->
            Right (sweepClosures threshold view (effectedState gs signer event))

{- | The state-returning fold step. It erases the checked result:
rejection is payload identity.
-}
applyVoteEvent
    :: Threshold -> GroupView -> VoteState -> Text -> VoteEvent -> VoteState
applyVoteEvent threshold view gs signer event =
    case validateVoteEvent threshold view gs signer event of
        Right () -> sweepClosures threshold view (effectedState gs signer event)
        Left _ -> gs

{- | The fold: every signed event, in order, from the empty payload
under one view.
-}
foldVote :: Threshold -> GroupView -> [(Text, VoteEvent)] -> VoteState
foldVote threshold view = foldFrom threshold view emptyVoteState

-- | 'foldVote' over a trace, continued from an arbitrary payload.
foldFrom
    :: Threshold
    -> GroupView
    -> VoteState
    -> [(Text, VoteEvent)]
    -> VoteState
foldFrom threshold view =
    foldl'
        ( \current (signer, event) -> applyVoteEvent threshold view current signer event
        )
