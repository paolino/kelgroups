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
    , newBroadcastTChanIO
    , newTChanIO
    , readTChan
    , writeTChan
    )
import Data.Aeson
    ( FromJSON (..)
    , Value (..)
    , decode
    , encode
    , withObject
    , (.:)
    )
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Set qualified as Set
import Data.Text (Text)
import KelGroups.Event
    ( BaseEvent (..)
    , GroupEvent (..)
    , Proposal (..)
    )
import KelGroups.Server (ServerEnv (..), mkApp)
import KelGroups.Server.JSON
    ( AppendResult (..)
    , Submission (..)
    )
import KelGroups.Store (closeKEL, openKEL)
import KelGroups.Store.Serialise ()
import KelGroups.Trivial
    ( trivialConfig
    , trivialFold
    , trivialInitial
    )
import KelGroups.Types (Role (..))
import Network.HTTP.Client qualified as HC
import Network.HTTP.Types
    ( status200
    , status401
    , status404
    , status422
    )
import Network.Wai.Handler.Warp qualified as Warp
import System.Directory (removeFile)
import System.IO.Temp (emptySystemTempFile)
import Test.Hspec
    ( Spec
    , around
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

-- --------------------------------------------------------
-- Test environment
-- --------------------------------------------------------

testPass :: Text
testPass = "e2e-bootstrap-pass"

data TestEnv = TestEnv
    { tePort :: Warp.Port
    , teMgr :: HC.Manager
    }

withTestEnv :: (TestEnv -> IO a) -> IO a
withTestEnv action = do
    dbPath <- emptySystemTempFile "kelgroups-e2e-.db"
    store <- openKEL trivialFold trivialInitial dbPath
    ch <- newBroadcastTChanIO
    let env =
            ServerEnv
                { envStore = store
                , envConfig = trivialConfig
                , envAppFold = trivialFold
                , envPassphrase = testPass
                , envBroadcast = ch
                }
    mgr <- HC.newManager HC.defaultManagerSettings
    result <-
        Warp.testWithApplication
            (pure $ mkApp env Nothing)
            (\port -> action TestEnv{tePort = port, teMgr = mgr})
    closeKEL store
    removeFile dbPath
    pure result

-- --------------------------------------------------------
-- HTTP helpers
-- --------------------------------------------------------

httpGet :: TestEnv -> String -> IO (HC.Response LBS.ByteString)
httpGet te path = do
    req <-
        HC.parseRequest $
            "http://127.0.0.1:" <> show (tePort te) <> path
    HC.httpLbs req (teMgr te)

httpPost
    :: TestEnv
    -> String
    -> LBS.ByteString
    -> IO (HC.Response LBS.ByteString)
httpPost te path body = do
    initReq <-
        HC.parseRequest $
            "http://127.0.0.1:" <> show (tePort te) <> path
    let req =
            initReq
                { HC.method = "POST"
                , HC.requestBody = HC.RequestBodyLBS body
                , HC.requestHeaders =
                    [("Content-Type", "application/json")]
                }
    HC.httpLbs req (teMgr te)

-- | POST a submission and expect 200, return sequence number.
postEvent
    :: TestEnv -> Submission () -> IO Int
postEvent te sub = do
    resp <- httpPost te "/events" (encode sub)
    HC.responseStatus resp `shouldBe` status200
    ar <- decodeOrFail (HC.responseBody resp)
    pure (sequenceNumber ar)

-- | GET /condition and decode.
getCondition :: TestEnv -> IO ConditionResp
getCondition te = do
    resp <- httpGet te "/condition"
    HC.responseStatus resp `shouldBe` status200
    decodeOrFail (HC.responseBody resp)

decodeOrFail :: (FromJSON a) => LBS.ByteString -> IO a
decodeOrFail bs = case decode bs of
    Just x -> pure x
    Nothing ->
        error $
            "JSON decode failed: "
                <> show (LBS.take 200 bs)

-- --------------------------------------------------------
-- Submission builders
-- --------------------------------------------------------

bootstrap :: Text -> Submission ()
bootstrap key =
    Submission
        { subPassphrase = Just testPass
        , subSigner = key
        , subEvent =
            Base $
                Propose $
                    IntroduceMember key (Set.singleton Admin)
        }

proposeAdmin :: Text -> Text -> Submission ()
proposeAdmin signer newKey =
    Submission
        { subPassphrase = Nothing
        , subSigner = signer
        , subEvent =
            Base $
                Propose $
                    IntroduceMember
                        newKey
                        (Set.singleton Admin)
        }

proposeMember :: Text -> Text -> Submission ()
proposeMember signer newKey =
    Submission
        { subPassphrase = Nothing
        , subSigner = signer
        , subEvent =
            Base $
                Propose $
                    IntroduceMember
                        newKey
                        Set.empty
        }

proposeRemove :: Text -> Text -> Submission ()
proposeRemove signer targetKey =
    Submission
        { subPassphrase = Nothing
        , subSigner = signer
        , subEvent =
            Base $
                Propose $
                    RemoveMember targetKey
        }

proposeChangeRoles
    :: Text -> Text -> Set.Set Role -> Submission ()
proposeChangeRoles signer targetKey roles =
    Submission
        { subPassphrase = Nothing
        , subSigner = signer
        , subEvent =
            Base $
                Propose $
                    ChangeRoles targetKey roles
        }

approve :: Text -> Text -> Submission ()
approve signer proposalId =
    Submission
        { subPassphrase = Nothing
        , subSigner = signer
        , subEvent = Base $ Approve proposalId
        }

-- --------------------------------------------------------
-- Response decoders
-- --------------------------------------------------------

data ConditionResp = ConditionResp
    { crAuthMode :: Text
    , crMembers :: [MemberResp]
    , crPending :: [(Text, Value)]
    }

instance FromJSON ConditionResp where
    parseJSON = withObject "ConditionResp" $ \o -> do
        mode <- o .: "authMode"
        st <- o .: "state"
        ms <- st .: "members"
        pps <- st .: "pendingProposals"
        pure
            ConditionResp
                { crAuthMode = mode
                , crMembers = ms
                , crPending = pps
                }

data MemberResp = MemberResp
    { mrKey :: Text
    , mrRoles :: [Value]
    }
    deriving stock (Show)

instance FromJSON MemberResp where
    parseJSON = withObject "MemberResp" $ \o ->
        MemberResp <$> o .: "key" <*> o .: "roles"

data EventResp = EventResp
    { erSigner :: Text
    , _erEvent :: Value
    }

instance FromJSON EventResp where
    parseJSON = withObject "EventResp" $ \o ->
        EventResp <$> o .: "signer" <*> o .: "event"

-- --------------------------------------------------------
-- Specs
-- --------------------------------------------------------

spec :: Spec
spec = describe "E2E scenarios" $ around withTestEnv $ do
    describe "Group bootstrap and single-admin lifecycle" $ do
        it "bootstrap → add member → verify state" $
            \te -> do
                -- Start in bootstrap mode
                c0 <- getCondition te
                crAuthMode c0 `shouldBe` "bootstrap"
                crMembers c0 `shouldSatisfy` null

                -- Bootstrap first admin
                sn1 <- postEvent te (bootstrap "admin1")
                sn1 `shouldBe` 1

                -- Now in normal mode with 1 member
                c1 <- getCondition te
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
                c2 <- getCondition te
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

                c <- getCondition te
                length (crMembers c) `shouldBe` 3

                -- Now majority = ceil(3/2) = 2
                -- a1 proposes adding user1 — gets 1 approval
                -- (proposer), not enough
                _ <-
                    postEvent te (proposeMember "a1" "user1")

                c1 <- getCondition te
                -- user1 not yet a member
                length (crMembers c1) `shouldBe` 3
                -- 1 pending proposal
                length (crPending c1) `shouldBe` 1

                -- a2 approves — reaches majority, enacted
                let pid = fst (head $ crPending c1)
                _ <- postEvent te (approve "a2" pid)

                c2 <- getCondition te
                length (crMembers c2) `shouldBe` 4
                crPending c2 `shouldSatisfy` null

        it "duplicate approval is rejected" $ \te -> do
            _ <- postEvent te (bootstrap "a1")
            _ <- postEvent te (proposeAdmin "a1" "a2")
            _ <- postEvent te (proposeAdmin "a1" "a3")

            -- a1 proposes, pending
            _ <- postEvent te (proposeMember "a1" "user1")
            c <- getCondition te
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

                c0 <- getCondition te
                length (crMembers c0) `shouldBe` 2

                -- Propose removal (auto-enacts, 1 admin)
                _ <-
                    postEvent te (proposeRemove "a1" "user1")

                c1 <- getCondition te
                length (crMembers c1) `shouldBe` 1
                mrKey (head $ crMembers c1)
                    `shouldBe` "a1"

        it "removing last admin returns to bootstrap" $
            \te -> do
                _ <- postEvent te (bootstrap "a1")
                c0 <- getCondition te
                crAuthMode c0 `shouldBe` "normal"

                -- Admin removes themselves
                _ <- postEvent te (proposeRemove "a1" "a1")

                c1 <- getCondition te
                crAuthMode c1 `shouldBe` "bootstrap"
                crMembers c1 `shouldSatisfy` null

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
                        (Set.singleton Admin)
                    )

            c <- getCondition te
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
            c <- getCondition te
            length (crMembers c) `shouldBe` 2

    describe "KEL replay via GET /events" $ do
        it "reads back all events in order" $ \te -> do
            _ <- postEvent te (bootstrap "a1")
            _ <- postEvent te (proposeMember "a1" "u1")
            _ <- postEvent te (proposeMember "a1" "u2")

            -- Read events from beginning
            e0 <- httpGet te "/events?after=-1"
            HC.responseStatus e0 `shouldBe` status200
            er0 <- decodeOrFail (HC.responseBody e0)
            erSigner er0 `shouldBe` "a1"

            e1 <- httpGet te "/events?after=0"
            HC.responseStatus e1 `shouldBe` status200
            er1 <- decodeOrFail (HC.responseBody e1)
            erSigner er1 `shouldBe` "a1"

            e2 <- httpGet te "/events?after=1"
            HC.responseStatus e2 `shouldBe` status200

            -- No more events (3 events = ids 1,2,3)
            e3 <- httpGet te "/events?after=3"
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

            c0 <- getCondition te
            crAuthMode c0 `shouldBe` "bootstrap"

            -- Re-bootstrap with different key
            _ <- postEvent te (bootstrap "a2")

            c1 <- getCondition te
            crAuthMode c1 `shouldBe` "normal"
            length (crMembers c1) `shouldBe` 1
            mrKey (head $ crMembers c1) `shouldBe` "a2"

    describe "SSE receives all events in sequence" $ do
        it "3 POSTs yield 3 SSE notifications" $
            \te -> do
                resultChan <- newTChanIO
                listener <- async $ do
                    initReq <-
                        HC.parseRequest $
                            "http://127.0.0.1:"
                                <> show (tePort te)
                                <> "/stream"
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
                            readChunks (3 :: Int)

                threadDelay 50000

                _ <- postEvent te (bootstrap "a1")
                _ <-
                    postEvent te (proposeMember "a1" "u1")
                _ <-
                    postEvent te (proposeMember "a1" "u2")

                -- Collect 3 notifications (2s timeout)
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
                            c3 <-
                                atomically $
                                    readTChan resultChan
                            pure [c1, c2, c3]
                        )
                cancel listener
                case result of
                    Right chunks -> do
                        length chunks `shouldBe` 3
                        -- Each chunk contains sn data
                        all
                            (BS.isInfixOf "\"sn\":")
                            chunks
                            `shouldBe` True
                    Left () ->
                        error "SSE timeout"
