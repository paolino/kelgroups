{- |
Module      : KelGroups.Event
Description : Base and group event types
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

Events that can be appended to a group KEL. Base events
handle member management and role changes. Application
events are opaque to the base system.
-}
module KelGroups.Event
    ( GroupEvent (..)
    , BaseEvent (..)
    , Proposal (..)
    ) where

import Data.Set (Set)
import Data.Text (Text)
import KelGroups.Types
    ( ProposalId
    , Role
    )

{- | A group event: either a base infrastructure event
or an application-specific event.
-}
data GroupEvent a
    = -- | Base system event (members, roles, voting)
      Base BaseEvent
    | -- | Application event (opaque to base system)
      App a
    deriving stock (Show, Eq)

{- | Base events for group management. All member and
role changes follow a proposal + approval pattern.
-}
data BaseEvent
    = -- | Propose a change (by an admin)
      Propose Proposal
    | -- | Approve a pending proposal (by an admin)
      Approve ProposalId
    deriving stock (Show, Eq)

{- | A proposal for a group change. Proposals require
admin majority to take effect.
-}
data Proposal
    = -- | Add a new member with initial roles
      IntroduceMember
        Text
        -- ^ CESR-encoded public key
        (Set Role)
        -- ^ Initial roles (must include 'Admin' during bootstrap)
    | -- | Remove a member entirely
      RemoveMember
        Text
        -- ^ CESR-encoded public key
    | -- | Change a member's role set
      ChangeRoles
        Text
        -- ^ CESR-encoded public key
        (Set Role)
        -- ^ New role set
    deriving stock (Show, Eq)
