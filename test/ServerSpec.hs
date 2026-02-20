{- |
Module      : ServerSpec
Description : HTTP-level tests for the kelgroups server
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

Tests the WAI application through real HTTP using
warp's testWithApplication and http-client.
-}
module ServerSpec (spec) where

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
    )

-- --------------------------------------------------------
-- Helpers
-- --------------------------------------------------------

-- | Passphrase used in all tests.
testPass :: Text
testPass = "test-bootstrap-pass"

-- | Set up a test server on a random port.
withTestApp :: (Warp.Port -> IO a) -> IO a
withTestApp action = do
    dbPath <- emptySystemTempFile "kelgroups-test-.db"
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
    result <-
        Warp.testWithApplication
            (pure $ mkApp env Nothing)
            action
    closeKEL store
    removeFile dbPath
    pure result

-- | Make a GET request to the test server.
httpGet
    :: HC.Manager
    -> Warp.Port
    -> String
    -> IO (HC.Response LBS.ByteString)
httpGet mgr port path = do
    req <-
        HC.parseRequest $
            "http://127.0.0.1:" <> show port <> path
    HC.httpLbs req mgr

-- | Make a POST request with JSON body.
httpPost
    :: HC.Manager
    -> Warp.Port
    -> String
    -> LBS.ByteString
    -> IO (HC.Response LBS.ByteString)
httpPost mgr port path body = do
    initReq <-
        HC.parseRequest $
            "http://127.0.0.1:" <> show port <> path
    let req =
            initReq
                { HC.method = "POST"
                , HC.requestBody = HC.RequestBodyLBS body
                , HC.requestHeaders =
                    [("Content-Type", "application/json")]
                }
    HC.httpLbs req mgr

-- | Decode or fail the test.
decodeOrFail :: (FromJSON a) => LBS.ByteString -> IO a
decodeOrFail bs = case decode bs of
    Just x -> pure x
    Nothing -> error "JSON decode failed"

-- | A bootstrap submission (introduce admin with passphrase).
bootstrapSubmission :: Submission ()
bootstrapSubmission =
    Submission
        { subPassphrase = Just testPass
        , subSigner = "bootstrap-signer"
        , subEvent =
            Base $
                Propose $
                    IntroduceMember
                        "admin1"
                        (Set.singleton Admin)
        }

-- | Helper to extract a text field from JSON response.
data ConditionResp = ConditionResp
    { condAuthMode :: Text
    }

instance FromJSON ConditionResp where
    parseJSON = withObject "ConditionResp" $ \o ->
        ConditionResp <$> o .: "authMode"

-- | Helper to extract signer from event response.
data EventResp = EventResp
    { evtSigner :: Text
    }

instance FromJSON EventResp where
    parseJSON = withObject "EventResp" $ \o ->
        EventResp <$> o .: "signer"

-- --------------------------------------------------------
-- Specs
-- --------------------------------------------------------

spec :: Spec
spec = describe "KelGroups.Server (HTTP)" $ do
    around withTestApp $ do
        describe "GET /condition" $ do
            it "empty KEL returns bootstrap mode" $
                \port -> do
                    mgr <-
                        HC.newManager
                            HC.defaultManagerSettings
                    resp <- httpGet mgr port "/condition"
                    HC.responseStatus resp
                        `shouldBe` status200
                    cr <-
                        decodeOrFail (HC.responseBody resp)
                    condAuthMode cr `shouldBe` "bootstrap"

        describe "POST /events" $ do
            it
                "bootstrap with correct passphrase succeeds"
                $ \port -> do
                    mgr <-
                        HC.newManager
                            HC.defaultManagerSettings
                    resp <-
                        httpPost
                            mgr
                            port
                            "/events"
                            (encode bootstrapSubmission)
                    HC.responseStatus resp
                        `shouldBe` status200
                    ar <-
                        decodeOrFail (HC.responseBody resp)
                    sequenceNumber ar `shouldBe` 1

            it "wrong passphrase returns 401" $
                \port -> do
                    mgr <-
                        HC.newManager
                            HC.defaultManagerSettings
                    let sub =
                            bootstrapSubmission
                                { subPassphrase =
                                    Just "wrong"
                                }
                    resp <-
                        httpPost
                            mgr
                            port
                            "/events"
                            (encode sub)
                    HC.responseStatus resp
                        `shouldBe` status401

            it
                "missing passphrase in bootstrap returns 401"
                $ \port -> do
                    mgr <-
                        HC.newManager
                            HC.defaultManagerSettings
                    let sub =
                            bootstrapSubmission
                                { subPassphrase = Nothing
                                }
                    resp <-
                        httpPost
                            mgr
                            port
                            "/events"
                            (encode sub)
                    HC.responseStatus resp
                        `shouldBe` status401

        describe "GET /events" $ do
            it "after submit returns event" $
                \port -> do
                    mgr <-
                        HC.newManager
                            HC.defaultManagerSettings
                    _ <-
                        httpPost
                            mgr
                            port
                            "/events"
                            (encode bootstrapSubmission)
                    resp <-
                        httpGet
                            mgr
                            port
                            "/events?after=-1"
                    HC.responseStatus resp
                        `shouldBe` status200

            it "beyond length returns 404" $
                \port -> do
                    mgr <-
                        HC.newManager
                            HC.defaultManagerSettings
                    resp <-
                        httpGet
                            mgr
                            port
                            "/events?after=99"
                    HC.responseStatus resp
                        `shouldBe` status404

        describe "POST + GET roundtrip" $ do
            it "submitted event matches retrieved" $
                \port -> do
                    mgr <-
                        HC.newManager
                            HC.defaultManagerSettings
                    _ <-
                        httpPost
                            mgr
                            port
                            "/events"
                            (encode bootstrapSubmission)
                    resp <-
                        httpGet
                            mgr
                            port
                            "/events?after=0"
                    HC.responseStatus resp
                        `shouldBe` status200
                    er <-
                        decodeOrFail (HC.responseBody resp)
                    evtSigner er
                        `shouldBe` "bootstrap-signer"

        describe "GET /condition reflects changes" $ do
            it "after bootstrap, mode is normal" $
                \port -> do
                    mgr <-
                        HC.newManager
                            HC.defaultManagerSettings
                    _ <-
                        httpPost
                            mgr
                            port
                            "/events"
                            (encode bootstrapSubmission)
                    resp <- httpGet mgr port "/condition"
                    HC.responseStatus resp
                        `shouldBe` status200
                    cr <-
                        decodeOrFail (HC.responseBody resp)
                    condAuthMode cr `shouldBe` "normal"

        describe "validation errors" $ do
            it "invalid event in normal mode returns 422" $
                \port -> do
                    mgr <-
                        HC.newManager
                            HC.defaultManagerSettings
                    -- First bootstrap
                    _ <-
                        httpPost
                            mgr
                            port
                            "/events"
                            (encode bootstrapSubmission)
                    -- Now try invalid: non-member proposing
                    let badSub :: Submission ()
                        badSub =
                            Submission
                                { subPassphrase = Nothing
                                , subSigner = "nobody"
                                , subEvent =
                                    Base $
                                        Propose $
                                            IntroduceMember
                                                "k2"
                                                ( Set.singleton
                                                    Admin
                                                )
                                }
                    resp <-
                        httpPost
                            mgr
                            port
                            "/events"
                            (encode badSub)
                    HC.responseStatus resp
                        `shouldBe` status422

        describe "unknown route" $ do
            it "returns 404" $
                \port -> do
                    mgr <-
                        HC.newManager
                            HC.defaultManagerSettings
                    resp <-
                        httpGet mgr port "/nonexistent"
                    HC.responseStatus resp
                        `shouldBe` status404

        describe "SSE /stream" $ do
            it "receives notification after POST" $
                \port -> do
                    mgr <-
                        HC.newManager
                            HC.defaultManagerSettings
                    -- Use a TChan to relay the SSE data
                    resultChan <- newTChanIO
                    -- Start SSE listener in background
                    listener <- async $ do
                        initReq <-
                            HC.parseRequest $
                                "http://127.0.0.1:"
                                    <> show port
                                    <> "/stream"
                        HC.withResponse initReq mgr $
                            \resp -> do
                                chunk <-
                                    HC.responseBody resp
                                atomically $
                                    writeTChan
                                        resultChan
                                        chunk
                    -- Give SSE connection time
                    threadDelay 50000
                    -- POST an event
                    _ <-
                        httpPost
                            mgr
                            port
                            "/events"
                            (encode bootstrapSubmission)
                    -- Wait for SSE notification (2s timeout)
                    result <-
                        race
                            (threadDelay 2000000)
                            ( atomically $
                                readTChan resultChan
                            )
                    cancel listener
                    case result of
                        Right bs ->
                            BS.isInfixOf
                                "\"sn\":1"
                                bs
                                `shouldBe` True
                        Left () ->
                            error "SSE timeout"
