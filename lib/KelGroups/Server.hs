{- |
Module      : KelGroups.Server
Description : HTTP server for kelgroups (WAI application)
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

WAI application providing JSON endpoints for group
management and SSE notifications. Manual routing on
method + path.
-}
module KelGroups.Server
    ( ServerEnv (..)
    , mkApp
    ) where

import Codec.Serialise (Serialise)
import Control.Concurrent.STM
    ( TChan
    , atomically
    , dupTChan
    , readTChan
    , writeTChan
    )
import Data.Aeson
    ( FromJSON
    , ToJSON (..)
    , decode
    , encode
    , object
    , (.=)
    )
import Data.ByteString (ByteString)
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Read qualified as TR
import KelGroups.Bootstrap (AuthMode (..), authMode)
import KelGroups.Event (Proposal (..))
import KelGroups.Fold (AppFold)
import KelGroups.Server.JSON
    ( AppendResult (..)
    , ServerError (..)
    , Submission (..)
    )
import KelGroups.State
    ( GroupState (..)
    , PendingProposal (..)
    , isMember
    )
import KelGroups.Store
    ( KELStore
    , appendEvent
    , kelLength
    , readEventsFrom
    , readState
    )
import KelGroups.Types
    ( Admin (..)
    , GroupConfig
    , Member (..)
    , Role (..)
    )
import KelGroups.Validate (validateEvent)
import Keri.Cesr qualified as Cesr
import Keri.Cesr.DerivationCode (DerivationCode (..))
import Keri.Cesr.Primitive (Primitive (..))
import Keri.Crypto.Ed25519 qualified as Ed25519
import Network.HTTP.Types
    ( HeaderName
    , Status
    , hContentType
    , status200
    , status400
    , status401
    , status403
    , status404
    , status422
    )
import Network.Wai
    ( Application
    , Request
    , Response
    , pathInfo
    , queryString
    , requestMethod
    , responseLBS
    , responseStream
    , strictRequestBody
    )

-- | Server environment shared across all handlers.
data ServerEnv a = ServerEnv
    { envStore :: KELStore a
    -- ^ Persistent event store
    , envConfig :: GroupConfig a
    -- ^ Group configuration (role defs)
    , envAppFold :: AppFold a
    -- ^ Application fold function
    , envPassphrase :: Text
    -- ^ Bootstrap passphrase
    , envBroadcast :: TChan Int
    -- ^ SSE broadcast channel
    }

{- | Build a WAI 'Application' from a 'ServerEnv'.
Unmatched routes are passed to the optional fallback
application, or return 404.
-}
mkApp
    :: (Serialise a, FromJSON a, ToJSON a)
    => ServerEnv a
    -> Maybe Application
    -- ^ Optional fallback for unmatched routes (e.g. static files)
    -> Application
mkApp env mFallback req respond =
    case (requestMethod req, pathInfo req) of
        ("GET", ["info"]) ->
            handleInfo env req respond
        ("GET", ["condition"]) ->
            requireMemberGuard env req respond $
                handleCondition env req respond
        ("GET", ["events"]) ->
            requireMemberGuard env req respond $
                handleGetEvent env req respond
        ("POST", ["events"]) ->
            handlePostEvent env req respond
        ("GET", ["stream"]) ->
            requireMemberGuard env req respond $
                handleStream env req respond
        _ -> case mFallback of
            Just fallback -> fallback req respond
            Nothing ->
                respond $
                    jsonResponse status404 $
                        BadRequest "not found"

-- --------------------------------------------------------
-- GET /condition
-- --------------------------------------------------------

handleCondition
    :: (ToJSON a)
    => ServerEnv a
    -> Application
handleCondition env _req respond = do
    gs <- readState (envStore env)
    respond $
        responseLBS
            status200
            jsonHeaders
            (encode $ conditionBody gs)

conditionBody
    :: GroupState a -> ConditionResponse a
conditionBody gs =
    ConditionResponse
        { crState = gs
        , crAuthMode = authMode gs
        }

-- | Internal type for the /condition response.
data ConditionResponse a = ConditionResponse
    { crState :: GroupState a
    , crAuthMode :: AuthMode
    }

instance (ToJSON a) => ToJSON (ConditionResponse a) where
    toJSON cr =
        object
            [ "state" .= crState cr
            , "authMode" .= crAuthMode cr
            ]

-- --------------------------------------------------------
-- GET /events?after=N
-- --------------------------------------------------------

handleGetEvent
    :: (Serialise a, ToJSON a)
    => ServerEnv a
    -> Application
handleGetEvent env req respond =
    case parseAfter req of
        Nothing ->
            respond $
                jsonResponse status400 $
                    BadRequest "missing or invalid ?after=N"
        Just after -> do
            events <-
                readEventsFrom (envStore env) (after + 1)
            case events of
                [] ->
                    respond $
                        jsonResponse status404 $
                            BadRequest
                                "no event at position"
                ((signer, evt) : _) ->
                    respond $
                        responseLBS
                            status200
                            jsonHeaders
                            ( encode $
                                object
                                    [ "signer" .= signer
                                    , "event" .= evt
                                    ]
                            )

-- | Parse the ?after=N query parameter.
parseAfter :: Request -> Maybe Int
parseAfter req =
    case lookup "after" (queryString req) of
        Just (Just bs) ->
            case TR.signed TR.decimal (TE.decodeUtf8 bs) of
                Right (n, _) -> Just n
                Left _ -> Nothing
        _ -> Nothing

-- --------------------------------------------------------
-- POST /events
-- --------------------------------------------------------

handlePostEvent
    :: (Serialise a, FromJSON a, ToJSON a)
    => ServerEnv a
    -> Application
handlePostEvent env req respond = do
    body <- strictRequestBody req
    case decode body of
        Nothing ->
            respond $
                jsonResponse status400 $
                    BadRequest "invalid JSON"
        Just sub -> do
            gs <- readState (envStore env)
            case authMode gs of
                Bootstrap ->
                    handleBootstrapPost env sub respond
                Normal ->
                    doAppend env sub respond

handleBootstrapPost
    :: (Serialise a, ToJSON a)
    => ServerEnv a
    -> Submission a
    -> (Response -> IO b)
    -> IO b
handleBootstrapPost env sub respond =
    case subPassphrase sub of
        Nothing ->
            respond $
                jsonResponse
                    status401
                    PassphraseRequired
        Just pass
            | pass /= envPassphrase env ->
                respond $
                    jsonResponse
                        status401
                        WrongPassphrase
            | otherwise ->
                doAppend env sub respond

-- | Validate and append the event.
doAppend
    :: (Serialise a, ToJSON a)
    => ServerEnv a
    -> Submission a
    -> (Response -> IO b)
    -> IO b
doAppend env sub respond =
    case verifySig (subSigner sub) (subSignature sub) (subEvent sub) of
        Left err ->
            respond $
                jsonResponse status401 $
                    SignatureError err
        Right () -> do
            gs <- readState (envStore env)
            case validateEvent
                (envConfig env)
                gs
                (subSigner sub)
                (subEvent sub) of
                Left ve ->
                    respond $
                        jsonResponse status422 $
                            ValidationErr ve
                Right () -> do
                    appendEvent
                        (envStore env)
                        (envAppFold env)
                        (subSigner sub, subEvent sub)
                    sn <- kelLength (envStore env)
                    atomically $
                        writeTChan (envBroadcast env) sn
                    respond $
                        responseLBS
                            status200
                            jsonHeaders
                            (encode $ AppendResult sn)

-- --------------------------------------------------------
-- GET /stream (SSE)
-- --------------------------------------------------------

handleStream
    :: ServerEnv a
    -> Application
handleStream env _req respond =
    respond $
        responseStream status200 sseHeaders $
            \write flush -> do
                ch <-
                    atomically $
                        dupTChan (envBroadcast env)
                let loop = do
                        sn <- atomically $ readTChan ch
                        write $
                            Builder.byteString
                                "event: new\ndata: {\"sn\":"
                                <> Builder.intDec sn
                                <> Builder.byteString
                                    "}\n\n"
                        flush
                        loop
                loop

-- --------------------------------------------------------
-- GET /info?key=K (open to anyone)
-- --------------------------------------------------------

handleInfo
    :: ServerEnv a
    -> Application
handleInfo env req respond =
    case parseKey req of
        Nothing ->
            respond $
                jsonResponse status400 $
                    BadRequest "missing ?key=K"
        Just key -> do
            gs <- readState (envStore env)
            let pubEmails = publicAdminEmails gs
                pending = hasPendingIntro key gs
            respond $
                responseLBS
                    status200
                    jsonHeaders
                    ( encode $
                        object
                            [ "publicAdminEmails"
                                .= pubEmails
                            , "pendingIntroduction"
                                .= pending
                            ]
                    )

-- | Emails of members with AdminRole PublicAdmin.
publicAdminEmails :: GroupState a -> [Text]
publicAdminEmails gs =
    [ memberEmail m
    | m <- Map.elems (members gs)
    , isPublicAdmin m
    ]
  where
    isPublicAdmin m =
        any
            ( \case
                AdminRole PublicAdmin -> True
                _ -> False
            )
            (memberRoles m)

-- | Check if any pending proposal introduces the key.
hasPendingIntro :: Text -> GroupState a -> Bool
hasPendingIntro key gs =
    any matchesKey $
        Map.elems (pendingProposals gs)
  where
    matchesKey pp = case proposal pp of
        IntroduceMember k _ _ -> k == key
        _ -> False

-- --------------------------------------------------------
-- Membership guard
-- --------------------------------------------------------

{- | Check that the request includes a valid member key.
In bootstrap mode, all guarded endpoints are blocked
(non-members should use /info instead).
-}
requireMemberGuard
    :: ServerEnv a
    -> Request
    -> (Response -> IO b)
    -> IO b
    -> IO b
requireMemberGuard env req respond onOk =
    case parseKey req of
        Nothing ->
            respond $
                jsonResponse status401 $
                    BadRequest "missing key"
        Just key -> do
            gs <- readState (envStore env)
            if isMember key gs
                then onOk
                else
                    respond $
                        jsonResponse status403 $
                            BadRequest "not a member"

-- | Parse the ?key=K query parameter.
parseKey :: Request -> Maybe Text
parseKey req =
    case lookup "key" (queryString req) of
        Just (Just bs) -> Just (TE.decodeUtf8 bs)
        _ -> Nothing

-- --------------------------------------------------------
-- Helpers
-- --------------------------------------------------------

jsonHeaders :: [(HeaderName, ByteString)]
jsonHeaders = [(hContentType, "application/json")]

sseHeaders :: [(HeaderName, ByteString)]
sseHeaders =
    [ (hContentType, "text/event-stream")
    , ("Cache-Control", "no-cache")
    ]

jsonResponse
    :: (ToJSON e)
    => Status
    -> e
    -> Response
jsonResponse status body =
    responseLBS status jsonHeaders (encode body)

{- | Verify the Ed25519 signature on a submission.
The signed message is the JSON encoding of the event.
-}
verifySig
    :: (ToJSON a)
    => Text
    -- ^ CESR-encoded signer public key
    -> Text
    -- ^ CESR-encoded Ed25519 signature
    -> a
    -- ^ The event (serialized as JSON for signing)
    -> Either Text ()
verifySig signerCesr sigCesr evt = do
    pk <- decodePubKey signerCesr
    sig <- decodeSig sigCesr
    let msg =
            LBS.toStrict $ encode evt
    if Ed25519.verify pk msg sig
        then Right ()
        else Left "signature verification failed"
  where
    decodePubKey t =
        case Cesr.decode t of
            Right Primitive{code = Ed25519PubKey, raw} ->
                case Ed25519.publicKeyFromBytes raw of
                    Right k -> Right k
                    Left e -> Left (T.pack e)
            Right _ ->
                Left "not an Ed25519 public key"
            Left e -> Left (T.pack e)
    decodeSig t =
        case Cesr.decode t of
            Right Primitive{code = Ed25519Sig, raw} ->
                Right raw
            Right _ ->
                Left "not an Ed25519 signature"
            Left e -> Left (T.pack e)
