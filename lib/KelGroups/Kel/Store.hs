{-# LANGUAGE NamedFieldPuns #-}

{- |
Module      : KelGroups.Kel.Store
Description : Member KELs and group chains in the server database
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

The hosted member KELs, one row per event in the
@member_kel_events@ table of the server database file, which this
store opens and closes itself; it creates only that table and
neither reads nor drops any other table the file holds: prefix, sequence
number, canonical event bytes, indexed signatures and digest,
unique on (prefix, sequence number). Group actions are interaction
rows of those KELs; the group chains and their heads are derived
from them in memory and never stored apart.

Stored KELs are not trusted: opening re-checks every stored KEL
with the KERI rule of "KelGroups.Kel", rebuilds every chain with
"KelGroups.Group" and refuses to open on a violation. Member
events and group actions are decided against the in-memory state
and persisted under one lock: a refusal writes nothing, an
acceptance is one INSERT (one SQLite transaction) and the KELs and
chains in memory are replaced only after it succeeds, together, in
one step no asynchronous exception can split.
-}
module KelGroups.Kel.Store
    ( MemberKels
    , openMemberKels
    , closeMemberKels
    , submitMemberEvent
    , lookupMemberKel
    , admitAction
    , lookupChain
    , lookupGroup
    ) where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Concurrent.STM
    ( TVar
    , atomically
    , newTVarIO
    , readTVarIO
    , writeTVar
    )
import Control.Exception (bracketOnError, uninterruptibleMask_)
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
import Database.SQLite.Simple
    ( Connection
    , close
    , execute
    , execute_
    , open
    , query_
    )
import KelGroups.Group
    ( Admission
    , Chain
    , GroupIndex
    , GroupRefusal
    , Hosted (..)
    , admit
    , groupIndex
    , rebuildChains
    , retried
    )
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

-- | The hosted member KELs and the group chains derived from them.
data MemberKels = MemberKels
    { mksConn :: Connection
    , mksLock :: MVar ()
    -- ^ Serializes submissions and admissions: decide, insert, publish
    , mksHosted :: TVar Hosted
    -- ^ Hosted KELs and group chains, as committed
    }

-- | A stored event row: prefix, sn, event bytes, signatures, digest.
type Row = (Text, Int, Text, Text, Text)

{- | Open the database file, create the member KEL table if absent,
load every stored KEL, re-checking each with the KERI rule, and
rebuild every group chain with the admission conditions. Fails, with
the file closed, if any stored KEL breaks the rule or any chain is
not one line of admissible actions from its genesis.
-}
openMemberKels :: FilePath -> IO MemberKels
openMemberKels path = bracketOnError (open path) close $ \conn -> do
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
    hosted <-
        either (fail . ("member KEL store refuses to open: " <>)) pure $ do
            kels <- loadKels rows
            chains <- rebuildChains kels
            pure Hosted{hostedKels = kels, hostedChains = chains}
    lock <- newMVar ()
    var <- newTVarIO hosted
    pure MemberKels{mksConn = conn, mksLock = lock, mksHosted = var}

-- | Close the database file.
closeMemberKels :: MemberKels -> IO ()
closeMemberKels MemberKels{mksConn} = close mksConn

{- | Submit an inception (hosted iff its prefix is not) or a
rotation (appended iff its prefix is hosted); any other event is
refused. A refusal stores nothing. No chain changes.
-}
submitMemberEvent
    :: MemberKels -> SignedEvent -> IO (Either KelRefusal MemberKel)
submitMemberEvent kels@MemberKels{mksLock, mksHosted} se =
    withMVar mksLock $ \() -> do
        hosted <- readTVarIO mksHosted
        case decide (hostedKels hosted) se of
            Left r -> pure (Left r)
            Right kel -> do
                commit kels se $
                    hosted
                        { hostedKels =
                            Map.insert (kelPrefix kel) kel (hostedKels hosted)
                        }
                pure (Right kel)

{- | Admit a group action ("KelGroups.Group.admit"): appended to its
signer's KEL and to its group's chain, or refused with nothing
stored. An event already in its signer's KEL with the same
signatures is a retry and answers its admission again, storing
nothing.
-}
admitAction
    :: MemberKels -> SignedEvent -> IO (Either GroupRefusal Admission)
admitAction kels@MemberKels{mksLock, mksHosted} se =
    withMVar mksLock $ \() -> do
        hosted <- readTVarIO mksHosted
        case retried hosted se of
            Just adm -> pure (Right adm)
            Nothing -> case admit hosted se of
                Left r -> pure (Left r)
                Right (hosted', adm) -> do
                    commit kels se hosted'
                    pure (Right adm)

-- | The hosted KEL of a prefix.
lookupMemberKel :: MemberKels -> Text -> IO (Maybe MemberKel)
lookupMemberKel MemberKels{mksHosted} pfx =
    Map.lookup pfx . hostedKels <$> readTVarIO mksHosted

-- | The chain of a group id.
lookupChain :: MemberKels -> Text -> IO (Maybe Chain)
lookupChain MemberKels{mksHosted} g =
    Map.lookup g . hostedChains <$> readTVarIO mksHosted

{- | The index of a group id, its head and tips read from one
committed state.
-}
lookupGroup :: MemberKels -> Text -> IO (Maybe GroupIndex)
lookupGroup MemberKels{mksHosted} g = do
    Hosted{hostedKels, hostedChains} <- readTVarIO mksHosted
    pure $ groupIndex hostedKels <$> Map.lookup g hostedChains

{- | Store an accepted event and publish the state it leads to.
Called under the lock with a state decided from the published one.
-}
commit :: MemberKels -> SignedEvent -> Hosted -> IO ()
commit MemberKels{mksConn, mksHosted} se hosted =
    -- commit and publish are one step: no asynchronous
    -- exception may leave the row on disk but not in memory
    uninterruptibleMask_ $ do
        execute
            mksConn
            "INSERT INTO member_kel_events \
            \(prefix, sn, event_bytes, signatures, digest) \
            \VALUES (?, ?, ?, ?, ?)"
            (toRow se)
        atomically $ writeTVar mksHosted hosted

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
