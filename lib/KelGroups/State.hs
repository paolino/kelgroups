{- |
Module      : KelGroups.State
Description : Group condition derived from KEL fold
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

The group condition (configuration) is derived entirely
by folding the KEL. There is no mutable external state.
-}
module KelGroups.State
    ( GroupState (..)
    , PendingProposal (..)
    , emptyState
    , adminCount
    , majority
    , isAdmin
    , isMember
    ) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import KelGroups.Event (Proposal)
import KelGroups.Types
    ( Member (..)
    , ProposalId
    , Role (..)
    )

{- | The group condition, derived from folding the KEL.
Parameterized by the application fold result @a@.
-}
data GroupState a = GroupState
    { members :: Map Text Member
    -- ^ All members, keyed by CESR public key
    , pendingProposals :: Map ProposalId PendingProposal
    -- ^ Proposals awaiting approval
    , appFold :: a
    -- ^ Application-level fold result
    }
    deriving stock (Show, Eq)

-- | A proposal that has been submitted but not yet enacted.
data PendingProposal = PendingProposal
    { proposal :: Proposal
    -- ^ The proposed change
    , proposer :: Text
    -- ^ CESR public key of the proposing admin
    , approvals :: Set Text
    -- ^ CESR public keys of admins who approved
    }
    deriving stock (Show, Eq)

-- | Empty group condition with no members.
emptyState :: a -> GroupState a
emptyState = GroupState Map.empty Map.empty

-- | Count current admins.
adminCount :: GroupState a -> Int
adminCount =
    Map.size
        . Map.filter
            (Set.member Admin . memberRoles)
        . members

{- | Compute required majority for admin votes.
@ceil(numAdmins / 2)@. With zero admins, returns 0
(bootstrap mode).
-}
majority :: GroupState a -> Int
majority gs =
    let n = adminCount gs
    in  (n + 1) `div` 2

-- | Check if a public key belongs to an admin.
isAdmin :: Text -> GroupState a -> Bool
isAdmin pubKey gs =
    case Map.lookup pubKey (members gs) of
        Just m -> Set.member Admin (memberRoles m)
        Nothing -> False

-- | Check if a public key belongs to a member.
isMember :: Text -> GroupState a -> Bool
isMember pubKey = Map.member pubKey . members
