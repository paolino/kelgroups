{- |
Module      : KelGroups.Server
Description : HTTP server for kelgroups (WAI application)
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

WAI application over the member KEL store: @POST /kel@ and
@GET /kel/<prefix>@ host and serve member KELs, @POST /actions@
admits group actions. Every refusal answers its status and
@{"error": <class>, "detail": <text>}@ and stores nothing.
-}
module KelGroups.Server
    ( kelApp
    ) where

import Data.Aeson (eitherDecode, encode, object, (.=))
import Data.Aeson.Encoding qualified as Encoding
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as T
import KelGroups.Group (Admission (..), GroupRefusal (..))
import KelGroups.Kel
    ( KelRefusal (..)
    , kelEvents
    , kelPrefix
    )
import KelGroups.Kel qualified as Kel
import KelGroups.Kel.Codec (decodeSignedEvent, encodeSignedEvent)
import KelGroups.Kel.Store
    ( MemberKels
    , admitAction
    , lookupMemberKel
    , submitMemberEvent
    )
import Keri.Event (eventSequenceNumber)
import Keri.Kel (SignedEvent (..))
import Network.HTTP.Types
    ( HeaderName
    , Status
    , hContentType
    , methodGet
    , methodHead
    , status200
    , status400
    , status403
    , status404
    , status409
    , status422
    )
import Network.Wai
    ( Application
    , Response
    , pathInfo
    , requestMethod
    , responseLBS
    , strictRequestBody
    )

{- | The member KEL endpoints, @POST /kel@ and @GET /kel/<prefix>@,
and group action admission, @POST /actions@. An unmatched GET or
HEAD is passed to the optional fallback application (the static
client files); any other unmatched request answers 404.
-}
kelApp :: MemberKels -> Maybe Application -> Application
kelApp kels mFallback req respond =
    case (requestMethod req, pathInfo req) of
        ("POST", ["kel"]) -> handlePostKel kels req respond
        ("GET", ["kel", pfx]) -> handleGetKel kels pfx respond
        ("POST", ["actions"]) -> handlePostAction kels req respond
        _ -> case mFallback of
            Just fallback
                | requestMethod req `elem` [methodGet, methodHead] ->
                    fallback req respond
            _ ->
                respond $
                    responseLBS status404 jsonHeaders $
                        encode $
                            object
                                [ "error" .= ("badRequest" :: Text)
                                , "message" .= ("not found" :: Text)
                                ]

-- --------------------------------------------------------
-- POST /kel, GET /kel/<prefix>
-- --------------------------------------------------------

{- | Submit an inception or a rotation. 200 with the prefix,
sequence number and digest of the accepted event; otherwise the
refusal status of 'refusalStatus', nothing stored.
-}
handlePostKel :: MemberKels -> Application
handlePostKel kels req respond = do
    body <- strictRequestBody req
    case eitherDecode body >>= decodeSignedEvent of
        Left err ->
            respond $ refusalResponse status400 "notDecodable" (T.pack err)
        Right se -> do
            r <- submitMemberEvent kels se
            respond $ case r of
                Left refusal ->
                    refusalResponse
                        (refusalStatus refusal)
                        (refusalName refusal)
                        (T.pack (show refusal))
                Right kel ->
                    responseLBS status200 jsonHeaders $
                        encode $
                            object
                                [ "prefix" .= kelPrefix kel
                                , "sn" .= eventSequenceNumber (event se)
                                , "digest" .= Kel.tip kel
                                ]

-- | The hosted KEL, oldest first, in the wire form; 404 if unhosted.
handleGetKel :: MemberKels -> Text -> (Response -> IO b) -> IO b
handleGetKel kels pfx respond = do
    mkel <- lookupMemberKel kels pfx
    respond $ case mkel of
        Nothing ->
            refusalResponse
                status404
                (refusalName Unhosted)
                (T.pack (show Unhosted))
        Just kel ->
            responseLBS status200 jsonHeaders $
                Encoding.encodingToLazyByteString $
                    Encoding.list encodeSignedEvent (kelEvents kel)

-- --------------------------------------------------------
-- POST /actions
-- --------------------------------------------------------

{- | Admit a group action: a signed interaction in the wire form of
@POST /kel@. 200 with the group, its new head, the signer and the
event's sequence number, also for an identical retry; otherwise the
refusal status of 'groupRefusalStatus', nothing stored.
-}
handlePostAction :: MemberKels -> Application
handlePostAction kels req respond = do
    body <- strictRequestBody req
    case eitherDecode body >>= decodeSignedEvent of
        Left err ->
            respond $ refusalResponse status400 "notDecodable" (T.pack err)
        Right se -> do
            r <- admitAction kels se
            respond $ case r of
                Left refusal ->
                    refusalResponse
                        (groupRefusalStatus refusal)
                        (groupRefusalName refusal)
                        (T.pack (show refusal))
                Right adm ->
                    responseLBS status200 jsonHeaders $
                        encode $
                            object
                                [ "group" .= admittedGroup adm
                                , "head" .= admittedHead adm
                                , "prefix" .= admittedPrefix adm
                                , "sn" .= admittedSn adm
                                ]

-- | HTTP status of a group action refusal (data model D4).
groupRefusalStatus :: GroupRefusal -> Status
groupRefusalStatus = \case
    NotAGroupAction _ -> status400
    KelRefused r -> refusalStatus r
    NoSuchGroup -> status404
    NotAMember -> status403
    PrevNotHead -> status409
    GroupExists -> status409
    NotAnAdmin -> status403
    MemberNotHosted -> status404
    AlreadyMember -> status409
    TargetNotMember -> status409
    AlreadyAdmin -> status409
    TargetNotAdmin -> status409
    LastAdmin -> status409

-- | Stable machine-readable name of a group action refusal.
groupRefusalName :: GroupRefusal -> Text
groupRefusalName = \case
    NotAGroupAction _ -> "notAGroupAction"
    KelRefused r -> refusalName r
    NoSuchGroup -> "noSuchGroup"
    NotAMember -> "notAMember"
    PrevNotHead -> "prevNotHead"
    GroupExists -> "groupExists"
    NotAnAdmin -> "notAnAdmin"
    MemberNotHosted -> "memberNotHosted"
    AlreadyMember -> "alreadyMember"
    TargetNotMember -> "targetNotMember"
    AlreadyAdmin -> "alreadyAdmin"
    TargetNotAdmin -> "targetNotAdmin"
    LastAdmin -> "lastAdmin"

-- | HTTP status of a refusal (data model D4).
refusalStatus :: KelRefusal -> Status
refusalStatus = \case
    Unhosted -> status404
    AlreadyHosted -> status409
    NotTipSuccessor -> status409
    ForeignPrefix -> status409
    UnexpectedEventKind _ -> status422
    SaidMismatch -> status422
    PrefixNotSaid -> status422
    InceptionNotFirst -> status422
    MissingNextCommitment -> status422
    ThresholdOutOfRange -> status422
    WitnessesPresent -> status422
    CommitmentNotRevealed -> status422
    InvalidSignatures -> status422

-- | Stable machine-readable name of a refusal class.
refusalName :: KelRefusal -> Text
refusalName = \case
    UnexpectedEventKind _ -> "unexpectedEventKind"
    SaidMismatch -> "saidMismatch"
    PrefixNotSaid -> "prefixNotSaid"
    InceptionNotFirst -> "inceptionNotFirst"
    MissingNextCommitment -> "missingNextCommitment"
    ThresholdOutOfRange -> "thresholdOutOfRange"
    WitnessesPresent -> "witnessesPresent"
    ForeignPrefix -> "foreignPrefix"
    NotTipSuccessor -> "notTipSuccessor"
    CommitmentNotRevealed -> "commitmentNotRevealed"
    InvalidSignatures -> "invalidSignatures"
    AlreadyHosted -> "alreadyHosted"
    Unhosted -> "unhosted"

-- | @{"error": <class>, "detail": <text>}@.
refusalResponse :: Status -> Text -> Text -> Response
refusalResponse status cls detail =
    responseLBS status jsonHeaders $
        encode $
            object ["error" .= cls, "detail" .= detail]

-- --------------------------------------------------------
-- Helpers
-- --------------------------------------------------------

jsonHeaders :: [(HeaderName, ByteString)]
jsonHeaders = [(hContentType, "application/json")]
