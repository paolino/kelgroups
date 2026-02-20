{- |
Module      : KelGroups.Types
Description : Core types for KEL-based group management
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

Base types for members, roles, and group configuration.
The library is polymorphic over an application event type
@a@ which carries domain-specific semantics.
-}
module KelGroups.Types
    ( Role (..)
    , RoleName
    , Member (..)
    , GroupConfig (..)
    , RoleDef (..)
    , ProposalId
    ) where

import Data.Map.Strict (Map)
import Data.Set (Set)
import Data.Text (Text)

-- | A role name is an opaque text label.
type RoleName = Text

-- | A proposal identifier (digest of the proposal).
type ProposalId = Text

{- | A role in the group. 'Admin' is the only role
with base-system meaning: admins vote on member and
role changes. Application roles are opaque labels
interpreted by the application layer.
-}
data Role
    = -- | Distinguished base-system role
      Admin
    | -- | Application-defined role
      AppRole RoleName
    deriving stock (Eq, Ord, Show)

-- | A group member with their public key and roles.
data Member = Member
    { memberKey :: Text
    -- ^ CESR-encoded public key
    , memberRoles :: Set Role
    -- ^ Current set of roles
    }
    deriving stock (Eq, Show)

{- | Definition of an application role with
preconditions for adding and removing the role.
The predicates receive a fold function that can
extract information from the KEL.
-}
data RoleDef a = RoleDef
    { canAdd :: a -> Bool
    -- ^ Can this role be added given current app fold?
    , canRemove :: a -> Bool
    -- ^ Can this role be removed given current app fold?
    }

{- | Group configuration, parameterized by the
application event type @a@. Supplied at server startup.
-}
newtype GroupConfig a = GroupConfig
    { roleDefs :: Map RoleName (RoleDef a)
    -- ^ Application role definitions with predicates
    }
