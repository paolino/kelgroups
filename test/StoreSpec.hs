{- |
Module      : StoreSpec
Description : SQLite KEL store properties
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

Monadic QuickCheck properties testing the SQLite-backed
KEL store through real disk I/O.
-}
module StoreSpec (spec) where

import Control.Monad (forM_)
import Data.Set qualified as Set
import Data.Text (Text, pack)
import KelGroups.Bootstrap (AuthMode (..), authMode)
import KelGroups.Event
    ( BaseEvent (..)
    , GroupEvent (..)
    , Proposal (..)
    )
import KelGroups.State
    ( adminCount
    , emptyState
    )
import KelGroups.Store
    ( appendEvent
    , closeKEL
    , kelLength
    , openKEL
    , readEventsFrom
    , readState
    )
import KelGroups.Store.Serialise ()
import KelGroups.Trivial
    ( trivialFold
    , trivialInitial
    )
import KelGroups.Types (Role (..))
import System.Directory (removeFile)
import System.IO.Temp (emptySystemTempFile)
import Test.Hspec (Spec, around, describe, it, shouldBe)
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
    ( Gen
    , chooseInt
    , listOf1
    , oneof
    )
import Test.QuickCheck.Monadic (assert, monadicIO, pick, run)

-- --------------------------------------------------------
-- Helpers
-- --------------------------------------------------------

-- | Run an action with a temporary SQLite KEL.
withTempKEL :: (FilePath -> IO a) -> IO a
withTempKEL action = do
    path <- emptySystemTempFile "kelgroups-test-.db"
    result <- action path
    removeFile path
    pure result

arbitraryKey :: Gen Text
arbitraryKey =
    pack . ("key" <>) . show <$> chooseInt (0, 19)

{- | Generate a base event stream that makes sense:
bootstrap proposals first, then normal operations.
-}
arbitraryBaseEvents :: Gen [(Text, GroupEvent ())]
arbitraryBaseEvents = do
    -- Start with a bootstrap introduce (always valid)
    bootstrapKey <- arbitraryKey
    let bootstrapEvt =
            ( "bootstrap"
            , Base $
                Propose $
                    IntroduceMember
                        bootstrapKey
                        (Set.singleton Admin)
            )
    -- Then some more proposals from the introduced admin
    rest <- listOf1 $ do
        key <- arbitraryKey
        evt <-
            oneof
                [ pure $
                    Base $
                        Propose $
                            IntroduceMember
                                key
                                (Set.singleton Admin)
                , pure $
                    Base $
                        Propose $
                            RemoveMember key
                ]
        pure (bootstrapKey, evt)
    pure $ bootstrapEvt : rest

-- --------------------------------------------------------
-- Specs
-- --------------------------------------------------------

spec :: Spec
spec = describe "KelGroups.Store (SQLite)" $ do
    describe "empty KEL" $ do
        it "opening empty DB gives emptyState" $
            withTempKEL $ \path -> do
                store <-
                    openKEL trivialFold trivialInitial path
                gs <- readState store
                len <- kelLength store
                closeKEL store
                gs `shouldBe` emptyState trivialInitial
                len `shouldBe` 0

    describe "roundtrip" $ do
        prop "append then readEventsFrom 1 matches" $
            monadicIO $ do
                events <- pick arbitraryBaseEvents
                (original, replayed) <- run $
                    withTempKEL $ \path -> do
                        store <-
                            openKEL
                                trivialFold
                                trivialInitial
                                path
                        forM_ events $
                            appendEvent
                                store
                                trivialFold
                        replayed <- readEventsFrom store 1
                        closeKEL store
                        pure (events, replayed)
                assert $ original == replayed

    describe "fold consistency" $ do
        prop
            "incremental TVar matches reopened replay"
            $ monadicIO
            $ do
                events <- pick arbitraryBaseEvents
                (stateIncremental, stateReplayed) <- run $
                    withTempKEL $ \path -> do
                        -- Append one by one
                        store <-
                            openKEL
                                trivialFold
                                trivialInitial
                                path
                        forM_ events $
                            appendEvent
                                store
                                trivialFold
                        gs1 <- readState store
                        closeKEL store
                        -- Reopen and let openKEL replay
                        store2 <-
                            openKEL
                                trivialFold
                                trivialInitial
                                path
                        gs2 <- readState store2
                        closeKEL store2
                        pure (gs1, gs2)
                assert $
                    stateIncremental == stateReplayed

    describe "readEventsFrom" $ around withTempKEL $ do
        it "returns tail from index N" $ \path -> do
            store <-
                openKEL trivialFold trivialInitial path
            let events =
                    [
                        ( "signer1"
                        , Base $
                            Propose $
                                IntroduceMember
                                    "k1"
                                    (Set.singleton Admin)
                        )
                    ,
                        ( "k1"
                        , Base $
                            Propose $
                                IntroduceMember
                                    "k2"
                                    (Set.singleton Admin)
                        )
                    ,
                        ( "k1"
                        , Base $
                            Propose $
                                RemoveMember "k2"
                        )
                    ]
            forM_ events $
                appendEvent store trivialFold
            tail' <- readEventsFrom store 2
            closeKEL store
            tail' `shouldBe` drop 1 events

        it "returns empty for index beyond length" $
            \path -> do
                store <-
                    openKEL
                        trivialFold
                        trivialInitial
                        path
                appendEvent store trivialFold $
                    ( "s"
                    , Base $
                        Propose $
                            IntroduceMember
                                "k"
                                (Set.singleton Admin)
                    )
                tail' <- readEventsFrom store 99
                closeKEL store
                tail' `shouldBe` []

    describe "kelLength" $ do
        prop "length matches number of appends" $
            monadicIO $ do
                events <- pick arbitraryBaseEvents
                len <- run $
                    withTempKEL $ \path -> do
                        store <-
                            openKEL
                                trivialFold
                                trivialInitial
                                path
                        forM_ events $
                            appendEvent
                                store
                                trivialFold
                        l <- kelLength store
                        closeKEL store
                        pure l
                assert $ len == length events

    describe "invariant preservation through store" $ do
        it
            "bootstrap event through store exits bootstrap"
            $ withTempKEL
            $ \path -> do
                store <-
                    openKEL
                        trivialFold
                        trivialInitial
                        path
                appendEvent store trivialFold $
                    ( "bootstrap"
                    , Base $
                        Propose $
                            IntroduceMember
                                "admin1"
                                (Set.singleton Admin)
                    )
                gs <- readState store
                closeKEL store
                authMode gs `shouldBe` Normal
                adminCount gs `shouldBe` 1
