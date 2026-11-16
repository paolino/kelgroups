{- |
Module      : VoteGroupViewSpec
Description : The read-only roster projection the vote machine reads
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

franchise-is-roster-admins: the franchise is the admins of the view
projected from a sovereign 'KelGroups.Group.Roster', in the roster's
own order, and nothing else. Rosters are obtained from the producer,
'KelGroups.Group.roster' over a chain real group admission built.
-}
module VoteGroupViewSpec
    ( spec
    ) where

import Data.List (sort)
import GroupWorld (Team (..), chainOf, genTeam)
import KelGroups.Group (Roster (Roster), roster)
import KelGroups.Group qualified as Group
import KelGroups.GroupView (groupView)
import KelGroups.GroupView qualified as GV
import KelGroups.Vote.State (franchise, franchiseSize, isResponsabile)
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Hspec.QuickCheck (modifyMaxSuccess, prop)
import Test.QuickCheck
    ( Gen
    , Property
    , counterexample
    , forAll
    , shuffle
    , sublistOf
    , (.&&.)
    , (===)
    )

genShuffledRoster :: Gen Roster
genShuffledRoster = do
    ms <- sublistOf ["a", "b", "c", "d", "e", "o"] >>= shuffle
    as <- sublistOf ms >>= shuffle
    pure (Roster ms as)

-- | The roster the producer reached for a generated team.
withRoster :: Team -> (Roster -> Property) -> Property
withRoster t k = case chainOf (tGroup t) (tWorld t) of
    Nothing -> counterexample "the team's group is not hosted" (False === True)
    Just ch ->
        let r = roster ch
        in  counterexample (show r) $
                sort (Group.admins r) === sort [tA t, tE t]
                    .&&. sort (Group.members r) === sort [tA t, tB t, tD t, tE t]
                    .&&. k r

spec :: Spec
spec = describe "Vote group view" $ do
    describe "projected from a roster real admission built" $
        modifyMaxSuccess (const 20) $ do
            prop "the franchise is the roster's admins, in its order" $
                forAll genTeam $ \t -> withRoster t $ \r ->
                    franchise (groupView r) === Group.admins r

            prop "view membership and admin standing agree with the roster" $
                forAll genTeam $ \t -> withRoster t $ \r ->
                    let v = groupView r
                        probes = [tA t, tE t, tB t, tD t, tC t, tU t]
                    in  map (`GV.isMember` v) probes
                            === map (`elem` Group.members r) probes
                            .&&. map (`GV.isAdmin` v) probes
                                === map (`elem` Group.admins r) probes

            prop "the admin count is the number of roster admins" $
                forAll genTeam $ \t -> withRoster t $ \r ->
                    toInteger (GV.adminCount (groupView r))
                        === toInteger (length (Group.admins r))

    describe "over rosters of any order" $ do
        prop "the admins keep the roster's own order" $
            forAll genShuffledRoster $ \r ->
                GV.admins (groupView r) === Group.admins r

        prop "an admin is a member holding the admin grant" $
            forAll genShuffledRoster $ \r ->
                let v = groupView r
                in  and
                        [ GV.isAdmin k v
                            == (k `elem` Group.members r && k `elem` Group.admins r)
                        | k <- ["a", "b", "c", "d", "e", "o", "s"]
                        ]

        prop "the franchise size is the admin count" $
            forAll genShuffledRoster $ \r ->
                let v = groupView r
                in  franchiseSize v === GV.adminCount v

        prop "responsabile is admin standing, never mere membership" $
            forAll genShuffledRoster $ \r ->
                let v = groupView r
                in  and
                        [ isResponsabile k v == GV.isAdmin k v
                        | k <- ["a", "b", "c", "d", "e", "o", "s"]
                        ]

    describe "an inconsistent roster" $ do
        it "an admin who is not a member is not an admin of the view" $ do
            let v = groupView (Roster ["a"] ["a", "ghost"])
            GV.isAdmin "ghost" v `shouldBe` False
            GV.isMember "ghost" v `shouldBe` False
            GV.admins v `shouldBe` ["a"]
            GV.adminCount v `shouldBe` 1

        it "a member without the grant is a member and no admin" $ do
            let v = groupView (Roster ["a", "b"] ["a"])
            GV.isMember "b" v `shouldBe` True
            GV.isAdmin "b" v `shouldBe` False

        it "the empty roster has no member, no admin, no franchise" $ do
            let v = groupView (Roster [] [])
            GV.admins v `shouldBe` []
            GV.adminCount v `shouldBe` 0
            GV.isMember "a" v `shouldBe` False
