{- |
Module      : KelGroups.Vote.Validate
Description : Admissibility of a signed vote event
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

Distinct admissibility errors and the one validation entry point. The
authorization decision is total and explicit over the complete
'VoteEvent' surface: every constructor is enumerated and there is no
wildcard, so a constructor added later does not compile until it is
given a decision.

Every signed event requires the signer to be a current responsabile in
the 'GroupView'. A renounce by a responsabile who is not the question's
proposer is refused with 'NotProposer', and a cast on a permission
question by a responsabile who is not its designee with 'NotDesignee'.
The checks run in one order: the standing check, then the lookup, then
the identity check. This function is the sole producer of these errors.
-}
module KelGroups.Vote.Validate
    ( VoteError (..)
    , validateVoteEvent
    ) where

import Data.Text (Text)
import KelGroups.GroupView (GroupView)
import KelGroups.Vote.Event (VoteEvent (..))
import KelGroups.Vote.State
    ( Question (..)
    , VoteState
    , isResponsabile
    , lookupQuestion
    )
import KelGroups.Vote.Types (QuestionKind (..), Threshold)

{- | Distinct admissibility errors. The identity of the first error is
part of the contract.
-}
data VoteError
    = NotResponsabile
    | QuestionNotFound
    | NotDesignee
    | NotProposer
    deriving stock (Eq, Ord, Show)

{- | Validate one signed event against the view and the current vote
payload. Success implies the signer is a responsabile of the view, for
every event in the sum. The threshold is part of the shape every
verdict-deciding function shares; admissibility does not consult it.
-}
validateVoteEvent
    :: Threshold
    -> GroupView
    -> VoteState
    -> Text
    -> VoteEvent
    -> Either VoteError ()
validateVoteEvent _threshold view gs signer = \case
    OpenQuestion _ _
        | standing -> Right ()
        | otherwise -> Left NotResponsabile
    Cast questionId _
        | not standing -> Left NotResponsabile
        | otherwise -> case lookupQuestion questionId gs of
            Nothing -> Left QuestionNotFound
            Just question -> case questionKind question of
                Collective -> Right ()
                Permission designee
                    | signer == designee -> Right ()
                    | otherwise -> Left NotDesignee
    Renounce questionId
        | not standing -> Left NotResponsabile
        | otherwise -> case lookupQuestion questionId gs of
            Nothing -> Left QuestionNotFound
            Just question
                | signer == questionProposer question -> Right ()
                | otherwise -> Left NotProposer
  where
    standing = isResponsabile signer view
