{-# LANGUAGE NamedFieldPuns #-}

{- |
Module      : KelGroups.Kel.Store
Description : Member KELs persisted in the server database
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

The hosted member KELs, one row per event in the
@member_kel_events@ table of the server database: prefix, sequence
number, canonical event bytes, indexed signatures and digest,
unique on (prefix, sequence number).

Stored KELs are not trusted: opening re-checks every stored KEL
with the KERI rule of "KelGroups.Kel" and refuses to open on a
violation. A submission is decided against the in-memory KELs and
persisted under one append lock: a refusal writes nothing, an
acceptance is one INSERT (one SQLite transaction) and memory is
updated only after it succeeds, in one step no asynchronous
exception can split.
-}
module KelGroups.Kel.Store
    ( MemberKels
    , openMemberKels
    , submitMemberEvent
    , lookupMemberKel
    ) where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Concurrent.STM
    ( TVar
    , atomically
    , modifyTVar'
    , newTVarIO
    , readTVarIO
    )
import Control.Exception (uninterruptibleMask_)
import Control.Monad (unless)
import Data.Aeson (eitherDecodeStrict)
import Data.Aeson.Encoding (encodingToLazyByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Function (on)
import Data.List (groupBy)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Database.SQLite.Simple (Connection, execute, execute_, query_)
import KelGroups.Kel
    ( KelRefusal (..)
    , MemberKel
    , host
    , kelPrefix
    , replayKel
    , rotate
    )
import KelGroups.Kel.Codec
    ( decodeEvent
    , decodeSignatures
    , encodeSignatures
    )
import Keri.Event
    ( Event (..)
    , eventDigest
    , eventPrefix
    , eventSequenceNumber
    , eventType
    )
import Keri.Event.Serialize (serializeEvent)
import Keri.Kel (SignedEvent (..))

-- | The hosted member KELs.
data MemberKels = MemberKels
    { mksConn :: Connection
    , mksLock :: MVar ()
    -- ^ Serializes submissions: decide, insert, then publish
    , mksKels :: TVar (Map Text MemberKel)
    -- ^ Hosted KELs by prefix, as committed
    }

-- | A stored event row: prefix, sn, event bytes, signatures, digest.
type Row = (Text, Int, Text, Text, Text)

{- | Create the member KEL table if absent and load every stored
KEL, re-checking each with the KERI rule. Fails if any stored
KEL breaks it.
-}
openMemberKels :: Connection -> IO MemberKels
openMemberKels conn = do
    execute_
        conn
        "CREATE TABLE IF NOT EXISTS member_kel_events \
        \( prefix TEXT NOT NULL \
        \, sn INTEGER NOT NULL \
        \, event_bytes TEXT NOT NULL \
        \, signatures TEXT NOT NULL \
        \, digest TEXT NOT NULL \
        \, PRIMARY KEY (prefix, sn) \
        \)"
    rows <-
        query_
            conn
            "SELECT prefix, sn, event_bytes, signatures, digest \
            \FROM member_kel_events ORDER BY prefix, sn"
    kels <-
        either (fail . ("member KEL store refuses to open: " <>)) pure $
            loadKels rows
    lock <- newMVar ()
    var <- newTVarIO kels
    pure MemberKels{mksConn = conn, mksLock = lock, mksKels = var}

{- | Submit an inception (hosted iff its prefix is not) or a
rotation (appended iff its prefix is hosted); any other event is
refused. A refusal stores nothing.
-}
submitMemberEvent
    :: MemberKels -> SignedEvent -> IO (Either KelRefusal MemberKel)
submitMemberEvent MemberKels{mksConn, mksLock, mksKels} se =
    withMVar mksLock $ \() -> do
        kels <- readTVarIO mksKels
        case decide kels se of
            Left r -> pure (Left r)
            Right kel -> do
                -- commit and publish are one step: no asynchronous
                -- exception may leave the row on disk but not in memory
                uninterruptibleMask_ $ do
                    execute
                        mksConn
                        "INSERT INTO member_kel_events \
                        \(prefix, sn, event_bytes, signatures, digest) \
                        \VALUES (?, ?, ?, ?, ?)"
                        (toRow se)
                    atomically $
                        modifyTVar' mksKels (Map.insert (kelPrefix kel) kel)
                pure (Right kel)

-- | The hosted KEL of a prefix.
lookupMemberKel :: MemberKels -> Text -> IO (Maybe MemberKel)
lookupMemberKel MemberKels{mksKels} pfx =
    Map.lookup pfx <$> readTVarIO mksKels

decide
    :: Map Text MemberKel -> SignedEvent -> Either KelRefusal MemberKel
decide kels se@SignedEvent{event} = case event of
    Inception{}
        | Map.member pfx kels -> Left AlreadyHosted
        | otherwise -> host se
    Rotation{} -> maybe (Left Unhosted) (`rotate` se) (Map.lookup pfx kels)
    other -> Left (UnexpectedEventKind (eventType other))
  where
    pfx = eventPrefix event

toRow :: SignedEvent -> Row
toRow SignedEvent{event, signatures} =
    ( eventPrefix event
    , eventSequenceNumber event
    , TE.decodeUtf8 (serializeEvent event)
    , TE.decodeUtf8
        . LBS.toStrict
        . encodingToLazyByteString
        $ encodeSignatures signatures
    , eventDigest event
    )

-- | Rebuild every stored KEL through the rule.
loadKels :: [Row] -> Either String (Map Text MemberKel)
loadKels rows =
    Map.fromList
        <$> traverse loadKel (groupBy ((==) `on` rowPrefix) rows)
  where
    rowPrefix (p, _, _, _, _) = p

loadKel :: [Row] -> Either String (Text, MemberKel)
loadKel rows = do
    ses <- traverse fromRow rows
    case ses of
        [] -> Left "empty KEL"
        first : rest -> do
            kel <- either (Left . refused) Right (replayKel first rest)
            pure (kelPrefix kel, kel)
  where
    refused r = "KEL " <> T.unpack pfx <> ": " <> show r
    pfx = case rows of
        (p, _, _, _, _) : _ -> p
        [] -> T.empty

-- | Decode a row; its columns must be those of the event it holds.
fromRow :: Row -> Either String SignedEvent
fromRow (pfx, sn, bytes, sigs, dg) = do
    let raw = TE.encodeUtf8 bytes
    evt <- eitherDecodeStrict raw >>= decodeEvent
    unless (serializeEvent evt == raw) $
        Left (at "event bytes are not canonical")
    unless
        ( eventPrefix evt == pfx
            && eventSequenceNumber evt == sn
            && eventDigest evt == dg
        )
        $ Left (at "row columns disagree with the event")
    ss <- eitherDecodeStrict (TE.encodeUtf8 sigs) >>= decodeSignatures
    pure SignedEvent{event = evt, signatures = ss}
  where
    at msg = T.unpack pfx <> " sn " <> show sn <> ": " <> msg
