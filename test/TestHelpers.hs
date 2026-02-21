{-# OPTIONS_GHC -Wno-x-partial #-}

{- |
Module      : TestHelpers
Description : Shared test infrastructure for E2E and multi-client specs
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

Reusable test environment, HTTP helpers, submission builders,
and response decoders for integration tests.
-}
module TestHelpers
    ( -- * Test environment
      TestEnv (..)
    , withTestEnv

      -- * HTTP helpers
    , httpGet
    , httpPost
    , postEvent
    , getCondition
    , getInfo
    , decodeOrFail

      -- * Submission builders
    , testPass
    , bootstrap
    , proposeAdmin
    , proposeMember
    , proposeRemove
    , proposeChangeRoles
    , approve

      -- * Response decoders
    , ConditionResp (..)
    , MemberResp (..)
    , EventResp (..)
    , InfoResp (..)
    ) where

import Control.Concurrent.STM (newBroadcastTChanIO)
import Data.Aeson
    ( FromJSON (..)
    , Value (..)
    , decode
    , encode
    , withObject
    , (.:)
    )
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
import KelGroups.Types (Admin (..), Role (..))
import Network.HTTP.Client qualified as HC
import Network.HTTP.Types (status200)
import Network.Wai.Handler.Warp qualified as Warp
import System.Directory (removeFile)
import System.IO.Temp (emptySystemTempFile)
import Test.Hspec (shouldBe)

-- --------------------------------------------------------
-- Test environment
-- --------------------------------------------------------

-- | Passphrase used in all tests.
testPass :: Text
testPass = "e2e-bootstrap-pass"

-- | Test environment with a running server and HTTP manager.
data TestEnv = TestEnv
    { tePort :: Warp.Port
    , teMgr :: HC.Manager
    }

-- | Spin up a fresh server on a random port for one test.
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

-- | GET request to the test server.
httpGet :: TestEnv -> String -> IO (HC.Response LBS.ByteString)
httpGet te path = do
    req <-
        HC.parseRequest $
            "http://127.0.0.1:" <> show (tePort te) <> path
    HC.httpLbs req (teMgr te)

-- | POST request with JSON body.
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
postEvent :: TestEnv -> Submission () -> IO Int
postEvent te sub = do
    resp <- httpPost te "/events" (encode sub)
    HC.responseStatus resp `shouldBe` status200
    ar <- decodeOrFail (HC.responseBody resp)
    pure (sequenceNumber ar)

-- | GET /condition?key=K and decode.
getCondition :: TestEnv -> String -> IO ConditionResp
getCondition te key = do
    resp <-
        httpGet te ("/condition?key=" <> key)
    HC.responseStatus resp `shouldBe` status200
    decodeOrFail (HC.responseBody resp)

-- | GET /info?key=K and decode.
getInfo :: TestEnv -> String -> IO InfoResp
getInfo te key = do
    resp <- httpGet te ("/info?key=" <> key)
    HC.responseStatus resp `shouldBe` status200
    decodeOrFail (HC.responseBody resp)

-- | Decode JSON or fail the test.
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

-- | Bootstrap the first admin.
bootstrap :: Text -> Submission ()
bootstrap key =
    Submission
        { subPassphrase = Just testPass
        , subSigner = key
        , subEvent =
            Base $
                Propose $
                    IntroduceMember
                        key
                        (key <> "@test.example")
                        ( Set.singleton
                            (AdminRole PublicAdmin)
                        )
        }

-- | Propose a new member with PublicAdmin role.
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
                        (newKey <> "@test.example")
                        ( Set.singleton
                            (AdminRole PublicAdmin)
                        )
        }

-- | Propose a new member with no roles.
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
                        (newKey <> "@test.example")
                        Set.empty
        }

-- | Propose removing a member.
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

-- | Propose changing a member's roles.
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

-- | Approve a pending proposal.
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

-- | Decoded /condition response.
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

-- | Decoded member within a /condition response.
data MemberResp = MemberResp
    { mrKey :: Text
    , mrRoles :: [Value]
    }
    deriving stock (Show)

instance FromJSON MemberResp where
    parseJSON = withObject "MemberResp" $ \o ->
        MemberResp <$> o .: "key" <*> o .: "roles"

-- | Decoded /events response.
data EventResp = EventResp
    { erSigner :: Text
    , _erEvent :: Value
    }

instance FromJSON EventResp where
    parseJSON = withObject "EventResp" $ \o ->
        EventResp <$> o .: "signer" <*> o .: "event"

-- | Decoded /info response.
data InfoResp = InfoResp
    { irEmails :: [Text]
    , irPending :: Bool
    }

instance FromJSON InfoResp where
    parseJSON = withObject "InfoResp" $ \o ->
        InfoResp
            <$> o .: "publicAdminEmails"
            <*> o .: "pendingIntroduction"
