{- |
Module      : KelGroups.Store
Description : SQLite-backed KEL store with KERI events
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

Persistent append-only event store backed by SQLite.
Each event is a KERI event stored as canonical JSON
alongside the signer key and CESR signature. The
group event anchor is stored separately for fast
replay without KERI event parsing. Chain metadata
(prefix, sequence number, digest) is stored per row
for efficient chain-tip recovery.

The server holds no key: a fresh store is empty, and
the first member submission is the group KEL's
inception.
-}
module KelGroups.Store
    ( KELStore (..)
    , ChainTip (..)
    , StoredEvent (..)
    , openKEL
    , closeKEL
    , openIntegratedKEL
    , appendEvent
    , appendIntegratedEvent
    , readState
    , readEventsFrom
    , kelLength
    , chainTip
    ) where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Concurrent.STM
    ( TVar
    , atomically
    , newTVarIO
    , readTVar
    , readTVarIO
    , writeTVar
    )
import Control.Exception (evaluate)
import Data.Aeson (FromJSON, ToJSON, decode, encode)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Database.SQLite.Simple
    ( Connection
    , Only (..)
    , close
    , execute
    , execute_
    , open
    , query
    , query_
    )
import KelGroups.Event (GroupEvent, IntegratedEvent)
import KelGroups.Fold
    ( AppFold
    , IntegratedError
    , IntegratedResult (..)
    , Integration
    , applyIntegratedEvent
    , foldIntegratedFrom
    )
import KelGroups.Fold qualified as Fold
import KelGroups.Server.JSON ()
import KelGroups.State (GroupState, emptyState)
import Keri.Event
    ( Event
    , eventDigest
    , eventPrefix
    , eventSequenceNumber
    )
import Keri.Event.Serialize (serializeEvent)

-- | Current tip of the KERI chain.
data ChainTip = ChainTip
    { tipPrefix :: Text
    -- ^ Identifier prefix (from inception SAID)
    , tipSeqNo :: Int
    -- ^ Sequence number of the last event
    , tipDigest :: Text
    -- ^ SAID of the last event
    }
    deriving stock (Show, Eq)

{- | A stored event as returned by 'readEventsFrom'.
Contains everything a client needs to verify the
chain independently.
-}
data StoredEvent = StoredEvent
    { seSigner :: Text
    -- ^ CESR-encoded signer public key
    , seEventBytes :: ByteString
    -- ^ Canonical JSON of the KERI event
    , seSignature :: Text
    -- ^ CESR-encoded Ed25519 signature
    }
    deriving stock (Show, Eq)

-- | A handle to a SQLite-backed KEL.
data KELStore a = KELStore
    { storeConn :: Connection
    -- ^ SQLite connection
    , stateVar :: TVar (GroupState a)
    -- ^ Hot state updated incrementally
    , tipVar :: TVar (Maybe ChainTip)
    -- ^ Current chain tip
    , lengthVar :: TVar Int
    -- ^ Number of events
    , storeAppendLock :: MVar ()
    -- ^ Serializes integrated appends (F1 repair)
    }

{- | Open or create a KEL at the given file path.
Replays all existing events to rebuild the in-memory
state and chain tip; a fresh store holds no event.

HISTORICAL-NON-PRODUCTION: 'openKEL'/'appendEvent' keep the accepted
behavior and the historical group-event log. The integrated production
path ('openIntegratedKEL'/'appendIntegratedEvent' below) never calls
these; they receive no new production responsibility in this slice.
-}
openKEL
    :: (FromJSON a)
    => AppFold a
    -> a
    -- ^ Initial application fold value
    -> FilePath
    -> IO (KELStore a)
openKEL appFoldFn initial path = do
    conn <- open path
    execute_
        conn
        "CREATE TABLE IF NOT EXISTS events \
        \( id INTEGER PRIMARY KEY AUTOINCREMENT \
        \, signer TEXT NOT NULL \
        \, event_bytes TEXT NOT NULL \
        \, signature TEXT NOT NULL \
        \, group_event TEXT NOT NULL \
        \, prefix TEXT NOT NULL \
        \, seq_no INTEGER NOT NULL \
        \, digest TEXT NOT NULL \
        \)"
    -- Replay group events for business state
    rows <-
        query_
            conn
            "SELECT signer, group_event FROM events \
            \ORDER BY id"
            :: IO [(Text, LBS.ByteString)]
    let gs =
            foldl
                (replayRow appFoldFn)
                (emptyState initial)
                rows
    -- Recover chain tip from last row
    tipRows <-
        query_
            conn
            "SELECT prefix, seq_no, digest \
            \FROM events ORDER BY id DESC LIMIT 1"
            :: IO [(Text, Int, Text)]
    let tip' = case tipRows of
            [(p, s, d)] ->
                Just
                    ChainTip
                        { tipPrefix = p
                        , tipSeqNo = s
                        , tipDigest = d
                        }
            _ -> Nothing
    stVar <- newTVarIO gs
    tVar <- newTVarIO tip'
    [Only n] <-
        query_
            conn
            "SELECT COUNT(*) FROM events"
    lVar <- newTVarIO (n :: Int)
    appendLock <- newMVar ()
    pure
        KELStore
            { storeConn = conn
            , stateVar = stVar
            , tipVar = tVar
            , lengthVar = lVar
            , storeAppendLock = appendLock
            }

-- | Close the KEL store.
closeKEL :: KELStore a -> IO ()
closeKEL = close . storeConn

{- | Append a verified event. Persists to SQLite and
updates the in-memory state. The caller is
responsible for constructing and verifying the KERI
event and signature before calling this.
-}
appendEvent
    :: (ToJSON a)
    => KELStore a
    -> AppFold a
    -> Text
    -- ^ Signer CESR public key
    -> Event
    -- ^ Constructed KERI event
    -> Text
    -- ^ CESR-encoded Ed25519 signature
    -> GroupEvent a
    -- ^ The anchor (group event) for folding
    -> IO ()
appendEvent store appFoldFn signer evt sig groupEvt =
    do
        let eventBytes =
                TE.decodeUtf8 (serializeEvent evt)
            groupJson = encode groupEvt
            prefix' = eventPrefix evt
            seqNo = eventSequenceNumber evt
            digest' = eventDigest evt
        execute
            (storeConn store)
            "INSERT INTO events \
            \(signer, event_bytes, signature, \
            \group_event, prefix, seq_no, digest) \
            \VALUES (?, ?, ?, ?, ?, ?, ?)"
            ( signer
            , eventBytes
            , sig
            , groupJson
            , prefix'
            , seqNo
            , digest'
            )
        let newTip =
                ChainTip
                    { tipPrefix = prefix'
                    , tipSeqNo = seqNo
                    , tipDigest = digest'
                    }
        atomically $ do
            gs <- readTVar (stateVar store)
            writeTVar (stateVar store) $
                Fold.applyEvent
                    appFoldFn
                    gs
                    (signer, groupEvt)
            writeTVar (tipVar store) (Just newTip)
            n <- readTVar (lengthVar store)
            writeTVar (lengthVar store) (n + 1)

-- | Read current state (from TVar, O(1)).
readState :: KELStore a -> IO (GroupState a)
readState = readTVarIO . stateVar

{- | Read events from index @n@ onward (1-based,
matching SQLite rowid). Returns events in order
with the data clients need for chain verification.
-}
readEventsFrom
    :: KELStore a
    -> Int
    -> IO [StoredEvent]
readEventsFrom store n = do
    rows <-
        query
            (storeConn store)
            "SELECT signer, event_bytes, signature \
            \FROM events WHERE id >= ? ORDER BY id"
            (Only n)
            :: IO [(Text, Text, Text)]
    pure $ map toStoredEvent rows
  where
    toStoredEvent (s, eb, sig) =
        StoredEvent
            { seSigner = s
            , seEventBytes = TE.encodeUtf8 eb
            , seSignature = sig
            }

-- | Number of events in the KEL.
kelLength :: KELStore a -> IO Int
kelLength = readTVarIO . lengthVar

{- | Get the current chain tip, or 'Nothing' if the
KEL is empty (no inception yet).
-}
chainTip :: KELStore a -> IO (Maybe ChainTip)
chainTip = readTVarIO . tipVar

-- --------------------------------------------------------
-- Internal helpers
-- --------------------------------------------------------

{- | Replay a single row into the group state.
Decodes the stored group event JSON.
-}
replayRow
    :: (FromJSON a)
    => AppFold a
    -> GroupState a
    -> (Text, LBS.ByteString)
    -> GroupState a
replayRow appFoldFn gs (signer, groupJson) =
    case decode groupJson of
        Just groupEvt ->
            Fold.applyEvent
                appFoldFn
                gs
                (signer, groupEvt)
        Nothing -> gs

-- --------------------------------------------------------
-- Integrated production store
-- --------------------------------------------------------

{- | Open or create an integrated KEL at the given file path. The caller
supplies the founding aggregate (which holds the founding admin): a fresh
database persists it in a 'founding' table and starts from it; an existing
database loads it and REQUIRES the passed founding to equal the stored one
(else IO failure), then replays stored integrated rows over it. There is
no bootstrap arm and no inception on this path: integrated
rows carry no KERI envelope (envelope columns hold documented
placeholders; the authoritative payload is the integrated-event JSON).
-}
openIntegratedKEL
    :: (ToJSON s, FromJSON s, FromJSON e, FromJSON bp, Eq s)
    => Integration s e bp err
    -> GroupState s
    -> FilePath
    -> IO (KELStore s)
openIntegratedKEL integration founding path = do
    conn <- open path
    execute_
        conn
        "CREATE TABLE IF NOT EXISTS events \
        \( id INTEGER PRIMARY KEY AUTOINCREMENT \
        \, signer TEXT NOT NULL \
        \, event_bytes TEXT NOT NULL \
        \, signature TEXT NOT NULL \
        \, group_event TEXT NOT NULL \
        \, prefix TEXT NOT NULL \
        \, seq_no INTEGER NOT NULL \
        \, digest TEXT NOT NULL \
        \)"
    execute_
        conn
        "CREATE TABLE IF NOT EXISTS founding \
        \( id INTEGER PRIMARY KEY CHECK (id = 1) \
        \, founding_json TEXT NOT NULL \
        \)"
    foundingRows <-
        query_
            conn
            "SELECT founding_json FROM founding"
            :: IO [Only LBS.ByteString]
    [Only eventCount] <-
        query_
            conn
            "SELECT COUNT(*) FROM events"
            :: IO [Only Int]
    base <- case foundingRows of
        [] ->
            if eventCount == 0
                then do
                    execute
                        conn
                        "INSERT INTO founding \
                        \(id, founding_json) VALUES (1, ?)"
                        (Only (encode founding))
                    pure founding
                else fail "founding absent but events exist"
        [Only stored] ->
            case decode stored of
                Nothing -> fail "stored founding is corrupt"
                Just loaded ->
                    if loaded == founding
                        then pure loaded
                        else
                            fail
                                "founding mismatch: passed founding differs \
                                \from stored founding"
        _ -> fail "multiple founding rows"
    rows <-
        query_
            conn
            "SELECT signer, group_event FROM events ORDER BY id"
            :: IO [(Text, LBS.ByteString)]
    let decoded =
            [ (signer, evt)
            | (signer, js) <- rows
            , Just evt <- [decode js]
            ]
        gs = foldIntegratedFrom integration base decoded
    stVar <- newTVarIO gs
    tVar <- newTVarIO Nothing
    lVar <- newTVarIO eventCount
    appendLock <- newMVar ()
    pure
        KELStore
            { storeConn = conn
            , stateVar = stVar
            , tipVar = tVar
            , lengthVar = lVar
            , storeAppendLock = appendLock
            }

{- | Validate-then-append on the integrated boundary. Runs
'applyIntegratedEvent' first: on refusal persists NOTHING and touches NO
in-memory state; on success inserts the SQL row then updates the hot
state, tip length included.

Concurrency + refusal order (F3 repair): appends hold 'storeAppendLock'
across one serialized transition — fresh state read, then the decision,
then payload-encode forcing, then the SQL row, then the TVar commit.
The decision is authoritative and comes first: a refusal short-circuits
before the application codec is ever forced, so a faulting codec cannot
replace a payload-independent refusal with an exception. Encode forcing
stays post-acceptance and pre-INSERT in the same hold, so an accepted
faulting codec still throws observably with hot state untouched, and
overlapping accepted callers still conserve every committed transition
and event count. A SQL failure still propagates to the caller with hot
state untouched and the lock released.
-}
appendIntegratedEvent
    :: (ToJSON e, ToJSON bp)
    => KELStore s
    -> Integration s e bp err
    -> Text
    -> IntegratedEvent bp e
    -> IO (Either (IntegratedError err) (IntegratedResult s))
appendIntegratedEvent store integration signer event =
    withMVar (storeAppendLock store) $ \() -> do
        gs <- readState store
        case applyIntegratedEvent integration gs signer event of
            Left err -> pure (Left err)
            Right result -> do
                let payloadJson = encode event
                    payloadText = TE.decodeUtf8 (LBS.toStrict payloadJson)
                    noEnvelope = T.empty
                _ <- evaluate payloadText
                n <- kelLength store
                execute
                    (storeConn store)
                    "INSERT INTO events \
                    \(signer, event_bytes, signature, \
                    \group_event, prefix, seq_no, digest) \
                    \VALUES (?, ?, ?, ?, ?, ?, ?)"
                    ( signer
                    , payloadText
                    , noEnvelope
                    , payloadJson
                    , noEnvelope
                    , n + 1
                    , noEnvelope
                    )
                atomically $ do
                    writeTVar (stateVar store) (irState result)
                    writeTVar (lengthVar store) (n + 1)
                pure (Right result)
