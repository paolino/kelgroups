{-# OPTIONS_GHC -Wno-x-partial #-}

{- |
Module      : MultiClientSpec
Description : Multi-client E2E scenarios
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

Explicit multi-client scenarios where separate identities
(Alice, Bob, Charlie, Dave) each make HTTP calls with
their own @?key=@ parameter and observe different views
of the group.
-}
module MultiClientSpec (spec) where

import Network.HTTP.Client qualified as HC
import Network.HTTP.Types (status200, status403)
import Test.Hspec
    ( Spec
    , around
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )
import TestHelpers

-- --------------------------------------------------------
-- Scenario 1: Admin bootstraps, outsider joins
-- --------------------------------------------------------

scenario1 :: Spec
scenario1 =
    describe
        "Two clients: admin bootstraps, outsider joins"
        $ around withTestEnv
        $ do
            it
                "Bob sees empty group, Alice bootstraps, \
                \Bob joins"
                $ \te -> do
                    -- 1. Bob sees no admins and is not pending
                    info0 <- getInfo te "bob"
                    irEmails info0 `shouldBe` []
                    irPending info0 `shouldBe` False

                    -- 2. Alice bootstraps as PublicAdmin
                    sn1 <- postEvent te (bootstrap "alice")
                    sn1 `shouldBe` 1

                    -- 3. Bob sees Alice's email in admin list
                    info1 <- getInfo te "bob"
                    irEmails info1
                        `shouldBe` ["alice@test.example"]
                    irPending info1 `shouldBe` False

                    -- 4. Bob cannot access /condition (not a member)
                    resp403 <-
                        httpGet te "/condition?key=bob"
                    HC.responseStatus resp403
                        `shouldBe` status403

                    -- 5. Alice proposes introducing Bob
                    --    (1 admin, majority=1, auto-enacted)
                    sn2 <-
                        postEvent te (proposeMember "alice" "bob")
                    sn2 `shouldBe` 2

                    -- 6. Bob checks /info — already enacted, not pending
                    info2 <- getInfo te "bob"
                    irPending info2 `shouldBe` False

                    -- 7. Bob can now access /condition
                    cBob <- getCondition te "bob"
                    crAuthMode cBob `shouldBe` "normal"
                    length (crMembers cBob) `shouldBe` 2

                    -- 8. Bob can replay the KEL
                    e0 <-
                        httpGet te "/events?after=-1&key=bob"
                    HC.responseStatus e0 `shouldBe` status200
                    er0 <- decodeOrFail (HC.responseBody e0)
                    erSigner er0 `shouldBe` "alice"

-- --------------------------------------------------------
-- Scenario 2: Multi-admin majority approval
-- --------------------------------------------------------

scenario2 :: Spec
scenario2 =
    describe
        "Three clients: multi-admin majority approval"
        $ around withTestEnv
        $ do
            it "3 admins require 2 approvals for Dave" $
                \te -> do
                    -- 1. Alice bootstraps
                    _ <- postEvent te (bootstrap "alice")

                    -- 2. Alice proposes Bob as admin
                    --    (1 admin, majority=1, auto-enacted)
                    _ <-
                        postEvent
                            te
                            (proposeAdmin "alice" "bob")

                    -- 3. Alice proposes Charlie as admin
                    --    (2 admins, majority=1, auto-enacted)
                    _ <-
                        postEvent
                            te
                            (proposeAdmin "alice" "charlie")

                    -- 4. Now 3 admins, majority = ceil(3/2) = 2
                    --    Dave sees 3 admin emails via /info
                    infoDave <- getInfo te "dave"
                    length (irEmails infoDave) `shouldBe` 3

                    -- 5. Alice proposes introducing Dave (non-admin)
                    --    Only Alice approves → pending (need 2)
                    _ <-
                        postEvent
                            te
                            (proposeMember "alice" "dave")

                    -- 6. Alice sees 1 pending proposal
                    cAlice <- getCondition te "alice"
                    length (crPending cAlice) `shouldBe` 1
                    length (crMembers cAlice) `shouldBe` 3

                    -- 7. Bob sees the same pending proposal
                    cBob <- getCondition te "bob"
                    length (crPending cBob) `shouldBe` 1
                    length (crMembers cBob) `shouldBe` 3

                    -- 8. Bob approves → 2 approvals >= majority,
                    --    enacted
                    let pid =
                            fst (head $ crPending cAlice)
                    _ <- postEvent te (approve "bob" pid)

                    -- 9. Charlie sees 4 members, 0 pending
                    cCharlie <- getCondition te "charlie"
                    length (crMembers cCharlie) `shouldBe` 4
                    crPending cCharlie `shouldSatisfy` null

                    -- 10. Dave can now see the group condition
                    cDave <- getCondition te "dave"
                    crAuthMode cDave `shouldBe` "normal"
                    length (crMembers cDave) `shouldBe` 4

-- --------------------------------------------------------
-- Scenario 3: Full lifecycle (introduce, remove, re-bootstrap)
-- --------------------------------------------------------

scenario3 :: Spec
scenario3 =
    describe
        "Three clients: full lifecycle"
        $ around withTestEnv
        $ do
            it "introduce, remove, wipe, re-bootstrap" $
                \te -> do
                    -- 1. Alice bootstraps
                    _ <- postEvent te (bootstrap "alice")

                    -- 2. Alice proposes Bob as admin
                    --    (auto-enacted, 1 admin)
                    _ <-
                        postEvent
                            te
                            (proposeAdmin "alice" "bob")

                    -- 3. Alice proposes Charlie (non-admin)
                    --    (2 admins, majority=1, auto-enacted)
                    _ <-
                        postEvent
                            te
                            (proposeMember "alice" "charlie")

                    -- Verify: 3 members
                    c0 <- getCondition te "alice"
                    length (crMembers c0) `shouldBe` 3

                    -- 4. Bob proposes removing Charlie
                    --    (2 admins, majority=1, auto-enacted)
                    _ <-
                        postEvent
                            te
                            (proposeRemove "bob" "charlie")

                    -- 5. Charlie is removed, can't access /condition
                    resp403 <-
                        httpGet te "/condition?key=charlie"
                    HC.responseStatus resp403
                        `shouldBe` status403

                    -- 6. Charlie can still see admin emails via /info
                    infoCharlie <- getInfo te "charlie"
                    length (irEmails infoCharlie) `shouldBe` 2

                    -- 7. Alice proposes removing Bob
                    --    (2 admins, majority=1, auto-enacted)
                    _ <-
                        postEvent
                            te
                            (proposeRemove "alice" "bob")

                    -- 8. Alice proposes removing Alice
                    --    (1 admin left, majority=1, auto-enacted)
                    _ <-
                        postEvent
                            te
                            (proposeRemove "alice" "alice")

                    -- 9. Bob is removed, can't access /condition
                    resp403b <-
                        httpGet te "/condition?key=bob"
                    HC.responseStatus resp403b
                        `shouldBe` status403

                    -- 10. Anyone sees empty admin list (bootstrap mode)
                    infoAnyone <- getInfo te "anyone"
                    irEmails infoAnyone `shouldBe` []

                    -- 11. Bob re-bootstraps
                    _ <- postEvent te (bootstrap "bob")

                    -- 12. Bob is the sole member in normal mode
                    cBob <- getCondition te "bob"
                    crAuthMode cBob `shouldBe` "normal"
                    length (crMembers cBob) `shouldBe` 1
                    mrKey (head $ crMembers cBob)
                        `shouldBe` "bob"

                    -- 13. Alice is no longer a member
                    resp403c <-
                        httpGet te "/condition?key=alice"
                    HC.responseStatus resp403c
                        `shouldBe` status403

-- --------------------------------------------------------
-- Top-level spec
-- --------------------------------------------------------

spec :: Spec
spec = describe "Multi-client scenarios" $ do
    scenario1
    scenario2
    scenario3
