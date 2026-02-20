-- | Core types mirroring Haskell KelGroups.Types.
module KelGroups.Client.Types
  ( Role(..)
  , Member
  ) where

import Prelude

import Data.Set (Set)

-- | A role in the group.
data Role
  = Admin
  | AppRole String

derive instance eqRole :: Eq Role
derive instance ordRole :: Ord Role

instance showRole :: Show Role where
  show Admin = "Admin"
  show (AppRole name) = "AppRole " <> name

-- | A group member identified by CESR public key.
type Member =
  { key :: String
  , roles :: Set Role
  }
