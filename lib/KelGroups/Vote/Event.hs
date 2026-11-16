{- |
Module      : KelGroups.Vote.Event
Description : The events the vote machine folds
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

Questions only. The signer is supplied separately by the fold, so no
event carries a second author identity. There is no membership event
in the sum: membership has one writable store and it is not in this
machine.
-}
module KelGroups.Vote.Event
    ( VoteEvent (..)
    ) where

import KelGroups.Vote.Types
    ( Ballot
    , QuestionId
    , QuestionKind
    )

-- | A question event, signed by a responsabile outside the event.
data VoteEvent
    = OpenQuestion QuestionId QuestionKind
    | Cast QuestionId Ballot
    | Renounce QuestionId
    deriving stock (Eq, Ord, Show)
