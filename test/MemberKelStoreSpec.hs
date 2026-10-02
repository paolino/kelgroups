{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : MemberKelStoreSpec
Description : Member KELs persisted in the server database
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

Checks of 'KelGroups.Kel.Store' against a real SQLite file the
store opens itself. Database state is compared as a dump of every
table the file holds, discovered at run time.
-}
module MemberKelStoreSpec
    ( spec
    , withDb
    , withKels
    , oldPathTables
    , tableNames
    , dumpTables
    ) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.Async (mapConcurrently)
import Control.Concurrent.MVar
    ( isEmptyMVar
    , newEmptyMVar
    , putMVar
    , takeMVar
    )
import Control.Exception (SomeException, bracket, catch, try)
import Control.Monad (forM)
import Data.Aeson.Encoding (encodingToLazyByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Database.SQLite.Simple
    ( Connection
    , Only (..)
    , Query (..)
    , SQLData
    , execute
    , execute_
    , query_
    , withConnection
    )
import KelGroups.Kel
    ( KelRefusal (..)
    , MemberKel
    , kelEvents
    , replayKel
    , rotate
    )
import KelGroups.Kel.Codec (encodeSignatures)
import KelGroups.Kel.Store
    ( MemberKels
    , closeMemberKels
    , lookupMemberKel
    , openMemberKels
    , submitMemberEvent
    )
import Keri.Event (RotationData (..), eventDigest)
import Keri.Event.Serialize (serializeEvent)
import Keri.Kel (SignedEvent (..))
import MemberKelFixtures
    ( Chain (..)
    , KeySet (..)
    , genKeySet
    , genRotChain
    , interactChain
    , mapRotation
    , rotateChain
    , rotationOf
    , signAll
    )
import System.Directory (copyFile, removeFile)
import System.IO.Temp (emptySystemTempFile)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.Hspec.QuickCheck (modifyMaxSuccess, prop)
import Test.QuickCheck
    ( conjoin
    , counterexample
    , forAll
    , generate
    , ioProperty
    , property
    , vectorOf
    , (===)
    )

-- | A fresh database file, removed afterwards.
withDb :: (FilePath -> IO a) -> IO a
withDb =
    bracket
        (emptySystemTempFile "kelgroups-member-kels-.db")
        removeFile

-- | Every table of the database file.
tableNames :: Connection -> IO [Text]
tableNames conn =
    map fromOnly
        <$> query_
            conn
            "SELECT name FROM sqlite_master WHERE type = 'table' \
            \ORDER BY name"

-- | Every row of every table, in insertion order.
dumpTables :: Connection -> IO [(Text, [[SQLData]])]
dumpTables conn = do
    names <- tableNames conn
    forM names $ \n -> do
        rows <-
            query_ conn $
                Query ("SELECT * FROM \"" <> n <> "\" ORDER BY rowid")
        pure (n, rows)

-- | The member KEL store on a database file, and a second connection to it.
data Opened = Opened
    { opConn :: Connection
    , opKels :: MemberKels
    }

-- | The member KEL store open on a file.
withKels :: FilePath -> (MemberKels -> IO a) -> IO a
withKels path = bracket (openMemberKels path) closeMemberKels

withOpened :: FilePath -> (Opened -> IO a) -> IO a
withOpened path act =
    withKels path $ \kels -> withConnection path $ \c ->
        act Opened{opConn = c, opKels = kels}

-- | The single table 'openMemberKels' creates in a fresh database.
memberTable :: FilePath -> IO Text
memberTable path =
    withKels path $ \_ ->
        withConnection path tableNames >>= \case
            [t] -> pure t
            ts -> error ("expected one member KEL table, got " <> show ts)

submitAll
    :: MemberKels -> [SignedEvent] -> IO [Either KelRefusal MemberKel]
submitAll kels = mapM (submitMemberEvent kels)

isRefusal :: Either a b -> Bool
isRefusal = either (const True) (const False)

firstEvent :: Chain -> SignedEvent
firstEvent ch = case chEvents ch of
    (e : _) -> e
    [] -> error "empty chain"

sigsText :: [(Int, Text)] -> Text
sigsText =
    TE.decodeUtf8
        . LBS.toStrict
        . encodingToLazyByteString
        . encodeSignatures

spec :: Spec
spec = describe "KelGroups.Kel.Store (member KELs in SQLite)" $
    modifyMaxSuccess (const 25) $ do
        prop
            "INV-38-HOST-ONCE: an inception of a hosted prefix is refused, \
            \identical resend included, and the KEL is unchanged"
            $ forAll genRotChain
            $ \ch -> ioProperty $ withDb $ \path ->
                withOpened path $ \Opened{opConn, opKels} -> do
                    let icp = firstEvent ch
                        resigned = icp{signatures = reverse (signatures icp)}
                    r0 <- submitMemberEvent opKels icp
                    d0 <- dumpTables opConn
                    r1 <- submitMemberEvent opKels icp
                    r2 <- submitMemberEvent opKels resigned
                    d1 <- dumpTables opConn
                    m1 <- lookupMemberKel opKels (chPrefix ch)
                    pure $
                        conjoin
                            [ fmap kelEvents r0 === Right [icp]
                            , r1 === Left AlreadyHosted
                            , r2 === Left AlreadyHosted
                            , d1 === d0
                            , m1 === either (const Nothing) Just r0
                            ]

        prop
            "INV-38-UNHOSTED: a rotation for an unhosted prefix is refused \
            \and nothing is stored"
            $ forAll ((,) <$> genRotChain <*> genKeySet)
            $ \(ch, n1) -> ioProperty $ withDb $ \path ->
                withOpened path $ \Opened{opConn, opKels} -> do
                    let (rotSe, _) = rotateChain n1 ch
                    d0 <- dumpTables opConn
                    r <- submitMemberEvent opKels rotSe
                    d1 <- dumpTables opConn
                    m <- lookupMemberKel opKels (chPrefix ch)
                    landed <- submitAll opKels (chEvents ch <> [rotSe])
                    pure $
                        conjoin
                            [ r === Left Unhosted
                            , d1 === d0
                            , m === Nothing
                            , counterexample "legitimate KEL refused" $
                                not (any isRefusal landed)
                            ]

        prop
            "INV-38-ROT-FRAME: an accepted rotation extends only its own \
            \KEL; other KELs and their stored rows are unchanged"
            $ forAll ((,,) <$> genRotChain <*> genRotChain <*> genKeySet)
            $ \(a, b, n1) -> ioProperty $ withDb $ \path ->
                withOpened path $ \Opened{opConn, opKels} -> do
                    rs <- submitAll opKels (chEvents a <> chEvents b)
                    let (rotSe, _) = rotateChain n1 a
                    d0 <- dumpTables opConn
                    kb0 <- lookupMemberKel opKels (chPrefix b)
                    r <- submitMemberEvent opKels rotSe
                    d1 <- dumpTables opConn
                    kb1 <- lookupMemberKel opKels (chPrefix b)
                    ka1 <- lookupMemberKel opKels (chPrefix a)
                    let changed =
                            [ (n, rows0, rows1)
                            | ((n, rows0), (_, rows1)) <- zip d0 d1
                            , rows0 /= rows1
                            ]
                    pure $
                        conjoin
                            [ counterexample "setup refused" $
                                not (any isRefusal rs)
                            , fmap kelEvents r
                                === Right (chEvents a <> [rotSe])
                            , ka1 === either (const Nothing) Just r
                            , kb1 === kb0
                            , map fst d1 === map fst d0
                            , case changed of
                                [(_, rows0, rows1)] ->
                                    counterexample "not one appended row" $
                                        take (length rows0) rows1 == rows0
                                            && length rows1 == length rows0 + 1
                                _ ->
                                    counterexample
                                        ("changed tables: " <> show changed)
                                        False
                            ]

        prop
            "INV-38-ATOMIC: every refusal leaves database and memory \
            \unchanged; every acceptance is visible and survives reopen"
            $ forAll ((,,) <$> genRotChain <*> genKeySet <*> genKeySet)
            $ \(ch, n1, n2) -> ioProperty $ withDb $ \path -> do
                let (rotSe, _) = rotateChain n1 ch
                    (otherRot, _) = rotateChain n2 ch
                    (ixnSe, _) = interactChain ch
                    signedByCurrent =
                        signAll
                            (ksPairs (chCurrent ch))
                            ( rotationOf
                                (chPrefix ch)
                                (chSn ch + 1)
                                (chTip ch)
                                (chNext ch)
                                n1
                            )
                    plan =
                        [(se, True) | se <- chEvents ch]
                            <> [ (signedByCurrent, False)
                               , (firstEvent ch, False)
                               , (ixnSe, False)
                               , (rotSe, True)
                               , (rotSe, False)
                               , (otherRot, False)
                               ]
                results <- forM plan $ \(se, shouldLand) -> do
                    (d0, m0, r, d1, m1) <-
                        withOpened path $ \Opened{opConn, opKels} -> do
                            d0 <- dumpTables opConn
                            m0 <- lookupMemberKel opKels (chPrefix ch)
                            r <- submitMemberEvent opKels se
                            d1 <- dumpTables opConn
                            m1 <- lookupMemberKel opKels (chPrefix ch)
                            pure (d0, m0, r, d1, m1)
                    reopened <- withOpened path $ \Opened{opKels} ->
                        lookupMemberKel opKels (chPrefix ch)
                    pure $
                        counterexample (show (se, shouldLand, r)) $
                            case r of
                                Left _ ->
                                    conjoin
                                        [ shouldLand === False
                                        , d1 === d0
                                        , m1 === m0
                                        , reopened === m0
                                        ]
                                Right kel ->
                                    conjoin
                                        [ shouldLand === True
                                        , m1 === Just kel
                                        , reopened === Just kel
                                        ]
                pure (conjoin results)

        prop
            "INV-38-ATOMIC: concurrent submissions land as if one at a \
            \time; memory, reopen and the accepted set agree"
            $ forAll
                ( (,,)
                    <$> vectorOf 4 genRotChain
                    <*> genKeySet
                    <*> genKeySet
                )
            $ \(chains, n1, n2) -> ioProperty $ withDb $ \path -> do
                let (fresh, racers) = case chains of
                        c : cs -> (c, cs)
                        [] -> error "no chains"
                    target = case racers of
                        c : _ -> c
                        [] -> error "no racers"
                    competing =
                        [fst (rotateChain k target) | k <- [n1, n2]]
                (rsKels, rsDup, rsRot, mem) <-
                    withOpened path $ \Opened{opKels} -> do
                        -- distinct prefixes, each KEL in order, in parallel
                        rsKels <-
                            mapConcurrently (submitAll opKels . chEvents) racers
                        -- one inception, eight times at once
                        rsDup <-
                            mapConcurrently
                                (submitMemberEvent opKels)
                                (replicate 8 (firstEvent fresh))
                        -- two rotations of one tip, four times each, at once
                        rsRot <-
                            mapConcurrently
                                (submitMemberEvent opKels)
                                (concat (replicate 4 competing))
                        mem <- mapM (lookupMemberKel opKels . chPrefix) chains
                        pure (rsKels, rsDup, rsRot, mem)
                reopened <- withOpened path $ \Opened{opKels} ->
                    mapM (lookupMemberKel opKels . chPrefix) chains
                let landed = [kel | Right kel <- rsRot]
                    expected =
                        Just [firstEvent fresh]
                            : [ Just (chEvents c <> extra)
                              | c <- racers
                              , let extra =
                                        [ se
                                        | c `samePrefix` target
                                        , kel <- take 1 landed
                                        , se <- drop (length (chEvents c)) (kelEvents kel)
                                        ]
                              ]
                pure $
                    conjoin
                        [ counterexample "a distinct-prefix KEL lost an event" $
                            not (any (any isRefusal) rsKels)
                        , length [() | Right _ <- rsDup] === 1
                        , [r | r@(Left _) <- rsDup]
                            === replicate 7 (Left AlreadyHosted)
                        , length landed === 1
                        , [r | r@(Left _) <- rsRot]
                            === replicate 7 (Left NotTipSuccessor)
                        , map (fmap kelEvents) mem === expected
                        , reopened === mem
                        ]

        it
            "INV-38-ATOMIC: an append interrupted during its INSERT is \
            \either visible in memory and on disk, or in neither"
            $ withDb
            $ \path -> do
                table <- memberTable path
                ch <- generate genRotChain
                withOpened path $ \Opened{opConn, opKels} -> do
                    let conn = opConn
                        icp = firstEvent ch
                    -- an INSERT that takes long enough to be interrupted
                    execute_ conn $
                        Query $
                            "CREATE TRIGGER slow AFTER INSERT ON \""
                                <> table
                                <> "\" BEGIN SELECT count(*) FROM (WITH RECURSIVE \
                                   \c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c \
                                   \WHERE x < 3000000) SELECT x FROM c); END"
                    started <- newEmptyMVar
                    done <- newEmptyMVar
                    submitter <-
                        forkIO $
                            ( putMVar started ()
                                >> submitMemberEvent opKels icp
                                >>= putMVar done . Right . isRefusal
                            )
                                `catch` \(e :: SomeException) ->
                                    putMVar done (Left (show e))
                    takeMVar started
                    threadDelay 200000
                    pending <- isEmptyMVar done
                    killThread submitter
                    outcome <- takeMVar done
                    execute_ conn "DROP TRIGGER slow"
                    mem <- lookupMemberKel opKels (chPrefix ch)
                    [Only rows] <-
                        query_ conn $
                            Query ("SELECT count(*) FROM \"" <> table <> "\"")
                    resend <-
                        try (submitMemberEvent opKels icp)
                            :: IO (Either SomeException (Either KelRefusal MemberKel))
                    -- the kill landed while the INSERT was running
                    pending `shouldBe` True
                    either (const True) (const False) outcome `shouldBe` True
                    -- memory agrees with the database
                    (fmap kelEvents mem, rows :: Int)
                        `shouldSatisfy` (`elem` [(Nothing, 0), (Just [icp], 1)])
                    -- a resend is decided, never an exception
                    either (const True) (const False) resend `shouldBe` False

        it
            "INV-38-ATOMIC: an append whose INSERT fails leaves memory \
            \unchanged and can be retried"
            $ withDb
            $ \path -> do
                table <- memberTable path
                ch <- generate genRotChain
                withOpened path $ \Opened{opConn, opKels} -> do
                    let conn = opConn
                        icp = firstEvent ch
                    execute_ conn $
                        Query $
                            "CREATE TRIGGER injected BEFORE INSERT ON \""
                                <> table
                                <> "\" BEGIN SELECT RAISE(ABORT, 'injected'); END"
                    r <-
                        try (submitMemberEvent opKels icp)
                            :: IO (Either SomeException (Either KelRefusal MemberKel))
                    m <- lookupMemberKel opKels (chPrefix ch)
                    execute_ conn "DROP TRIGGER injected"
                    r2 <- submitMemberEvent opKels icp
                    m2 <- lookupMemberKel opKels (chPrefix ch)
                    isRefusal r `shouldBe` True
                    m `shouldBe` Nothing
                    fmap kelEvents r2 `shouldBe` Right [icp]
                    fmap kelEvents m2 `shouldBe` Just [icp]

        prop
            "INV-38-LOAD: reopening refuses a database holding a KEL that \
            \breaks the KERI rule"
            $ forAll ((,,) <$> genRotChain <*> genKeySet <*> genKeySet)
            $ \(ch0, n1, n2) -> ioProperty $ withDb $ \path -> do
                let (rotSe, ch) = rotateChain n1 ch0
                    lastSn = chSn ch
                    forged = signAll (ksPairs (chCurrent ch0)) (event rotSe)
                    otherRot = event . fst $ rotateChain n2 ch0
                    changedRot =
                        mapRotation
                            ( \RotationData{..} ->
                                RotationData{config = ["x"], ..}
                            )
                            (event rotSe)
                    -- breaks only the reveal: right p, s, SAID, own signatures
                    unrevealed =
                        signAll (ksPairs n2) $
                            rotationOf
                                (chPrefix ch0)
                                (chSn ch0 + 1)
                                (chTip ch0)
                                n2
                                n1
                    onlyReveal =
                        ( replayKel (firstEvent ch0) (drop 1 (chEvents ch0))
                            >>= (`rotate` unrevealed)
                        )
                            === Left CommitmentNotRevealed
                table <- memberTable path
                landed <- withOpened path $ \Opened{opKels} ->
                    submitAll opKels (chEvents ch)
                reopened <- withOpened path $ \Opened{opKels} ->
                    lookupMemberKel opKels (chPrefix ch)
                let update rest =
                        Query ("UPDATE \"" <> table <> "\" " <> rest)
                    corruptions :: [(String, Connection -> IO ())]
                    corruptions =
                        [
                            ( "rotation signed by the superseded keys"
                            , \c ->
                                execute
                                    c
                                    (update "SET signatures = ? WHERE sn = ?")
                                    (sigsText (signatures forged), lastSn)
                            )
                        ,
                            ( "event bytes changed after signing"
                            , \c ->
                                execute
                                    c
                                    (update "SET event_bytes = ? WHERE sn = ?")
                                    ( TE.decodeUtf8 (serializeEvent changedRot)
                                    , lastSn
                                    )
                            )
                        ,
                            ( "another rotation under this row's signatures"
                            , \c ->
                                execute
                                    c
                                    (update "SET event_bytes = ? WHERE sn = ?")
                                    ( TE.decodeUtf8 (serializeEvent otherRot)
                                    , lastSn
                                    )
                            )
                        ,
                            ( "inception row deleted"
                            , \c ->
                                execute_ c $
                                    Query
                                        ( "DELETE FROM \""
                                            <> table
                                            <> "\" WHERE sn = 0"
                                        )
                            )
                        ,
                            ( "the same event in non-canonical bytes"
                            , \c ->
                                execute
                                    c
                                    (update "SET event_bytes = ? WHERE sn = ?")
                                    ( "{ "
                                        <> T.drop 1 (TE.decodeUtf8 (serializeEvent (event rotSe)))
                                    , lastSn
                                    )
                            )
                        ,
                            ( "digest column not the event's digest"
                            , \c ->
                                execute
                                    c
                                    (update "SET digest = ? WHERE sn = ?")
                                    (chPrefix ch0, lastSn)
                            )
                        ,
                            ( "a rotation not revealing the commitment, otherwise valid"
                            , \c ->
                                execute
                                    c
                                    ( update
                                        "SET event_bytes = ?, signatures = ?, \
                                        \digest = ? WHERE sn = ?"
                                    )
                                    ( TE.decodeUtf8 (serializeEvent (event unrevealed))
                                    , sigsText (signatures unrevealed)
                                    , eventDigest (event unrevealed)
                                    , lastSn
                                    )
                            )
                        ]
                refusals <- forM corruptions $ \(label, corrupt) ->
                    withDb $ \copy -> do
                        copyFile path copy
                        withConnection copy corrupt
                        r <-
                            try (withKels copy (const (pure ())))
                                :: IO (Either SomeException ())
                        pure $
                            counterexample label $
                                property (isRefusal r)
                pure $
                    conjoin $
                        [ counterexample "setup refused" $
                            not (any isRefusal landed)
                        , fmap kelEvents reopened === Just (chEvents ch)
                        , counterexample "corruption breaks more than the reveal" onlyReveal
                        ]
                            <> refusals

        it
            "INV-40-SCHEMA/store: a freshly opened database holds only the \
            \member KEL table and no row; a file that also holds the old \
            \path's tables opens and leaves them untouched"
            $ withDb
            $ \path -> do
                fresh <- withKels path $ \_ -> withConnection path dumpTables
                fresh `shouldBe` [("member_kel_events", [])]
                withDb $ \old -> do
                    withConnection old oldPathTables
                    before <- withConnection old dumpTables
                    opened <- withKels old $ \_ -> withConnection old dumpTables
                    after <- withConnection old dumpTables
                    filter ((/= "member_kel_events") . fst) opened `shouldBe` before
                    after `shouldBe` opened
                    map fst after `shouldSatisfy` ("member_kel_events" `elem`)

{- | The tables of the removed group path, with one row each, as its
store created them.
-}
oldPathTables :: Connection -> IO ()
oldPathTables c = do
    execute_
        c
        "CREATE TABLE events \
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
        c
        "CREATE TABLE founding \
        \( id INTEGER PRIMARY KEY CHECK (id = 1) \
        \, founding_json TEXT NOT NULL \
        \)"
    execute_
        c
        "INSERT INTO events \
        \(signer, event_bytes, signature, group_event, prefix, seq_no, digest) \
        \VALUES ('s', '{}', 'sig', '{}', 'p', 0, 'd')"
    execute_ c "INSERT INTO founding (id, founding_json) VALUES (1, '{}')"

samePrefix :: Chain -> Chain -> Bool
samePrefix a b = chPrefix a == chPrefix b
