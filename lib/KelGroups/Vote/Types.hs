{- |
Module      : KelGroups.Vote.Types
Description : Vote vocabulary mirrored from the Lean model
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

Declarations only: the type heads and constructors mandated by slice
S30-1. No transitions, no verdict logic, no fold wiring, no threshold
default: those are later slices and are out of scope here.
-}
module KelGroups.Vote.Types
    ( QuestionId
    , Threshold
    , Verdict (..)
    , Ballot (..)
    , QuestionKind (..)
    , ClosureCause (..)
    ) where

import Data.Text (Text)
import Numeric.Natural (Natural)

{- | Identifier of a question. The same 'Text' key space as the shared
substrate ('KelGroups.Types.Member' keys); no parallel key type is
introduced.
-}
type QuestionId = Text

{- | A threshold policy maps the current responsabile count to the
required count. A parameter everywhere: nothing here hard-codes a
policy, and no default is shipped. The domain is 'Natural', the
exact mirror of Lean @Nat@: no negative value and no bounded wrap
is representable, so no policy can carry a count the model cannot.
-}
type Threshold = Natural -> Natural

{- | Exactly three outcomes. 'Open' is a distinct constructor: never
negative plus a flag, never an 'Option'/'Maybe' of a two-valued type.
-}
data Verdict
    = Positive
    | Negative
    | Open
    deriving stock (Eq, Ord, Show)

{- | The two positions a responsabile can record. -}
data Ballot
    = Assent
    | Dissent
    deriving stock (Eq, Ord, Show)

{- | A question is either collective (tallied against the threshold) or
a permission addressed to exactly one designee. The designee is part
of the kind, so a permission question without a designee is not
representable. The designee is a substrate member key ('Text', as in
'KelGroups.Types.Member'); no parallel designee type is introduced.
-}
data QuestionKind
    = Collective
    | Permission Text
    deriving stock (Eq, Ord, Show)

{- | Why a question left the open set. All four causes are carried as
data, never as producers.
-}
data ClosureCause
    = Tally
    | FranchiseChange
    | ProposerDeparted
    | Renounced
    deriving stock (Eq, Ord, Show)
