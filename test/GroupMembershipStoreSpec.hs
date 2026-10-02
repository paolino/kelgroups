{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : GroupMembershipStoreSpec
Description : Membership actions against the SQLite store
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

Membership histories built by legitimate signing ("GroupWorld")
submitted to 'KelGroups.Kel.Store' on a real SQLite file, then
reopened: removed members' actions survive the reopen, every
payload replays to the same chains and rosters, and a stored
interaction that breaks the membership rule at its position
refuses the open.
-}
module GroupMembershipStoreSpec (spec) where

import Control.Exception (SomeException, try)
import Control.Monad (forM, forM_)
import Data.Text (Text)
import Database.SQLite.Simple (withConnection)
import GroupFixtures (genAppData)
import GroupStoreSpec (insertRow, memberTable, withKels)
import GroupWorld
    ( Intent (..)
    , Team (..)
    , World (..)
    , act
    , attempt
    , chainOf
    , eventsOf
    , found
    , genTeam
    , rosterOf
    , sets
    , sign
    )
import KelGroups.Group (GroupRefusal (..), chainActions, roster)
import KelGroups.Group qualified as Group
import KelGroups.Kel (appendInteraction, kelEvents, replayKel)
import KelGroups.Kel.Store
    ( MemberKels
    , admitAction
    , lookupChain
    , lookupMemberKel
    , submitMemberEvent
    )
import Keri.Event (Event (..))
import Keri.Kel (SignedEvent (..))
import MemberKelStoreSpec (dumpTables, withDb)
import System.Directory (copyFile)
import Test.Hspec (Spec, describe)
import Test.Hspec.QuickCheck (modifyMaxSuccess, prop)
import Test.QuickCheck
    ( conjoin
    , counterexample
    , forAll
    , ioProperty
    , property
    , (===)
    )

-- | Submit a world's log in order; a refusal fails the setup.
replay :: MemberKels -> World -> IO ()
replay kels w = forM_ (wLog w) $ \se -> case event se of
    Interaction{} ->
        admitAction kels se >>= either (setup se) (const (pure ()))
    _ -> submitMemberEvent kels se >>= either (setup se) (const (pure ()))
  where
    setup se r = fail ("setup refused " <> show (event se) <> ": " <> show r)

-- | Signed events of a group chain in the store.
storedChain :: MemberKels -> Text -> IO (Maybe [SignedEvent])
storedChain kels g = fmap (map Group.signed . chainActions) <$> lookupChain kels g

-- | Signed events of a group chain in a world.
worldChain :: Text -> World -> Maybe [SignedEvent]
worldChain g w = map Group.signed . chainActions <$> chainOf g w

-- | Whether a KEL fixture accepts this interaction by the KERI rule.
keriValid :: [SignedEvent] -> SignedEvent -> Bool
keriValid kel se = case kel of
    e : es ->
        either
            (const False)
            (const True)
            (replayKel e es >>= (`appendInteraction` se))
    [] -> False

opens :: FilePath -> IO (Either SomeException ())
opens path = try (withKels path $ \_ _ -> pure ())

spec :: Spec
spec = describe "KelGroups.Kel.Store (membership actions)" $
    modifyMaxSuccess (const 5) $ do
        prop
            "INV-40-REMOVED/store: after x is removed its earlier actions stay \
            \in the stored chain and reopen rebuilds the identical chain and \
            \roster; x's new action is refused notAMember, nothing stored"
            $ forAll ((,,) <$> genTeam <*> genAppData <*> genAppData)
            $ \(Team{..}, d1, d2) -> ioProperty $ withDb $ \path -> do
                let earlier = sign tGroup tB (IApp d1) tWorld
                    w1 = act tGroup tB (IApp d1) tWorld
                    w2 = act tGroup tA (IRemove tB) w1
                    late = sign tGroup tB (IApp d2) w2
                (mem, r, dump0, dump1, kelB) <- withKels path $ \c kels -> do
                    replay kels w2
                    mem <- storedChain kels tGroup
                    dump0 <- dumpTables c
                    r <- admitAction kels late
                    dump1 <- dumpTables c
                    kelB <- fmap kelEvents <$> lookupMemberKel kels tB
                    pure (mem, r, dump0, dump1, kelB)
                (reopened, rosterRe) <- withKels path $ \_ kels ->
                    (,)
                        <$> storedChain kels tGroup
                        <*> (fmap (sets . roster) <$> lookupChain kels tGroup)
                pure $
                    conjoin
                        [ mem === worldChain tGroup w2
                        , counterexample "earlier action dropped" $
                            property (maybe False (earlier `elem`) mem)
                        , reopened === mem
                        , rosterRe === rosterOf tGroup w2
                        , (() <$ r) === Left NotAMember
                        , dump1 === dump0
                        , kelB === Just (eventsOf tB w2)
                        ]

        prop
            "INV-40-LOAD/store: a database whose history uses every payload \
            \reopens to identical chains and rosters"
            $ forAll ((,) <$> genTeam <*> genAppData)
            $ \(Team{..}, d) -> ioProperty $ withDb $ \path -> do
                let w1 =
                        foldl
                            (\w (s, i) -> act tGroup s i w)
                            tWorld
                            [ (tA, IRevoke tE)
                            , (tE, ILeave)
                            , (tB, ILeave)
                            , (tA, IRemove tD)
                            , (tA, IAdd tC)
                            , (tA, IGrant tC)
                            , (tC, IApp d)
                            ]
                    (g2, w2) = found tC w1
                    w3 = act g2 tC (IAdd tB) (act g2 tC (IAdd tE) w2)
                    groups = [tGroup, g2]
                    observe kels =
                        forM groups $ \g ->
                            (,)
                                <$> storedChain kels g
                                <*> (fmap (sets . roster) <$> lookupChain kels g)
                mem <- withKels path $ \_ kels -> replay kels w3 >> observe kels
                reopened <- withKels path $ \_ kels -> observe kels
                pure $
                    conjoin
                        [ mem
                            === [(worldChain g w3, rosterOf g w3) | g <- groups]
                        , reopened === mem
                        ]

        prop
            "INV-40-LOAD/store: reopening refuses a database holding a \
            \KERI-valid interaction that breaks the membership rule at its \
            \position: a non-admin's add, the last admin's revoke of itself"
            $ forAll genTeam
            $ \Team{..} -> ioProperty $ do
                let lone = act tGroup tA (IRevoke tE) tWorld
                    nonAdminAdd = sign tGroup tB (IAdd tC) tWorld
                    lastRevoke = sign tGroup tA (IRevoke tA) lone
                    cases =
                        [ ("non-admin add", tWorld, nonAdminAdd, tB, NotAnAdmin)
                        , ("last-admin revoke", lone, lastRevoke, tA, LastAdmin)
                        ]
                results <- forM cases $ \(label, w, se, s, why) ->
                    withDb $ \path -> do
                        table <- withKels path $ \c kels -> replay kels w >> memberTable c
                        control <- withDb $ \copy -> copyFile path copy >> opens copy
                        withConnection path $ \c -> insertRow c table se
                        r <- opens path
                        pure $
                            counterexample label $
                                conjoin
                                    [ counterexample "not KERI-valid" $
                                        keriValid (eventsOf s w) se
                                    , counterexample "breaks another condition" $
                                        (() <$ attempt se w) === Left why
                                    , counterexample ("control: " <> show control) $
                                        either (const False) (const True) control
                                    , counterexample "opened" $
                                        either (const True) (const False) r
                                    ]
                pure (conjoin results)
