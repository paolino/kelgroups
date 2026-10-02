{-# LANGUAGE RecordWildCards #-}

{- |
Module      : GroupServerSpec
Description : POST /actions over real HTTP
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

Drives @POST /actions@ through warp and http-client against the
member KEL store on a real SQLite file. Status codes and refusal
classes are those of data model D4; the success body is D3.
-}
module GroupServerSpec (spec) where

import Control.Concurrent.Async (mapConcurrently)
import Control.Monad (forM, forM_, unless)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Encoding (encodingToLazyByteString)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Text (Text)
import Database.SQLite.Simple (withConnection)
import GroupFixtures
    ( actWith
    , anchoredOf
    , appAnchor
    , appOf
    , appPayload
    , genAppData
    , genMember
    , genMultiKeyMember
    , genNumericData
    , genesisAnchor
    , genesisOf
    , respellNumbers
    )
import GroupSpec (Scene (..), genScene)
import KelGroups.Kel.Codec (encodeSignedEvent)
import KelGroups.Kel.Store (openMemberKels)
import KelGroups.Server (kelApp)
import Keri.Event
    ( InteractionData (..)
    , eventDigest
    , eventPrefix
    , eventSequenceNumber
    )
import Keri.Kel (SignedEvent (..))
import MemberKelFixtures
    ( Chain (..)
    , KeySet (..)
    , genKeySet
    , mapInteraction
    , resaid
    , rotateChain
    , signAll
    )
import MemberKelServerSpec
    ( Srv (..)
    , fetched
    , getKel
    , hostAll
    , postKel
    , refused
    , request
    )
import MemberKelStoreSpec (withDb)
import Network.HTTP.Client qualified as HC
import Network.Wai.Handler.Warp qualified as Warp
import Test.Hspec (Spec, describe)
import Test.Hspec.QuickCheck (modifyMaxSuccess, prop)
import Test.QuickCheck
    ( Property
    , conjoin
    , counterexample
    , forAll
    , ioProperty
    , property
    , (===)
    )

-- | A running server on a fresh database, member KELs only.
withSrv :: (Srv -> IO a) -> IO a
withSrv act = withDb $ \path -> withConnection path $ \c -> do
    kels <- openMemberKels c
    mgr <- HC.newManager HC.defaultManagerSettings
    Warp.testWithApplication
        (pure (kelApp kels Nothing))
        (\port -> act Srv{srvPort = port, srvMgr = mgr})

-- | POST /actions with the wire form of a signed event.
postAction :: Srv -> SignedEvent -> IO (Int, Value)
postAction srv se =
    request srv "POST" "/actions" $
        Just (encodingToLazyByteString (encodeSignedEvent se))

-- | Admit actions; a refusal fails the setup.
admitAll :: Srv -> [SignedEvent] -> IO ()
admitAll srv ses = forM_ ses $ \se -> do
    (st, body) <- postAction srv se
    unless (st == 200) $ fail ("setup refused: " <> show body)

-- | Host the scene's members and admit its setup actions.
stage :: Srv -> Scene -> IO ()
stage srv Scene{..} = do
    hostAll srv (concatMap chEvents scStart)
    admitAll srv scSetup

digestOf :: SignedEvent -> Text
digestOf = eventDigest . event

-- | The 200 body of an admitted action in group @g@ (D3).
admittedBody :: Text -> SignedEvent -> Value
admittedBody g se =
    object
        [ "group" .= g
        , "head" .= digestOf se
        , "prefix" .= eventPrefix (event se)
        , "sn" .= eventSequenceNumber (event se)
        ]

admitted :: Text -> SignedEvent -> (Int, Value) -> Property
admitted g se r = r === (200, admittedBody g se)

-- | The KEL of a prefix as GET /kel returns it.
kelOf :: Srv -> Text -> IO (Int, Either String [SignedEvent])
kelOf srv pfx = fmap fetched <$> getKel srv pfx

inceptionDigest :: Chain -> Text
inceptionDigest ch = case chEvents ch of
    e : _ -> digestOf e
    [] -> error "empty KEL fixture"

withAnchor :: (Value -> Value) -> SignedEvent -> SignedEvent
withAnchor f se =
    se
        { event =
            mapInteraction
                (\InteractionData{..} -> InteractionData{anchors = map f anchors, ..})
                (event se)
        }

setKey :: Text -> Value -> Value -> Value
setKey k v = \case
    Object o -> Object (KM.insert (Key.fromText k) v o)
    other -> other

spec :: Spec
spec = describe "POST /actions" $ modifyMaxSuccess (const 10) $ do
    prop
        "INV-39-TAMPER/http: a signed action with group id, payload, p \
        \or prev altered is refused (422 as signed; recomputed d: 422, \
        \409 for p); KEL and chain unchanged"
        $ forAll ((,) <$> genScene <*> genAppData)
        $ \(sc@Scene{..}, d) -> ioProperty $ withSrv $ \srv -> do
            stage srv sc
            let (legit, _) = appOf scGroup scHead d scMember
                elsewhere = inceptionDigest scMember
                alterations =
                    [
                        ( "group id"
                        , withAnchor (setKey "group" (String elsewhere))
                        , 422
                        , "invalidSignatures"
                        )
                    ,
                        ( "payload"
                        , withAnchor
                            (setKey "payload" (appPayload (object ["tampered" .= True])))
                        , 422
                        , "invalidSignatures"
                        )
                    ,
                        ( "prev"
                        , withAnchor (setKey "prev" (String elsewhere))
                        , 422
                        , "invalidSignatures"
                        )
                    ,
                        ( "p"
                        , \se ->
                            se
                                { event =
                                    mapInteraction
                                        (\InteractionData{..} -> InteractionData{priorDigest = elsewhere, ..})
                                        (event se)
                                }
                        , 409
                        , "notTipSuccessor"
                        )
                    ]
            rs <- forM alterations $ \(what, f, st, cls) -> do
                r1 <- postAction srv (f legit)
                let se = f legit
                r2 <- postAction srv se{event = resaid (event se)}
                pure $
                    conjoin
                        [ counterexample (what <> ", d as signed") $
                            refused 422 "saidMismatch" r1
                        , counterexample (what <> ", d recomputed") $ refused st cls r2
                        ]
            k <- kelOf srv (chPrefix scMember)
            r <- postAction srv legit
            pure $
                conjoin $
                    rs
                        <> [ k === (200, Right (chEvents scMember))
                           , admitted scGroup legit r
                           ]

    prop
        "INV-39-LINK/http: a correctly signed action with p not the \
        \signer's tip (409), prev not the head (409) or a group id with \
        \no chain (404) is refused; nothing stored"
        $ forAll ((,) <$> genScene <*> genAppData)
        $ \(sc@Scene{..}, d) -> ioProperty $ withSrv $ \srv -> do
            stage srv sc
            let stale = inceptionDigest scMember
                staleP =
                    signAll (ksPairs (chCurrent scMember)) $
                        anchoredOf
                            (chPrefix scMember)
                            (chSn scMember + 1)
                            stale
                            [appAnchor scGroup scHead d]
                (staleHead, _) = appOf scGroup stale d scMember
                (noGroup, _) = appOf stale scHead d scMember
                (legit, _) = appOf scGroup scHead d scMember
            r1 <- postAction srv staleP
            r2 <- postAction srv staleHead
            r3 <- postAction srv noGroup
            k <- kelOf srv (chPrefix scMember)
            r <- postAction srv legit
            pure $
                conjoin
                    [ refused 409 "notTipSuccessor" r1
                    , refused 409 "prevNotHead" r2
                    , refused 404 "noSuchGroup" r3
                    , k === (200, Right (chEvents scMember))
                    , admitted scGroup legit r
                    ]

    modifyMaxSuccess (const 2)
        $ prop
            "INV-39-CONTEND/http: two actions signed against one head, \
            \posted concurrently, 20 rounds: exactly one 200 and one 409 \
            \each round; the refused one, re-signed against the new tip \
            \and head, is admitted"
        $ forAll genMember
        $ \a0 -> ioProperty $ withSrv $ \srv -> do
            hostAll srv (chEvents a0)
            let (g, a1) = genesisOf a0
                gid = digestOf g
            admitAll srv [g]
            let go :: Int -> (Text, Chain) -> IO ([Property], Chain)
                go i (h, ch)
                    | i > 20 = pure ([], ch)
                    | otherwise = do
                        let dataOf :: Int -> Value
                            dataOf side = object ["round" .= i, "side" .= side]
                            racers = [appOf gid h (dataOf side) ch | side <- [0, 1]]
                        rs <- mapConcurrently (postAction srv . fst) racers
                        case [side | (side, (st, _)) <- zip [0 :: Int ..] rs, st /= 200] of
                            [loser]
                                | [((wse, wch), wr)] <-
                                    [(x, r) | (side, x, r) <- zip3 [0 ..] racers rs, side /= loser] -> do
                                    let (z, zch) = appOf gid (digestOf wse) (dataOf loser) wch
                                    rz <- postAction srv z
                                    (ps, chEnd) <- go (i + 1) (digestOf z, zch)
                                    pure
                                        ( counterexample ("round " <> show i) (admitted gid wse wr)
                                            : counterexample
                                                ("round " <> show i)
                                                (refused 409 "notTipSuccessor" (rs !! loser))
                                            : counterexample
                                                ("round " <> show i <> " re-signed")
                                                (admitted gid z rz)
                                            : ps
                                        , chEnd
                                        )
                            _ ->
                                pure
                                    ( [counterexample ("round " <> show i <> ": " <> show rs) False]
                                    , ch
                                    )
            (ps, chEnd) <- go 1 (gid, a1)
            k <- kelOf srv (chPrefix a0)
            pure $ conjoin $ ps <> [k === (200, Right (chEvents chEnd))]

    prop
        "INV-39-RETRY/http: identical bytes posted again after admission, \
        \immediately and after later actions, return 200 with the same \
        \body; the event is stored once; another signature set is \
        \refused with 409; the same value in other bytes is \
        \refused with 422"
        $ forAll ((,,) <$> genMultiKeyMember <*> genNumericData <*> genAppData)
        $ \(a0, d1, d2) -> ioProperty $ withSrv $ \srv -> do
            hostAll srv (chEvents a0)
            let (g, a1) = genesisOf a0
                gid = digestOf g
                (x, a2) = appOf gid gid d1 a1
                (y, a3) = appOf gid (digestOf x) d2 a2
                KeySet{ksThreshold} = chCurrent a1
                otherSet = x{signatures = take ksThreshold (signatures x)}
            rg <- postAction srv g
            rx <- postAction srv x
            rx1 <- postAction srv x
            alt1 <- postAction srv otherSet
            ry <- postAction srv y
            rx2 <- postAction srv x
            rg2 <- postAction srv g
            alt2 <- postAction srv otherSet
            respelled <- postAction srv (withAnchor (respellNumbers 1) x)
            k <- kelOf srv (chPrefix a0)
            pure $
                conjoin
                    [ counterexample "signature sets coincide" $
                        signatures otherSet /= signatures x
                    , admitted gid g rg
                    , admitted gid x rx
                    , rx1 === rx
                    , rx2 === rx
                    , rg2 === rg
                    , admitted gid y ry
                    , refused 409 "notTipSuccessor" alt1
                    , refused 409 "notTipSuccessor" alt2
                    , refused 422 "saidMismatch" respelled
                    , k === (200, Right (chEvents a3))
                    ]

    prop
        "INV-39-UNHOSTED: an action whose signer has no hosted KEL is \
        \refused with 404; hosted, it is admitted"
        $ forAll ((,,) <$> genScene <*> genMember <*> genAppData)
        $ \(sc@Scene{..}, u0, d) -> ioProperty $ withSrv $ \srv -> do
            stage srv sc
            let (gu, _) = genesisOf u0
                (au, _) = appOf scGroup scHead d u0
            r1 <- postAction srv gu
            r2 <- postAction srv au
            k <- getKel srv (chPrefix u0)
            hostAll srv (chEvents u0)
            r3 <- postAction srv gu
            pure $
                conjoin
                    [ refused 404 "unhosted" r1
                    , refused 404 "unhosted" r2
                    , refused 404 "unhosted" k
                    , admitted (digestOf gu) gu r3
                    ]

    prop
        "INV-39-MEMBER/http: an action by a hosted non-member with \
        \correct p and prev is refused with 403; nothing stored"
        $ forAll ((,) <$> genScene <*> genAppData)
        $ \(sc@Scene{..}, d) -> ioProperty $ withSrv $ \srv -> do
            stage srv sc
            let (byOther, _) = appOf scGroup scHead d scOther
                (legit, _) = appOf scGroup scHead d scMember
            r1 <- postAction srv byOther
            k <- kelOf srv (chPrefix scOther)
            r2 <- postAction srv legit
            pure $
                conjoin
                    [ refused 403 "notAMember" r1
                    , k === (200, Right (chEvents scOther))
                    , admitted scGroup legit r2
                    ]

    prop
        "INV-39-SHAPE/http: an ixn without exactly one well-formed anchor \
        \is refused with 400, a body that is no signed event with 400, a \
        \non-ixn with 422; POST /kel refuses a group action with 422; \
        \nothing stored"
        $ forAll ((,,) <$> genScene <*> genAppData <*> genKeySet)
        $ \(sc@Scene{..}, d, n1) -> ioProperty $ withSrv $ \srv -> do
            stage srv sc
            let app = appAnchor scGroup scHead d
                shapes =
                    [ ("no anchor", [])
                    , ("two anchors", [app, app])
                    , ("extra anchor key", [setKey "x" (Number 1) app])
                    ,
                        ( "unknown payload tag"
                        , [setKey "payload" (object ["t" .= ("leave" :: Text)]) app]
                        )
                    ,
                        ( "genesis with group and prev"
                        , [setKey "payload" (object ["t" .= ("genesis" :: Text)]) app]
                        )
                    ]
                (rot, _) = rotateChain n1 scMember
                (gOther, _) = genesisOf scOther
            rs <- forM shapes $ \(what, as) -> do
                r <- postAction srv (fst (actWith as scMember))
                pure $ counterexample what $ refused 400 "notAGroupAction" r
            rBody <- request srv "POST" "/actions" (Just "{\"event\": 1}")
            rRot <- postAction srv rot
            rKel <- postKel srv gOther
            kA <- kelOf srv (chPrefix scMember)
            kB <- kelOf srv (chPrefix scOther)
            rOk <- postAction srv (fst (actWith [app] scMember))
            rGenesis <- postAction srv (fst (actWith [genesisAnchor] scOther))
            pure $
                conjoin $
                    rs
                        <> [ refused 400 "notDecodable" rBody
                           , refused 422 "unexpectedEventKind" rRot
                           , refused 422 "unexpectedEventKind" rKel
                           , kA === (200, Right (chEvents scMember))
                           , kB === (200, Right (chEvents scOther))
                           , counterexample "well-formed action refused" $
                                property (fst rOk == 200)
                           , admitted (digestOf gOther) gOther rGenesis
                           ]
