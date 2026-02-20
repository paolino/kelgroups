{- |
Module      : KelGroups.Fold
Description : Fold a KEL into group condition
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

The group condition is computed by folding the sequence
of group events. Base events update members, roles, and
pending proposals. Application events are folded by a
user-supplied function.
-}
module KelGroups.Fold
    ( foldGroup
    , applyEvent
    , AppFold
    , enact
    , applyPropose
    ) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text, pack)
import KelGroups.Event
    ( BaseEvent (..)
    , GroupEvent (..)
    , Proposal (..)
    )
import KelGroups.State
    ( GroupState (..)
    , PendingProposal (..)
    , emptyState
    , majority
    )
import KelGroups.Types (Member (..))

{- | Application fold function. Given the current
application fold result and an application event,
produce the new fold result.
-}
type AppFold a = a -> a -> a

{- | Fold a sequence of signed group events into a
group condition. Each event is tagged with the signer's
CESR public key.
-}
foldGroup
    :: AppFold a
    -> a
    -- ^ Initial application fold value
    -> [(Text, GroupEvent a)]
    -- ^ Events with signer public keys
    -> GroupState a
foldGroup appFoldFn initial =
    foldl (applyEvent appFoldFn) (emptyState initial)

{- | Apply a single event to the group condition.
Does not validate — assumes the event has already
been validated.
-}
applyEvent
    :: AppFold a
    -> GroupState a
    -> (Text, GroupEvent a)
    -> GroupState a
applyEvent appFoldFn gs (signer, evt) = case evt of
    Base baseEvt -> applyBase gs signer baseEvt
    App appEvt ->
        gs{appFold = appFoldFn (appFold gs) appEvt}

applyBase
    :: GroupState a
    -> Text
    -> BaseEvent
    -> GroupState a
applyBase gs signer = \case
    Propose proposal' ->
        applyPropose gs signer proposal'
    Approve proposalId ->
        applyApprove gs signer proposalId

applyPropose
    :: GroupState a
    -> Text
    -> Proposal
    -> GroupState a
applyPropose gs signer proposal' =
    let pid = proposalDigest proposal'
        pp =
            PendingProposal
                { proposal = proposal'
                , proposer = signer
                , approvals = Set.singleton signer
                }
        gs' =
            gs
                { pendingProposals =
                    Map.insert
                        pid
                        pp
                        (pendingProposals gs)
                }
    in  tryEnact gs' pid

applyApprove
    :: GroupState a
    -> Text
    -> Text
    -> GroupState a
applyApprove gs signer proposalId =
    case Map.lookup
        proposalId
        (pendingProposals gs) of
        Nothing -> gs
        Just pp ->
            let pp' =
                    pp
                        { approvals =
                            Set.insert
                                signer
                                (approvals pp)
                        }
                gs' =
                    gs
                        { pendingProposals =
                            Map.insert
                                proposalId
                                pp'
                                (pendingProposals gs)
                        }
            in  tryEnact gs' proposalId

{- | Try to enact a proposal if it has reached
admin majority.
-}
tryEnact
    :: GroupState a -> Text -> GroupState a
tryEnact gs proposalId =
    case Map.lookup
        proposalId
        (pendingProposals gs) of
        Nothing -> gs
        Just pp
            | Set.size (approvals pp)
                >= majority gs ->
                let gs' = enact gs (proposal pp)
                in  gs'
                        { pendingProposals =
                            Map.delete
                                proposalId
                                (pendingProposals gs')
                        }
            | otherwise -> gs

-- | Enact a proposal by modifying the group condition.
enact :: GroupState a -> Proposal -> GroupState a
enact gs = \case
    IntroduceMember pubKey roles ->
        gs
            { members =
                Map.insert
                    pubKey
                    Member
                        { memberKey = pubKey
                        , memberRoles = roles
                        }
                    (members gs)
            }
    RemoveMember pubKey ->
        gs{members = Map.delete pubKey (members gs)}
    ChangeRoles pubKey roles ->
        gs
            { members =
                Map.adjust
                    (\m -> m{memberRoles = roles})
                    pubKey
                    (members gs)
            }

{- | Compute a proposal digest. This is a placeholder
that uses 'show' — in production this should use a
proper cryptographic hash via keri-hs.
-}
proposalDigest :: Proposal -> Text
proposalDigest p =
    -- TODO: use proper SAID/hash via keri-hs
    "proposal:" <> pack (show p)
