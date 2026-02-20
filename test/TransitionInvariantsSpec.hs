{-# OPTIONS_GHC -Wno-orphans #-}

{- |
Module      : TransitionInvariantsSpec
Description : QuickCheck properties mirroring Lean transition invariants
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

Each property corresponds to a proven Lean theorem in
@KelGroups.TransitionInvariants@. The Lean proofs guarantee
correctness for all inputs; these QuickCheck properties
test that the Haskell implementation matches.
-}
module TransitionInvariantsSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text, pack)
import KelGroups.Event (Proposal (..))
import KelGroups.Fold
    ( AppFold
    , applyPropose
    , enact
    , foldGroup
    )
import KelGroups.State
    ( GroupState (..)
    , adminCount
    , emptyState
    )
import KelGroups.Types (Member (..), Role (..))
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
    ( Arbitrary (..)
    , Gen
    , chooseInt
    , elements
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

instance Arbitrary Member where
    arbitrary :: Gen Member
    arbitrary = do
        key <- arbitraryKey
        roles <- Set.fromList <$> listOf arbitrary
        pure Member{memberKey = key, memberRoles = roles}

arbitraryKey :: Gen Text
arbitraryKey =
    pack . ("key" <>) . show <$> chooseInt (0, 99)

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

-- | Build a GroupState with exactly @n@ admin members.
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

-- | Trivial app fold for testing.
trivialAppFold :: AppFold ()
trivialAppFold _ _ = ()

-- --------------------------------------------------------
-- Specs
-- --------------------------------------------------------

spec :: Spec
spec = do
    -- ==================================================
    -- Tier 1: Straightforward invariants
    -- ==================================================
    describe
        "Tier 1: enact_introduce_admin_exits_bootstrap"
        $ do
            prop
                "introducing admin makes adminCount > 0"
                $ do
                    gs <- arbitraryGroupState
                    key <- arbitraryKey
                    roles <- arbitraryAdminRoles
                    let gs' =
                            enact gs $
                                IntroduceMember key roles
                    pure $ adminCount gs' > 0

    describe "Tier 1: enact_introduce_admin_count" $ do
        prop
            "introducing admin increases adminCount by 1"
            $ do
                gs <- arbitraryGroupState
                key <-
                    arbitraryKey `suchThat` \k ->
                        not $ Map.member k (members gs)
                roles <- arbitraryAdminRoles
                let gs' =
                        enact gs $
                            IntroduceMember key roles
                pure $
                    adminCount gs' == adminCount gs + 1

    describe
        "Tier 1: enact_introduce_nonadmin_count"
        $ do
            prop
                "introducing non-admin preserves adminCount"
                $ do
                    gs <- arbitraryGroupState
                    key <-
                        arbitraryKey `suchThat` \k ->
                            not $ Map.member k (members gs)
                    roles <- arbitraryNonAdminRoles
                    let gs' =
                            enact gs $
                                IntroduceMember key roles
                    pure $
                        adminCount gs' == adminCount gs

    describe
        "Tier 1: enact_preserves_pendingProposals"
        $ do
            prop
                "enact only touches members"
                $ do
                    gs <- arbitraryGroupState
                    proposal <- arbitrary
                    let gs' = enact gs proposal
                    pure $
                        pendingProposals gs'
                            == pendingProposals gs

    describe "Tier 1: foldGroup_nil" $ do
        it "folding empty list yields emptyState" $
            foldGroup trivialAppFold () []
                `shouldBe` emptyState ()

    -- ==================================================
    -- Tier 2: Majority + tryEnact
    -- ==================================================
    describe
        "Tier 2: bootstrap_proposal_immediately_enacted"
        $ do
            prop
                "bootstrap proposal has no pending after apply"
                $ do
                    signer <- arbitraryKey
                    proposal <- arbitrary
                    let gs' =
                            applyPropose
                                (emptyState ())
                                signer
                                proposal
                    pure $
                        Map.null (pendingProposals gs')

    describe
        "Tier 2: single_admin_proposal_enacted"
        $ do
            prop
                "single admin proposal is enacted immediately"
                $ do
                    let gs = gsWithAdminCount 1
                    signer <-
                        elements $
                            Map.keys (members gs)
                    proposal <- arbitrary
                    let gs' = applyPropose gs signer proposal
                    pure $
                        members gs'
                            == members
                                (enact gs proposal)

    -- ==================================================
    -- Tier 3: List induction — eraseP + filter
    -- ==================================================
    describe
        "Tier 3: enact_remove_preserves_normal"
        $ do
            prop
                "adminCount >= 2 and remove keeps adminCount >= 1"
                $ do
                    gs <- arbitraryWithTwoAdmins
                    key <- arbitraryKey
                    let gs' =
                            enact gs $ RemoveMember key
                    pure $ adminCount gs' >= 1
