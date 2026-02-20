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
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Text.Read qualified as TR
import KelGroups.Bootstrap (AuthMode (..), authMode)
import KelGroups.Fold (AppFold)
import KelGroups.Server.JSON
    ( AppendResult (..)
    , ServerError (..)
    , Submission (..)
    )
import KelGroups.State (GroupState)
import KelGroups.Store
    ( KELStore
    , appendEvent
    , kelLength
    , readEventsFrom
    , readState
    )
import KelGroups.Types (GroupConfig)
import KelGroups.Validate (validateEvent)
import Network.HTTP.Types
    ( HeaderName
    , Status
    , hContentType
    , status200
    , status400
    , status401
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

-- | Build a WAI 'Application' from a 'ServerEnv'.
mkApp
    :: (Serialise a, FromJSON a, ToJSON a)
    => ServerEnv a
    -> Application
mkApp env req respond =
    case (requestMethod req, pathInfo req) of
        ("GET", ["condition"]) ->
            handleCondition env req respond
        ("GET", ["events"]) ->
            handleGetEvent env req respond
        ("POST", ["events"]) ->
            handlePostEvent env req respond
        ("GET", ["stream"]) ->
            handleStream env req respond
        _ ->
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
    :: (Serialise a, FromJSON a)
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
    :: (Serialise a)
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
    :: (Serialise a)
    => ServerEnv a
    -> Submission a
    -> (Response -> IO b)
    -> IO b
doAppend env sub respond = do
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
