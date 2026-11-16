{- |
Module      : KelGroups.GroupView
Description : Read-only projection of a roster for the vote machine
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

The view the vote machine reads its franchise from. It is built from a
sovereign 'KelGroups.Group.Roster' and from nothing else, it exposes
queries only, and it carries no capability to return or replace a
roster: a fold handed a 'GroupView' can read membership and admin
standing and can produce nothing but vote payload.

The franchise is the admins of the view: the roster's admins that are
also members, in the roster's own order. Admission keeps every admin a
member; the filter makes the view agree with the Lean @GroupView@
(an admin is a member holding an admin role) for any roster.
-}
module KelGroups.GroupView
    ( GroupView
    , groupView
    , isMember
    , isAdmin
    , admins
    , adminCount
    ) where

import Data.Text (Text)
import KelGroups.Group qualified as Group
import Numeric.Natural (Natural)

{- | An immutable projection of a roster. The constructor is not
exported: a view is built by 'groupView' only.
-}
data GroupView = GroupView
    { viewMembers :: [Text]
    , viewAdmins :: [Text]
    }
    deriving stock (Eq, Show)

-- | Project the members and the admin standing of a roster.
groupView :: Group.Roster -> GroupView
groupView r =
    GroupView
        { viewMembers = Group.members r
        , viewAdmins = filter (`elem` Group.members r) (Group.admins r)
        }

-- | Is the key a current member of the roster?
isMember :: Text -> GroupView -> Bool
isMember k = elem k . viewMembers

-- | Is the key a current member holding the admin grant?
isAdmin :: Text -> GroupView -> Bool
isAdmin k = elem k . viewAdmins

-- | The franchise: the admin members, in the roster's admin order.
admins :: GroupView -> [Text]
admins = viewAdmins

-- | The size of the franchise.
adminCount :: GroupView -> Natural
adminCount = fromIntegral . length . viewAdmins
