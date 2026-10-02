{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : GroupStoreSpec
Description : Group action admission against the SQLite store
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

Checks of 'KelGroups.Kel.Store.admitAction' on a real SQLite
file: concurrency, retry, atomicity under write failures and
asynchronous exceptions, frame, stale actions after a rotation
and the chain rebuild on open.
-}
module GroupStoreSpec
    ( spec
    , withKels
    , insertRow
    , memberTable
    ) where

import Control.Concurrent (forkFinally, killThread, threadDelay)
import Control.Concurrent.Async (concurrently, mapConcurrently)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, try)
import Control.Monad (forM, forM_, unless)
import Data.Aeson (Value, object, (.=))
import Data.Aeson.Encoding (encodingToLazyByteString)
import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as LBS
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Database.SQLite.Simple
    ( Connection
    , Query (..)
    , execute
    , execute_
    , withConnection
    )
import GHC.Clock (getMonotonicTime)
import GroupFixtures
    ( actWith
    , appOf
    , genAppData
    , genMember
    , genMultiKeyMember
    , genNumericData
    , genesisOf
    , respellNumbers
    )
import GroupSpec (Scene (..), genScene)
import KelGroups.Group
    ( Admission (..)
    , GroupRefusal (..)
    , chainActions
    )
import KelGroups.Group qualified as Group
import KelGroups.Kel
    ( KelRefusal (..)
    , appendInteraction
    , kelEvents
    , replayKel
    )
import KelGroups.Kel qualified as Kel
import KelGroups.Kel.Codec (encodeSignatures)
import KelGroups.Kel.Store
    ( MemberKels
    , admitAction
    , lookupChain
    , lookupMemberKel
    , submitMemberEvent
    )
import Keri.Event
    ( InteractionData (..)
    , eventDigest
    , eventPrefix
    , eventSequenceNumber
    )
import Keri.Event.Serialize (serializeEvent)
import Keri.Kel (SignedEvent (..))
import MemberKelFixtures
    ( Chain (..)
    , KeySet (..)
    , genKeySet
    , mapInteraction
    , rotateChain
    )
import MemberKelStoreSpec (dumpTables, tableNames, withDb)
import MemberKelStoreSpec qualified as MKS
import System.Directory (copyFile)
import Test.Hspec (Spec, describe)
import Test.Hspec.QuickCheck (modifyMaxSuccess, prop)
import Test.QuickCheck
    ( Property
    , chooseInt
    , conjoin
    , counterexample
    , forAll
    , generate
    , ioProperty
    , property
    , (===)
    )

-- | The member KELs of a database file, open for the action.
withKels :: FilePath -> (Connection -> MemberKels -> IO a) -> IO a
withKels path act =
    MKS.withKels path $ \kels -> withConnection path $ \c -> act c kels

-- | Host member KELs; a refusal fails the setup.
hostAll :: MemberKels -> [SignedEvent] -> IO ()
hostAll kels ses = forM_ ses $ \se -> do
    r <- submitMemberEvent kels se
    either (fail . ("setup refused: " <>) . show) (const (pure ())) r

-- | Admit an action; a refusal fails the setup.
admitOk :: MemberKels -> SignedEvent -> IO Admission
admitOk kels se =
    admitAction kels se
        >>= either (fail . ("setup refused: " <>) . show) pure

digestOf :: SignedEvent -> Text
digestOf = eventDigest . event

tipOf :: MemberKels -> Text -> IO (Maybe Text)
tipOf kels pfx = fmap Kel.tip <$> lookupMemberKel kels pfx

headOf :: MemberKels -> Text -> IO (Maybe Text)
headOf kels g = fmap Group.head <$> lookupChain kels g

-- | The signed events of a group's chain, genesis first.
chainOf :: MemberKels -> Text -> IO (Maybe [SignedEvent])
chainOf kels g = fmap (map Group.signed . chainActions) <$> lookupChain kels g

-- | The single table a fresh database gets from 'openMemberKels'.
memberTable :: Connection -> IO Text
memberTable c =
    tableNames c >>= \case
        [t] -> pure t
        ts -> fail ("expected one table, got " <> show ts)

-- | Store a signed event as a row, bypassing admission.
insertRow :: Connection -> Text -> SignedEvent -> IO ()
insertRow c table SignedEvent{event, signatures} =
    execute
        c
        ( Query $
            "INSERT INTO \""
                <> table
                <> "\" (prefix, sn, event_bytes, signatures, digest) \
                   \VALUES (?, ?, ?, ?, ?)"
        )
        ( eventPrefix event
        , eventSequenceNumber event
        , TE.decodeUtf8 (serializeEvent event)
        , TE.decodeUtf8
            . LBS.toStrict
            . encodingToLazyByteString
            $ encodeSignatures signatures
        , eventDigest event
        )

-- | Host the scene's members and admit its setup actions.
stage :: MemberKels -> Scene -> IO ()
stage kels Scene{..} = do
    hostAll kels (concatMap chEvents scStart)
    mapM_ (admitOk kels) scSetup

-- | Every event digest of these KELs: every candidate group id.
candidates :: [Chain] -> [Text]
candidates = map digestOf . concatMap chEvents

isRight' :: Either a b -> Bool
isRight' = either (const False) (const True)

spec :: Spec
spec = describe "KelGroups.Kel.Store (group action admission)" $ do
    modifyMaxSuccess (const 3)
        $ prop
            "INV-39-CONTEND/store: two actions signed against one head, \
            \submitted concurrently, 20 rounds: exactly one admitted and \
            \one refused stale each round; the refused one, re-signed \
            \against the new tip and head, is admitted"
        $ forAll genMember
        $ \a0 -> ioProperty $ withDb $ \path -> withKels path $ \_ kels -> do
            hostAll kels (chEvents a0)
            let (g, a1) = genesisOf a0
                gid = digestOf g
            _ <- admitOk kels g
            let round'
                    :: Int
                    -> (Text, Chain, [SignedEvent])
                    -> IO ([Property], Chain, [SignedEvent])
                round' i (h, ch, acc)
                    | i > 20 = pure ([], ch, acc)
                    | otherwise = do
                        let dataOf :: Int -> Value
                            dataOf side = object ["round" .= i, "side" .= side]
                            racers = [appOf gid h (dataOf side) ch | side <- [0, 1]]
                        rs <- mapConcurrently (admitAction kels . fst) racers
                        case [(side, r) | (side, Left r) <- zip [0 :: Int ..] rs] of
                            [(loser, r)]
                                | [(wse, wch)] <- [x | (side, x) <- zip [0 ..] racers, side /= loser] -> do
                                    let (z, zch) = appOf gid (digestOf wse) (dataOf loser) wch
                                    rz <- admitAction kels z
                                    (ps, chEnd, accEnd) <-
                                        round' (i + 1) (digestOf z, zch, acc <> [wse, z])
                                    pure
                                        ( counterexample ("round " <> show i) (r === KelRefused NotTipSuccessor)
                                            : counterexample
                                                ("round " <> show i <> " re-signed")
                                                (property (isRight' rz))
                                            : ps
                                        , chEnd
                                        , accEnd
                                        )
                            other ->
                                pure
                                    (
                                        [ counterexample ("round " <> show i <> ": " <> show (rs, other)) False
                                        ]
                                    , ch
                                    , acc
                                    )
            (ps, chEnd, admittedSeq) <- round' 1 (gid, a1, [])
            kel <- lookupMemberKel kels (chPrefix a0)
            chain <- chainOf kels gid
            pure $
                conjoin $
                    ps
                        <> [ fmap kelEvents kel === Just (chEvents chEnd)
                           , chain === Just (g : admittedSeq)
                           ]

    modifyMaxSuccess (const 10) $ do
        prop
            "INV-39-RETRY/store: identical bytes resubmitted after \
            \admission, immediately and after later actions, return the \
            \same admission and store nothing; a different signature set \
            \is not a retry and is refused"
            $ forAll ((,,) <$> genMultiKeyMember <*> genAppData <*> genAppData)
            $ \(a0, d1, d2) -> ioProperty $ withDb $ \path ->
                withKels path $ \c kels -> do
                    hostAll kels (chEvents a0)
                    let (g, a1) = genesisOf a0
                        gid = digestOf g
                        (x, a2) = appOf gid gid d1 a1
                        (y, _) = appOf gid (digestOf x) d2 a2
                        KeySet{ksThreshold} = chCurrent a1
                        otherSet = x{signatures = take ksThreshold (signatures x)}
                    rg <- admitAction kels g
                    rx <- admitAction kels x
                    dump0 <- dumpTables c
                    rx1 <- admitAction kels x
                    alt1 <- admitAction kels otherSet
                    dump1 <- dumpTables c
                    ry <- admitAction kels y
                    rx2 <- admitAction kels x
                    rg2 <- admitAction kels g
                    alt2 <- admitAction kels otherSet
                    dump2 <- dumpTables c
                    ry2 <- admitAction kels y
                    dump3 <- dumpTables c
                    kel <- lookupMemberKel kels (chPrefix a0)
                    let expected se =
                            Right
                                Admission
                                    { admittedGroup = gid
                                    , admittedHead = digestOf se
                                    , admittedPrefix = chPrefix a0
                                    , admittedSn = eventSequenceNumber (event se)
                                    }
                    pure $
                        conjoin
                            [ counterexample "signature sets coincide" $
                                signatures otherSet /= signatures x
                            , rg === expected g
                            , rx === expected x
                            , rx1 === rx
                            , rx2 === rx
                            , rg2 === rg
                            , ry === expected y
                            , ry2 === ry
                            , alt1 === Left (KelRefused NotTipSuccessor)
                            , alt2 === Left (KelRefused NotTipSuccessor)
                            , dump1 === dump0
                            , dump3 === dump2
                            , fmap (length . filter (== x) . kelEvents) kel === Just 1
                            ]

        prop
            "INV-39-RETRY/store: an admitted action resubmitted with its \
            \numbers spelled otherwise (an equal value in other bytes, same \
            \d and signatures) is no retry: the admission rule refuses it \
            \and nothing is stored"
            $ forAll ((,,) <$> genMember <*> genNumericData <*> chooseInt (1, 3))
            $ \(a0, d, k) -> ioProperty $ withDb $ \path ->
                withKels path $ \c kels -> do
                    hostAll kels (chEvents a0)
                    let (g, a1) = genesisOf a0
                        gid = digestOf g
                        (x, _) = appOf gid gid d a1
                        x' = respelled k x
                    _ <- admitOk kels g
                    rx <- admitAction kels x
                    dump0 <- dumpTables c
                    rx' <- admitAction kels x'
                    dump1 <- dumpTables c
                    pure $
                        conjoin
                            [ counterexample "respelled is not an equal value" $
                                x' === x
                            , counterexample "respelled has the same bytes" $
                                serializeEvent (event x') /= serializeEvent (event x)
                            , counterexample "setup refused" $ isRight' rx
                            , rx' === Left (KelRefused SaidMismatch)
                            , dump1 === dump0
                            ]

        prop
            "INV-39-ATOMIC/store: an admission whose INSERT fails advances \
            \neither the KEL tip nor the group head, in memory or after \
            \reopen; retried, it is admitted and survives reopen"
            $ forAll ((,) <$> genScene <*> genAppData)
            $ \(sc@Scene{..}, d) -> ioProperty $ withDb $ \path -> do
                let (x, _) = appOf scGroup scHead d scMember
                    (gb, _) = genesisOf scOther
                    observe kels =
                        (,,,)
                            <$> tipOf kels (chPrefix scMember)
                            <*> headOf kels scGroup
                            <*> tipOf kels (chPrefix scOther)
                            <*> headOf kels (digestOf gb)
                    before =
                        (Just (chTip scMember), Just scHead, Just (chTip scOther), Nothing)
                    after =
                        ( Just (digestOf x)
                        , Just (digestOf x)
                        , Just (digestOf gb)
                        , Just (digestOf gb)
                        )
                (failed, mem0, mem1) <- withKels path $ \c kels -> do
                    stage kels sc
                    table <- memberTable c
                    execute_ c $
                        Query $
                            "CREATE TRIGGER injected BEFORE INSERT ON \""
                                <> table
                                <> "\" BEGIN SELECT RAISE(ABORT, 'injected'); END"
                    rs <-
                        forM [x, gb] $ \se ->
                            try (admitAction kels se)
                                :: IO (Either SomeException (Either GroupRefusal Admission))
                    mem0 <- observe kels
                    execute_ c "DROP TRIGGER injected"
                    -- the reopen below sees the database as the failure left it
                    reopened0 <- withKels path $ \_ k -> observe k
                    retriedRs <- mapM (admitAction kels) [x, gb]
                    mem1 <- observe kels
                    pure
                        ( conjoin
                            [ counterexample ("write failure not raised: " <> show rs) $
                                not (any isRight' rs)
                            , reopened0 === mem0
                            , counterexample "retry refused" $ all isRight' retriedRs
                            ]
                        , mem0
                        , mem1
                        )
                reopened1 <- withKels path $ \_ k -> observe k
                pure $
                    conjoin
                        [ failed
                        , mem0 === before
                        , mem1 === after
                        , reopened1 === mem1
                        ]

    modifyMaxSuccess (const 1)
        $ prop
            "INV-39-ATOMIC/store: an asynchronous exception at varying \
            \points of an admission leaves the KEL tip and the group head \
            \both advanced or both unchanged, in memory and after reopen"
        $ forAll genMember
        $ \a0 -> ioProperty $ withDb $ \path ->
            withKels path $ \c kels -> do
                hostAll kels (chEvents a0)
                let (g, a1) = genesisOf a0
                    gid = digestOf g
                    pfx = chPrefix a0
                _ <- admitOk kels g
                table <- memberTable c
                -- an INSERT slow enough to be interrupted inside
                execute_ c $
                    Query $
                        "CREATE TRIGGER slow AFTER INSERT ON \""
                            <> table
                            <> "\" BEGIN SELECT count(*) FROM (WITH RECURSIVE \
                               \c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c \
                               \WHERE x < 1000000) SELECT x FROM c); END"
                let (m, a2) = appOf gid gid (object ["measure" .= True]) a1
                t0 <- getMonotonicTime
                _ <- admitOk kels m
                t1 <- getMonotonicTime
                let rounds = 24 :: Int
                    span' = 2 * (t1 - t0)
                    delayOf k = round (span' * 1e6 * fromIntegral k / fromIntegral rounds) :: Int
                    go k (h, ch)
                        | k >= rounds = pure []
                        | otherwise = do
                            let (x, xch) = appOf gid h (object ["round" .= k]) ch
                            done <- newEmptyMVar
                            -- the handler is installed masked: a kill at any point fills done
                            tid <- forkFinally (admitAction kels x) (putMVar done . first show)
                            unless (delayOf k == 0) $ threadDelay (delayOf k)
                            killThread tid
                            outcome <- takeMVar done
                            tipM <- tipOf kels pfx
                            headM <- headOf kels gid
                            reopened <- withKels path $ \_ k' ->
                                (,) <$> tipOf k' pfx <*> headOf k' gid
                            let tipAdv = tipM == Just (digestOf x)
                                headAdv = headM == Just (digestOf x)
                                unchanged = (tipM, headM) == (Just (chTip ch), Just h)
                                verdict =
                                    counterexample
                                        ( "round "
                                            <> show k
                                            <> " delay "
                                            <> show (delayOf k)
                                            <> ": "
                                            <> show (outcome, tipM, headM, reopened)
                                        )
                                        $ conjoin
                                            [ property (tipAdv == headAdv)
                                            , property (tipAdv || unchanged)
                                            , reopened === (tipM, headM)
                                            , case outcome of
                                                Right r -> property (isRight' r && tipAdv)
                                                Left _ -> property True
                                            ]
                            rest <-
                                go (k + 1) $
                                    if tipAdv then (digestOf x, xch) else (h, ch)
                            pure ((tipAdv, verdict) : rest)
                outcomes <- go 0 (digestOf m, a2)
                execute_ c "DROP TRIGGER slow"
                let advanced = length (filter fst outcomes)
                pure $
                    conjoin $
                        counterexample
                            ( "interruptions did not vary: "
                                <> show advanced
                                <> " of "
                                <> show rounds
                                <> " advanced"
                            )
                            (property (advanced > 0 && advanced < rounds))
                            : map snd outcomes

    modifyMaxSuccess (const 10) $ do
        prop
            "INV-39-FRAME: an admission changes only the signer's KEL and \
            \its group's chain; a rotation changes no chain"
            $ forAll
                ((,,,) <$> genMember <*> genMember <*> genAppData <*> genKeySet)
            $ \(a0, b0, d, n1) -> ioProperty $ withDb $ \path ->
                withKels path $ \c kels -> do
                    hostAll kels (chEvents a0 <> chEvents b0)
                    let (g1, a1) = genesisOf a0
                        (g2, a2) = genesisOf a1
                        (g3, b1) = genesisOf b0
                    mapM_ (admitOk kels) [g1, g2, g3]
                    let (x, a3) = appOf (digestOf g1) (digestOf g1) d a2
                        (rot, b2) = rotateChain n1 b1
                        ids = candidates [a3, b2]
                        snapshot =
                            (,)
                                <$> mapM
                                    (fmap (fmap kelEvents) . lookupMemberKel kels)
                                    [chPrefix a0, chPrefix b0]
                                <*> mapM (chainOf kels) ids
                    (kels0, chains0) <- snapshot
                    dump0 <- dumpTables c
                    rx <- admitAction kels x
                    (kels1, chains1) <- snapshot
                    dump1 <- dumpTables c
                    rr <- submitMemberEvent kels rot
                    (kels2, chains2) <- snapshot
                    let expectChains1 =
                            [ if i == digestOf g1 then fmap (<> [x]) ch else ch
                            | (i, ch) <- zip ids chains0
                            ]
                        appended =
                            [ (n, length r1 - length r0, take (length r0) r1 == r0)
                            | ((n, r0), (_, r1)) <- zip dump0 dump1
                            ]
                    pure $
                        conjoin
                            [ counterexample "admission refused" $ isRight' rx
                            , counterexample "rotation refused" $ isRight' rr
                            , kels0 === [Just (chEvents a2), Just (chEvents b1)]
                            , kels1 === [Just (chEvents a3), Just (chEvents b1)]
                            , chains1 === expectChains1
                            , counterexample "the setup holds three groups" $
                                length (filter isJust chains0) === 3
                            , appended === [(n, 1, True) | (n, _) <- dump0]
                            , kels2 === [Just (chEvents a3), Just (chEvents b2)]
                            , chains2 === chains1
                            ]

        prop
            "INV-39-FRAME/store: an admission of one member and a rotation \
            \of another, submitted concurrently, 20 rounds: both succeed \
            \and memory equals a fresh reopen"
            $ forAll ((,) <$> genMember <*> genMember)
            $ \(a0, b0) -> ioProperty $ withDb $ \path -> do
                let (g, a1) = genesisOf a0
                    gid = digestOf g
                    observe kels =
                        (,,,)
                            <$> fmap (fmap kelEvents) (lookupMemberKel kels (chPrefix a0))
                            <*> fmap (fmap kelEvents) (lookupMemberKel kels (chPrefix b0))
                            <*> headOf kels gid
                            <*> chainOf kels gid
                    go kels i (hd, a, b, acc)
                        | i > (20 :: Int) = pure ([], (hd, a, b, acc))
                        | otherwise = do
                            nb <- generate genKeySet
                            let (x, a') = appOf gid hd (object ["round" .= i]) a
                                (rot, b') = rotateChain nb b
                            (rx, rr) <-
                                concurrently
                                    (admitAction kels x)
                                    (submitMemberEvent kels rot)
                            (ps, end) <- go kels (i + 1) (digestOf x, a', b', acc <> [x])
                            pure
                                ( counterexample
                                    ("round " <> show i <> ": " <> show (rx, fmap kelEvents rr))
                                    (property (isRight' rx && isRight' rr))
                                    : ps
                                , end
                                )
                (outcomes, (hEnd, aEnd, bEnd, xs), mem) <- withKels path $ \_ kels -> do
                    hostAll kels (chEvents a0 <> chEvents b0)
                    _ <- admitOk kels g
                    (ps, end) <- go kels 1 (gid, a1, b0, [])
                    mem <- observe kels
                    pure (ps, end, mem)
                reopened <- withKels path $ \_ kels -> observe kels
                pure $
                    conjoin $
                        outcomes
                            <> [ mem
                                    === ( Just (chEvents aEnd)
                                        , Just (chEvents bEnd)
                                        , Just hEnd
                                        , Just (g : xs)
                                        )
                               , reopened === mem
                               ]

        prop
            "INV-39-STALE-ROT: an action signed before an admitted rotation \
            \of its signer is refused; re-signed with the new keys and tip \
            \it is admitted"
            $ forAll ((,,) <$> genMember <*> genAppData <*> genKeySet)
            $ \(a0, d, n1) -> ioProperty $ withDb $ \path ->
                withKels path $ \c kels -> do
                    hostAll kels (chEvents a0)
                    let (g, a1) = genesisOf a0
                        gid = digestOf g
                        (stale, _) = appOf gid gid d a1
                        (rot, a2) = rotateChain n1 a1
                        (fresh, a3) = appOf gid gid d a2
                    _ <- admitOk kels g
                    rr <- submitMemberEvent kels rot
                    dump0 <- dumpTables c
                    rs <- admitAction kels stale
                    dump1 <- dumpTables c
                    h1 <- headOf kels gid
                    rf <- admitAction kels fresh
                    kel <- lookupMemberKel kels (chPrefix a0)
                    h2 <- headOf kels gid
                    pure $
                        conjoin
                            [ counterexample "rotation refused" $ isRight' rr
                            , rs === Left (KelRefused NotTipSuccessor)
                            , dump1 === dump0
                            , h1 === Just gid
                            , counterexample "re-signed refused" $ isRight' rf
                            , fmap kelEvents kel === Just (chEvents a3)
                            , h2 === Just (digestOf fresh)
                            ]

        prop
            "INV-39-LOAD: reopening rebuilds identical KELs, chains and heads"
            $ forAll ((,,) <$> genScene <*> genKeySet <*> genAppData)
            $ \(sc@Scene{..}, n1, d) -> ioProperty $ withDb $ \path -> do
                let (gb, b1) = genesisOf scOther
                    (rot, a1) = rotateChain n1 scMember
                    (x, a2) = appOf scGroup scHead d a1
                    (y, b2) = appOf (digestOf gb) (digestOf gb) d b1
                    ids = candidates [a2, b2]
                    pfxs = [chPrefix scMember, chPrefix scOther]
                    observe kels =
                        (,,)
                            <$> mapM (lookupMemberKel kels) pfxs
                            <*> mapM (lookupChain kels) ids
                            <*> mapM (headOf kels) ids
                mem <- withKels path $ \_ kels -> do
                    stage kels sc
                    _ <- admitOk kels gb
                    hostAll kels [rot]
                    mapM_ (admitOk kels) [x, y]
                    observe kels
                reopened <- withKels path $ \_ kels -> observe kels
                let (_, _, heads) = mem
                pure $
                    conjoin
                        [ reopened === mem
                        , counterexample "the setup holds two groups" $
                            length (filter isJust heads) === 2
                        ]

        prop
            "INV-39-LOAD: reopening refuses a database holding a KERI-valid \
            \interaction with an unresolved prev, two actions with one \
            \prev, a non-member signer, or no group anchor"
            $ forAll ((,,) <$> genScene <*> genAppData <*> genAppData)
            $ \(sc@Scene{..}, d1, d2) -> ioProperty $ withDb $ \path -> do
                let elsewhere = case chEvents scMember of
                        e : _ -> digestOf e
                        [] -> error "empty KEL fixture"
                    (twin1, a1) = appOf scGroup scHead d1 scMember
                    (twin2, _) = appOf scGroup scHead d2 a1
                    corruptions =
                        [ ("unresolved prev", [fst (appOf scGroup elsewhere d1 scMember)])
                        , ("unknown group", [fst (appOf elsewhere scHead d1 scMember)])
                        , ("two actions with one prev", [twin1, twin2])
                        , ("non-member signer", [fst (appOf scGroup scHead d1 scOther)])
                        , ("no group anchor", [fst (actWith [] scMember)])
                        ]
                    kelOf ch = case chEvents ch of
                        e : es -> replayKel e es
                        [] -> error "empty KEL fixture"
                    -- each corruption passes the KERI rule: only R6 is broken
                    keriValid rows = case rows of
                        r : rs
                            | eventPrefix (event r) == chPrefix scOther ->
                                isRight' (kelOf scOther >>= (`appendInteraction` r))
                            | otherwise ->
                                isRight'
                                    ( kelOf scMember >>= \k ->
                                        foldl
                                            (\acc se -> acc >>= (`appendInteraction` se))
                                            (appendInteraction k r)
                                            rs
                                    )
                        [] -> False
                table <- withKels path $ \c kels -> stage kels sc >> memberTable c
                control <-
                    withDb $ \copy -> do
                        copyFile path copy
                        try (withKels copy $ \_ _ -> pure ())
                            :: IO (Either SomeException ())
                results <- forM corruptions $ \(label, rows) ->
                    withDb $ \copy -> do
                        copyFile path copy
                        withConnection copy $ \c -> mapM_ (insertRow c table) rows
                        r <-
                            try (withKels copy $ \_ _ -> pure ())
                                :: IO (Either SomeException ())
                        pure $
                            counterexample label $
                                conjoin
                                    [ counterexample "not KERI-valid" $ keriValid rows
                                    , counterexample "opened" $ not (isRight' r)
                                    ]
                pure $
                    conjoin $
                        counterexample
                            ("control did not open: " <> show control)
                            (isRight' control)
                            : results

-- | The action with every number of its anchors spelled with @k@ more decimals.
respelled :: Int -> SignedEvent -> SignedEvent
respelled k se =
    se
        { event =
            mapInteraction
                ( \InteractionData{..} ->
                    InteractionData{anchors = map (respellNumbers k) anchors, ..}
                )
                (event se)
        }
