{-# OPTIONS_GHC -Wno-orphans #-}

{- |
Module      : Generators
Description : Shared QuickCheck generators and orphan instances
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

Shared generators for group states, members, roles, and
proposals. Used by pure invariant specs and store-through
specs alike.
-}
module Generators
    ( arbitraryKey
    , freshKey
    , arbitraryGroupState
    , arbitraryWithAdmin
    , arbitraryWithTwoAdmins
    , arbitraryAdminRoles
    , arbitraryNonAdminRoles
    , gsWithAdminCount
    ) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text, pack)
import KelGroups.Event (Proposal (..))
import KelGroups.State (GroupState (..), adminCount)
import KelGroups.Types (Member (..), Role (..))
import Test.QuickCheck
    ( Arbitrary (..)
    , Gen
    , chooseInt
    , listOf
    , oneof
    , suchThat
    , vectorOf
    )

-- --------------------------------------------------------
-- Arbitrary instances
-- --------------------------------------------------------

instance Arbitrary Role where
    arbitrary :: Gen Role
    arbitrary =
        oneof
            [ pure Admin
            , AppRole . pack . ("role" <>) . show
                <$> chooseInt (0, 9)
            ]

instance Arbitrary Member where
    arbitrary :: Gen Member
    arbitrary = do
        key <- arbitraryKey
        roles <- Set.fromList <$> listOf arbitrary
        pure Member{memberKey = key, memberRoles = roles}

instance Arbitrary Proposal where
    arbitrary :: Gen Proposal
    arbitrary = do
        key <- arbitraryKey
        oneof
            [ IntroduceMember key . Set.fromList
                <$> listOf arbitrary
            , pure $ RemoveMember key
            , ChangeRoles key . Set.fromList
                <$> listOf arbitrary
            ]

-- --------------------------------------------------------
-- Key generators
-- --------------------------------------------------------

-- | Random key from a pool of 100.
arbitraryKey :: Gen Text
arbitraryKey =
    pack . ("key" <>) . show <$> chooseInt (0, 99)

-- | A key not present in the given group state.
freshKey :: GroupState () -> Gen Text
freshKey gs =
    arbitraryKey `suchThat` \k ->
        not $ Map.member k (members gs)

-- --------------------------------------------------------
-- GroupState generators
-- --------------------------------------------------------

-- | Generate a GroupState () with random members.
arbitraryGroupState :: Gen (GroupState ())
arbitraryGroupState = do
    n <- chooseInt (0, 10)
    ms <- vectorOf n arbitrary
    let memberMap =
            Map.fromList
                [(memberKey m, m) | m <- ms]
    pure
        GroupState
            { members = memberMap
            , pendingProposals = Map.empty
            , appFold = ()
            }

-- | Generate a GroupState with at least one admin.
arbitraryWithAdmin :: Gen (GroupState ())
arbitraryWithAdmin =
    arbitraryGroupState `suchThat` \gs ->
        adminCount gs > 0

-- | Generate a GroupState with at least 2 admins.
arbitraryWithTwoAdmins :: Gen (GroupState ())
arbitraryWithTwoAdmins =
    arbitraryGroupState `suchThat` \gs ->
        adminCount gs >= 2

-- | An admin-bearing role set (always contains Admin).
arbitraryAdminRoles :: Gen (Set.Set Role)
arbitraryAdminRoles = do
    extras <- listOf arbitrary
    pure $ Set.insert Admin (Set.fromList extras)

-- | A non-admin role set (never contains Admin).
arbitraryNonAdminRoles :: Gen (Set.Set Role)
arbitraryNonAdminRoles = do
    n <- chooseInt (0, 5)
    roles <-
        vectorOf n $
            AppRole . pack . ("role" <>) . show
                <$> chooseInt (0, 9)
    pure $ Set.fromList roles

{- | Build a GroupState with exactly @n@ admin members.
Used to test majority properties directly.
-}
gsWithAdminCount :: Int -> GroupState ()
gsWithAdminCount n =
    GroupState
        { members =
            Map.fromList
                [ (key i, adminMember (key i))
                | i <- [1 .. n]
                ]
        , pendingProposals = Map.empty
        , appFold = ()
        }
  where
    key :: Int -> Text
    key i = "admin" <> pack (show i)
    adminMember :: Text -> Member
    adminMember k =
        Member
            { memberKey = k
            , memberRoles = Set.singleton Admin
            }
