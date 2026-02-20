{- |
Module      : KelGroups.Store
Description : SQLite-backed KEL store with random access
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

Persistent append-only event store backed by SQLite.
Each event is CBOR-encoded and stored as a blob. The
in-memory group state is kept in a 'TVar' and updated
incrementally on each append. Clients can request events
from any index onward for catch-up.
-}
module KelGroups.Store
    ( KELStore (..)
    , openKEL
    , closeKEL
    , appendEvent
    , readState
    , readEventsFrom
    , kelLength
    ) where

import Codec.Serialise (Serialise, deserialise, serialise)
import Control.Concurrent.STM
    ( TVar
    , atomically
    , newTVarIO
    , readTVar
    , readTVarIO
    , writeTVar
    )
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
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
import KelGroups.Event (GroupEvent)
import KelGroups.Fold (AppFold, applyEvent)
import KelGroups.State (GroupState, emptyState)
import KelGroups.Store.Serialise ()

-- | A handle to a SQLite-backed KEL.
data KELStore a = KELStore
    { storeConn :: Connection
    -- ^ SQLite connection
    , stateVar :: TVar (GroupState a)
    -- ^ Hot state updated incrementally
    }

{- | Open or create a KEL at the given file path.
Replays all existing events to rebuild the in-memory
state.
-}
openKEL
    :: (Serialise a)
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
        \, event BLOB NOT NULL \
        \)"
    rows <-
        query_
            conn
            "SELECT signer, event FROM events \
            \ORDER BY id"
            :: IO [(Text, LBS.ByteString)]
    let events = map decodeRow rows
        gs = foldl (applyEvent appFoldFn) (emptyState initial) events
    var <- newTVarIO gs
    pure KELStore{storeConn = conn, stateVar = var}

-- | Close the KEL store.
closeKEL :: KELStore a -> IO ()
closeKEL = close . storeConn

{- | Append a validated event. Persists to SQLite and
updates the in-memory state atomically.
-}
appendEvent
    :: (Serialise a)
    => KELStore a
    -> AppFold a
    -> (Text, GroupEvent a)
    -> IO ()
appendEvent store appFoldFn entry@(signer, evt) = do
    let blob = serialise evt
    execute
        (storeConn store)
        "INSERT INTO events (signer, event) VALUES (?, ?)"
        (signer, blob)
    atomically $ do
        gs <- readTVar (stateVar store)
        writeTVar (stateVar store) $
            applyEvent appFoldFn gs entry

-- | Read current state (from TVar, O(1)).
readState :: KELStore a -> IO (GroupState a)
readState = readTVarIO . stateVar

{- | Read events from index @n@ onward (1-based,
matching SQLite rowid). Returns events in order.
-}
readEventsFrom
    :: (Serialise a)
    => KELStore a
    -> Int
    -> IO [(Text, GroupEvent a)]
readEventsFrom store n = do
    rows <-
        query
            (storeConn store)
            "SELECT signer, event FROM events \
            \WHERE id >= ? ORDER BY id"
            (Only n)
            :: IO [(Text, LBS.ByteString)]
    pure $ map decodeRow rows

-- | Number of events in the KEL.
kelLength :: KELStore a -> IO Int
kelLength store = do
    [Only n] <-
        query_
            (storeConn store)
            "SELECT COUNT(*) FROM events"
    pure n

-- | Decode a row from the database.
decodeRow
    :: (Serialise a)
    => (Text, LBS.ByteString)
    -> (Text, GroupEvent a)
decodeRow (signer, blob) =
    (signer, deserialise blob)
