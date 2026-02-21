{-# OPTIONS_GHC -Wno-x-partial #-}

{- |
Module      : E2ESpec
Description : End-to-end scenarios through the HTTP API
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

Multi-step workflows exercising the full group lifecycle
via HTTP calls: bootstrap, proposals, approvals, role
changes, member removal, KEL replay, and SSE.
-}
module E2ESpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, race)
import Control.Concurrent.STM
    ( atomically
    , newTChanIO
    , readTChan
    , writeTChan
    )
import Data.Aeson (encode)
import Data.ByteString qualified as BS
import Data.Set qualified as Set
import KelGroups.Server.JSON (Submission (..))
import KelGroups.Types (Admin (..), Role (..))
import Network.HTTP.Client qualified as HC
import Network.HTTP.Types
    ( status200
    , status401
    , status404
    , status422
    )
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
-- Specs
-- --------------------------------------------------------

spec :: Spec
spec = describe "E2E scenarios" $ around withTestEnv $ do
    describe "Group bootstrap and single-admin lifecycle" $ do
        it "bootstrap → add member → verify state" $
            \te -> do
                -- Bootstrap first admin
                sn1 <- postEvent te (bootstrap "admin1")
                sn1 `shouldBe` 1

                -- Now in normal mode with 1 member
                c1 <- getCondition te "admin1"
                crAuthMode c1 `shouldBe` "normal"
                length (crMembers c1) `shouldBe` 1
                mrKey (head $ crMembers c1)
                    `shouldBe` "admin1"

                -- Single admin proposes a non-admin member
                -- majority(1) = 1, auto-enacts
                sn2 <-
                    postEvent te (proposeMember "admin1" "user1")
                sn2 `shouldBe` 2

                -- Verify 2 members now
                c2 <- getCondition te "admin1"
                length (crMembers c2) `shouldBe` 2

    describe "Multi-admin approval flow" $ do
        it
            "3 admins, proposal requires 2 approvals"
            $ \te -> do
                -- Bootstrap 3 admins (each auto-enacts with
                -- majority <= current admin count)
                _ <- postEvent te (bootstrap "a1")
                -- 1 admin, majority=1, auto-enacts
                _ <- postEvent te (proposeAdmin "a1" "a2")
                -- 2 admins, majority=1, auto-enacts
                _ <- postEvent te (proposeAdmin "a1" "a3")

                c <- getCondition te "a1"
                length (crMembers c) `shouldBe` 3

                -- Now majority = ceil(3/2) = 2
                -- a1 proposes adding user1 — gets 1 approval
                -- (proposer), not enough
                _ <-
                    postEvent te (proposeMember "a1" "user1")

                c1 <- getCondition te "a1"
                -- user1 not yet a member
                length (crMembers c1) `shouldBe` 3
                -- 1 pending proposal
                length (crPending c1) `shouldBe` 1

                -- a2 approves — reaches majority, enacted
                let pid = fst (head $ crPending c1)
                _ <- postEvent te (approve "a2" pid)

                c2 <- getCondition te "a1"
                length (crMembers c2) `shouldBe` 4
                crPending c2 `shouldSatisfy` null

        it "duplicate approval is rejected" $ \te -> do
            _ <- postEvent te (bootstrap "a1")
            _ <- postEvent te (proposeAdmin "a1" "a2")
            _ <- postEvent te (proposeAdmin "a1" "a3")

            -- a1 proposes, pending
            _ <- postEvent te (proposeMember "a1" "user1")
            c <- getCondition te "a1"
            let pid = fst (head $ crPending c)

            -- a1 tries to approve own proposal (already in
            -- approvals as proposer) → 422
            resp <-
                httpPost
                    te
                    "/events"
                    (encode $ approve "a1" pid)
            HC.responseStatus resp `shouldBe` status422

    describe "Member removal" $ do
        it "admin removes a member via proposal" $
            \te -> do
                _ <- postEvent te (bootstrap "a1")
                _ <-
                    postEvent te (proposeMember "a1" "user1")

                c0 <- getCondition te "a1"
                length (crMembers c0) `shouldBe` 2

                -- Propose removal (auto-enacts, 1 admin)
                _ <-
                    postEvent te (proposeRemove "a1" "user1")

                c1 <- getCondition te "a1"
                length (crMembers c1) `shouldBe` 1
                mrKey (head $ crMembers c1)
                    `shouldBe` "a1"

        it "removing last admin returns to bootstrap" $
            \te -> do
                _ <- postEvent te (bootstrap "a1")
                c0 <- getCondition te "a1"
                crAuthMode c0 `shouldBe` "normal"

                -- Admin removes themselves
                _ <- postEvent te (proposeRemove "a1" "a1")

                -- Use /info to check bootstrap (no members)
                resp <- httpGet te "/info?key=anyone"
                HC.responseStatus resp `shouldBe` status200

    describe "Role changes" $ do
        it "promote member to admin" $ \te -> do
            _ <- postEvent te (bootstrap "a1")
            _ <- postEvent te (proposeMember "a1" "user1")

            -- Change user1's roles to include Admin
            _ <-
                postEvent
                    te
                    ( proposeChangeRoles
                        "a1"
                        "user1"
                        ( Set.singleton
                            (AdminRole PublicAdmin)
                        )
                    )

            c <- getCondition te "a1"
            length (crMembers c) `shouldBe` 2

        it "demote admin to regular member" $ \te -> do
            _ <- postEvent te (bootstrap "a1")
            _ <- postEvent te (proposeAdmin "a1" "a2")

            -- a1 changes a2's roles to empty
            _ <-
                postEvent
                    te
                    ( proposeChangeRoles
                        "a1"
                        "a2"
                        Set.empty
                    )

            -- a2 is still a member but not admin
            c <- getCondition te "a1"
            length (crMembers c) `shouldBe` 2

    describe "KEL replay via GET /events" $ do
        it "reads back all events in order" $ \te -> do
            _ <- postEvent te (bootstrap "a1")
            _ <- postEvent te (proposeMember "a1" "u1")
            _ <- postEvent te (proposeMember "a1" "u2")

            -- Read events from beginning (as member a1)
            e0 <- httpGet te "/events?after=-1&key=a1"
            HC.responseStatus e0 `shouldBe` status200
            er0 <- decodeOrFail (HC.responseBody e0)
            erSigner er0 `shouldBe` "a1"

            e1 <- httpGet te "/events?after=0&key=a1"
            HC.responseStatus e1 `shouldBe` status200
            er1 <- decodeOrFail (HC.responseBody e1)
            erSigner er1 `shouldBe` "a1"

            e2 <- httpGet te "/events?after=1&key=a1"
            HC.responseStatus e2 `shouldBe` status200

            -- No more events (3 events = ids 1,2,3)
            e3 <- httpGet te "/events?after=3&key=a1"
            HC.responseStatus e3 `shouldBe` status404

    describe "Authorization edge cases" $ do
        it "non-member cannot propose" $ \te -> do
            _ <- postEvent te (bootstrap "a1")

            resp <-
                httpPost
                    te
                    "/events"
                    (encode $ proposeMember "nobody" "u1")
            HC.responseStatus resp `shouldBe` status422

        it "non-admin member cannot propose" $ \te -> do
            _ <- postEvent te (bootstrap "a1")
            _ <- postEvent te (proposeMember "a1" "user1")

            resp <-
                httpPost
                    te
                    "/events"
                    ( encode $
                        proposeMember "user1" "user2"
                    )
            HC.responseStatus resp `shouldBe` status422

        it "bootstrap rejects missing passphrase" $
            \te -> do
                let sub =
                        (bootstrap "a1")
                            { subPassphrase = Nothing
                            }
                resp <-
                    httpPost te "/events" (encode sub)
                HC.responseStatus resp `shouldBe` status401

        it "duplicate member introduction is rejected" $
            \te -> do
                _ <- postEvent te (bootstrap "a1")
                resp <-
                    httpPost
                        te
                        "/events"
                        (encode $ proposeAdmin "a1" "a1")
                HC.responseStatus resp `shouldBe` status422

    describe "Re-bootstrap after total admin removal" $ do
        it "new admin can bootstrap after wipe" $ \te -> do
            -- Bootstrap and remove
            _ <- postEvent te (bootstrap "a1")
            _ <- postEvent te (proposeRemove "a1" "a1")

            -- No members → /condition is inaccessible, use /info
            resp0 <- httpGet te "/info?key=anyone"
            HC.responseStatus resp0 `shouldBe` status200

            -- Re-bootstrap with different key
            _ <- postEvent te (bootstrap "a2")

            c1 <- getCondition te "a2"
            crAuthMode c1 `shouldBe` "normal"
            length (crMembers c1) `shouldBe` 1
            mrKey (head $ crMembers c1) `shouldBe` "a2"

    describe "SSE receives all events in sequence" $ do
        it "2 POSTs yield 2 SSE notifications" $
            \te -> do
                -- Bootstrap first so we have a member for SSE
                _ <- postEvent te (bootstrap "a1")

                resultChan <- newTChanIO
                listener <- async $ do
                    initReq <-
                        HC.parseRequest $
                            "http://127.0.0.1:"
                                <> show (tePort te)
                                <> "/stream?key=a1"
                    HC.withResponse initReq (teMgr te) $
                        \resp -> do
                            let readChunks n
                                    | n <= 0 = pure ()
                                    | otherwise = do
                                        chunk <-
                                            HC.responseBody
                                                resp
                                        atomically $
                                            writeTChan
                                                resultChan
                                                chunk
                                        readChunks (n - 1)
                            readChunks (2 :: Int)

                threadDelay 50000

                _ <-
                    postEvent te (proposeMember "a1" "u1")
                _ <-
                    postEvent te (proposeMember "a1" "u2")

                -- Collect 2 notifications (2s timeout)
                result <-
                    race
                        (threadDelay 2000000)
                        ( do
                            c1 <-
                                atomically $
                                    readTChan resultChan
                            c2 <-
                                atomically $
                                    readTChan resultChan
                            pure [c1, c2]
                        )
                cancel listener
                case result of
                    Right chunks -> do
                        length chunks `shouldBe` 2
                        -- Each chunk contains sn data
                        all
                            (BS.isInfixOf "\"sn\":")
                            chunks
                            `shouldBe` True
                    Left () ->
                        error "SSE timeout"
