{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : GroupIndexServerSpec
Description : GET /groups/<gid> and GET /kel/<prefix>?after=<sn> over real HTTP
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

Drives the two read endpoints through warp and http-client against
the member KEL store on a real SQLite file, after hosting and
admitting legitimately signed events over HTTP. The expected index
is derived from what the scenario submitted and saw admitted
(signers, add targets, last admitted action, every identity's last
event), not from the server's chains; the expected suffixes from
the submitted KEL events.
-}
module GroupIndexServerSpec (spec) where

import Control.Monad (forM, unless)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Encoding (encodingToLazyByteString)
import Data.Foldable (foldl')
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GroupFixtures (genMember)
import GroupWorld
    ( Intent (..)
    , Op (..)
    , Step (..)
    , Team (..)
    , World (..)
    , act
    , genRun
    , genTeam
    )
import KelGroups.Kel.Codec (encodeSignedEvent)
import KelGroups.Server (kelApp)
import Keri.Event (Event (..), eventDigest, eventPrefix)
import Keri.Kel (SignedEvent (..))
import MemberKelFixtures (Chain (..), genKeySet, rotateChain)
import MemberKelServerSpec
    ( Srv (..)
    , fetched
    , postKel
    , refused
    , request
    )
import MemberKelStoreSpec (withDb, withKels)
import Network.HTTP.Client qualified as HC
import Network.Wai.Handler.Warp qualified as Warp
import Test.Hspec (Spec, describe)
import Test.Hspec.QuickCheck (modifyMaxSuccess, prop)
import Test.QuickCheck
    ( Gen
    , Property
    , chooseInt
    , conjoin
    , counterexample
    , forAll
    , ioProperty
    , sublistOf
    , (===)
    )

-- | A running server on a fresh database.
withSrv :: (Srv -> IO a) -> IO a
withSrv run = withDb $ \path -> withKels path $ \kels -> do
    mgr <- HC.newManager HC.defaultManagerSettings
    Warp.testWithApplication
        (pure (kelApp kels Nothing))
        (\port -> run Srv{srvPort = port, srvMgr = mgr})

-- | Submit an event as a client would: KEL events to @/kel@, actions to @/actions@.
submit :: Srv -> SignedEvent -> IO ()
submit srv se = do
    (st, body) <- case event se of
        Interaction{} ->
            request srv "POST" "/actions" $
                Just (encodingToLazyByteString (encodeSignedEvent se))
        _ -> postKel srv se
    unless (st == 200) $ fail ("setup refused: " <> show body)

-- --------------------------------------------------------
-- Scenario and its expected index
-- --------------------------------------------------------

{- | A team, a generated run after it, and rotations of some
identities after the run, every event submitted in order.
-}
data Scenario = Scenario
    { scTeam :: Team
    , scStart :: World
    -- ^ the team after @a@ removed @b@
    , scSteps :: [Step]
    , scRotations :: [SignedEvent]
    , scLog :: [SignedEvent]
    -- ^ everything submitted, in order
    , scFinal :: World
    }

instance Show Scenario where
    show Scenario{..} =
        "Scenario steps="
            <> show (length scSteps)
            <> " rotations="
            <> show (length scRotations)

genScenario :: Gen Scenario
genScenario = do
    team <- genTeam
    let start = act (tGroup team) (tA team) (IRemove (tB team)) (tWorld team)
    n <- chooseInt (0, 12)
    steps <- genRun n start
    let final = maybe start stAfter (lastMaybe steps)
        submitted = Set.fromList (map (eventPrefix . event) (wLog final))
        hostedIds =
            [c | c <- Map.elems (wIds final), Set.member (chPrefix c) submitted]
    rotating <- sublistOf hostedIds
    rots <- forM rotating $ \c -> do
        ks <- genKeySet
        pure (fst (rotateChain ks c))
    pure
        Scenario
            { scTeam = team
            , scStart = start
            , scSteps = steps
            , scRotations = rots
            , scLog = wLog final <> rots
            , scFinal = final
            }

lastMaybe :: [a] -> Maybe a
lastMaybe = foldl' (\_ x -> Just x) Nothing

-- | A group as the scenario sees it: participants and last admitted action.
data Seen = Seen
    { seenPrefixes :: Set Text
    , seenHead :: Text
    }

{- | What each group's index must hold: the team group from its
known composition (founder @a@, adds of @b@, @d@, @e@, app actions
of @b@ and @d@, the removal of @b@ by @a@), then every admitted step: its signer, its add
target, and the event it admitted as the new head.
-}
expectedGroups :: Scenario -> Map Text Seen
expectedGroups Scenario{..} =
    foldl' stepped (Map.singleton tGroup teamSeen) scSteps
  where
    Team{..} = scTeam
    teamSeen =
        Seen
            { seenPrefixes = Set.fromList [tA, tB, tD, tE]
            , seenHead = digestOf (last (wLog scStart))
            }
    stepped acc Step{stOp, stAfter} = case stOp of
        ActOp{opGroup, opSigner, opIntent, opResult = Right ()} ->
            let admitted = digestOf (last (wLog stAfter))
                g = case opIntent of
                    IGenesis -> admitted
                    _ -> opGroup
                targets = case opIntent of
                    IAdd x -> [x]
                    _ -> []
                seen0 =
                    Map.findWithDefault (Seen Set.empty admitted) g acc
            in  Map.insert
                    g
                    Seen
                        { seenPrefixes =
                            Set.union
                                (seenPrefixes seen0)
                                (Set.fromList (opSigner : targets))
                        , seenHead = admitted
                        }
                    acc
        _ -> acc

-- | Every submitted identity's tip: the digest of its last submitted event.
expectedTips :: Scenario -> Map Text Text
expectedTips Scenario{scLog} =
    Map.fromList [(eventPrefix (event se), digestOf se) | se <- scLog]

-- | The D2 body for a group.
indexBody :: Map Text Text -> Seen -> Value
indexBody tips Seen{..} =
    object
        [ "head" .= seenHead
        , "kels"
            .= [ object ["prefix" .= pfx, "tip" .= Map.findWithDefault "" pfx tips]
               | pfx <- Set.toAscList seenPrefixes
               ]
        ]

digestOf :: SignedEvent -> Text
digestOf = eventDigest . event

getPath :: Srv -> String -> IO (Int, Value)
getPath srv path = request srv "GET" path Nothing

-- --------------------------------------------------------
-- Spec
-- --------------------------------------------------------

spec :: Spec
spec = describe "read endpoints" $ do
    describe "INV-41-INDEX/http GET /groups/<gid>" $ modifyMaxSuccess (const 15) $ do
        prop
            "answers the head and every signer and add target with its current tip, former members included"
            indexAnswers
        prop "answers 404 noSuchGroup for an id that is no group" noSuchGroup
    describe "INV-41-AFTER/http GET /kel/<prefix>?after=<sn>" $ modifyMaxSuccess (const 15) $ do
        prop
            "answers exactly the events with s > sn, oldest first; none past the tip"
            afterAnswers
        prop
            "answers the whole KEL without after, other keys ignored"
            wholeAnswers
        prop "answers 400 badQuery for a non-canonical after" badAfter
        prop
            "answers 404 unhosted for a prefix that is not hosted, 400 badQuery first"
            unhostedAfter

indexAnswers :: Property
indexAnswers = forAll genScenario $ \sc -> ioProperty $ withSrv $ \srv -> do
    mapM_ (submit srv) (scLog sc)
    let tips = expectedTips sc
        groups = expectedGroups sc
        formers =
            [ pfx
            | Step{stOp = ActOp{opIntent = i, opResult = Right ()}} <- scSteps sc
            , pfx <- case i of
                IRemove x -> [x]
                _ -> []
            ]
    answers <- forM (Map.toList groups) $ \(g, seen) -> do
        r <- getPath srv ("/groups/" <> T.unpack g)
        pure $
            counterexample ("group " <> T.unpack g) $
                r === (200, indexBody tips seen)
    pure $
        counterexample ("removed members: " <> show formers) $
            conjoin answers

noSuchGroup :: Property
noSuchGroup = forAll genScenario $ \sc -> ioProperty $ withSrv $ \srv -> do
    mapM_ (submit srv) (scLog sc)
    -- a member's inception and a rotation are hosted digests, never a group id
    let notGroups =
            [digestOf se | se@SignedEvent{event = Inception{}} <- scLog sc]
                <> ["Enot-a-digest"]
    rs <- forM notGroups $ \g -> getPath srv ("/groups/" <> T.unpack g)
    pure $ conjoin [refused 404 "noSuchGroup" r | r <- rs]

-- | A scenario's identities with their submitted events, oldest first.
kelsOf :: Scenario -> Map Text [SignedEvent]
kelsOf sc =
    Map.fromListWith
        (flip (<>))
        [(eventPrefix (event se), [se]) | se <- scLog sc]

afterAnswers :: Property
afterAnswers = forAll genScenario $ \sc -> ioProperty $ withSrv $ \srv -> do
    mapM_ (submit srv) (scLog sc)
    checks <- forM (Map.toList (kelsOf sc)) $ \(pfx, ses) ->
        forM [0 .. length ses + 1] $ \sn -> do
            (st, body) <-
                getPath srv ("/kel/" <> T.unpack pfx <> "?after=" <> show sn)
            pure $
                counterexample (T.unpack pfx <> " after " <> show sn) $
                    (st, fmap (map digestOf) (fetched body))
                        === (200, Right (map digestOf (drop (sn + 1) ses)))
    pure $ conjoin (concat checks)

wholeAnswers :: Property
wholeAnswers = forAll genScenario $ \sc -> ioProperty $ withSrv $ \srv -> do
    mapM_ (submit srv) (scLog sc)
    checks <- forM (Map.toList (kelsOf sc)) $ \(pfx, ses) -> do
        let whole = Right (map digestOf ses)
            path = "/kel/" <> T.unpack pfx
        rs <- forM [path, path <> "?other=1", path <> "?other=1&after=0"] $ \p ->
            fmap (fmap (map digestOf) . fetched) <$> getPath srv p
        pure $
            counterexample (T.unpack pfx) $
                rs
                    === [ (200, whole)
                        , (200, whole)
                        , (200, Right (map digestOf (drop 1 ses)))
                        ]
    pure $ conjoin checks

badAfter :: Property
badAfter = forAll genScenario $ \sc -> ioProperty $ withSrv $ \srv -> do
    mapM_ (submit srv) (scLog sc)
    let bad =
            [ "?after=-1"
            , "?after=01"
            , "?after=%2B1"
            , "?after=1.0"
            , "?after=%201"
            , "?after=0x1"
            , "?after=a"
            , "?after="
            , "?after"
            , "?after=99999999999999999999999"
            ]
    checks <- forM (Map.keys (kelsOf sc)) $ \pfx ->
        forM bad $ \q -> do
            r <- getPath srv ("/kel/" <> T.unpack pfx <> q)
            pure $ counterexample q $ refused 400 "badQuery" r
    pure $ conjoin (concat checks)

unhostedAfter :: Property
unhostedAfter =
    forAll ((,) <$> genScenario <*> genMember) $ \(sc, fresh) ->
        ioProperty $ withSrv $ \srv -> do
            mapM_ (submit srv) (scLog sc)
            let hosted = Map.keysSet (kelsOf sc)
                unhosted =
                    chPrefix fresh
                        : [ pfx
                          | pfx <- Map.keys (wIds (scFinal sc))
                          , not (Set.member pfx hosted)
                          ]
            checks <- forM unhosted $ \pfx -> do
                let path = "/kel/" <> T.unpack pfx
                found <- forM ["", "?after=0"] $ \q -> do
                    r <- getPath srv (path <> q)
                    pure $ counterexample (path <> q) $ refused 404 "unhosted" r
                badQ <- getPath srv (path <> "?after=01")
                pure $
                    found
                        <> [ counterexample (path <> "?after=01") $
                                refused 400 "badQuery" badQ
                           ]
            pure $ conjoin (concat checks)
