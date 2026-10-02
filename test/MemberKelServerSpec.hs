{-# LANGUAGE RecordWildCards #-}

{- |
Module      : MemberKelServerSpec
Description : POST /kel and GET /kel/<prefix> over real HTTP
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

Drives the member KEL endpoints through warp and http-client,
against a member KEL store on a real SQLite file. Status codes
and refusal classes are those of data model D4.
-}
module MemberKelServerSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (mapConcurrently)
import Control.Exception (bracket, finally, try)
import Control.Monad (forM_, unless)
import Data.Aeson (Value (..), decode, encode, object, (.=))
import Data.Aeson.Encoding (encodingToLazyByteString)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as LBS
import Data.List (sort)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import KelGroups.Kel.Codec (decodeSignedEvent, encodeSignedEvent)
import KelGroups.Kel.Store (openMemberKels)
import KelGroups.Server (kelApp)
import KelGroups.Store (KELStore (..), closeKEL, openKEL)
import KelGroups.Trivial (trivialFold, trivialInitial)
import Keri.Event
    ( Event
    , InceptionData (..)
    , RotationData (..)
    , eventDigest
    , eventPrefix
    , eventSequenceNumber
    )
import Keri.Kel (SignedEvent (..))
import MemberKelFixtures
    ( Chain (..)
    , KeySet (..)
    , genKeyPair
    , genKeySet
    , genRotChain
    , inceptionOf
    , interactChain
    , mapInception
    , mapRotation
    , resaid
    , rotateChain
    , rotationOf
    , signAll
    )
import MemberKelStoreSpec (withDb)
import Network.HTTP.Client qualified as HC
import Network.HTTP.Types (status200, status404, statusCode)
import Network.Socket qualified as Socket
import Network.Wai.Handler.Warp qualified as Warp
import System.Process
    ( CreateProcess (..)
    , StdStream (..)
    , proc
    , terminateProcess
    , withCreateProcess
    )
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Hspec.QuickCheck (modifyMaxSuccess, prop)
import Test.QuickCheck
    ( Property
    , conjoin
    , counterexample
    , forAll
    , generate
    , ioProperty
    , (===)
    )

-- | A running member KEL server on a fresh database.
data Srv = Srv
    { srvPort :: Warp.Port
    , srvMgr :: HC.Manager
    }

withSrv :: (Srv -> IO a) -> IO a
withSrv act = withDb $ \path ->
    bracket (openKEL trivialFold trivialInitial path) closeKEL $
        \store -> do
            kels <- openMemberKels (storeConn store)
            mgr <- HC.newManager HC.defaultManagerSettings
            Warp.testWithApplication
                (pure (kelApp kels Nothing))
                (\port -> act Srv{srvPort = port, srvMgr = mgr})

request
    :: Srv -> String -> String -> Maybe LBS.ByteString -> IO (Int, Value)
request srv method path body = do
    req0 <-
        HC.parseRequest $
            "http://127.0.0.1:" <> show (srvPort srv) <> path
    let req =
            req0
                { HC.method = BS8.pack method
                , HC.requestBody =
                    HC.RequestBodyLBS (maybe "" id body)
                , HC.requestHeaders =
                    [("Content-Type", "application/json")]
                }
    resp <- HC.httpLbs req (srvMgr srv)
    pure
        ( statusCode (HC.responseStatus resp)
        , fromMaybe Null (decode (HC.responseBody resp))
        )

-- | POST /kel with the wire form of a signed event.
postKel :: Srv -> SignedEvent -> IO (Int, Value)
postKel srv se =
    request srv "POST" "/kel" $
        Just (encodingToLazyByteString (encodeSignedEvent se))

-- | Submit legitimate events; any refusal fails the setup.
hostAll :: Srv -> [SignedEvent] -> IO ()
hostAll srv ses = forM_ ses $ \se -> do
    (st, body) <- postKel srv se
    unless (st == 200) $ fail ("setup refused: " <> show body)

-- | GET /kel/<prefix>.
getKel :: Srv -> Text -> IO (Int, Value)
getKel srv pfx = request srv "GET" ("/kel/" <> T.unpack pfx) Nothing

-- | The refusal class named by a refusal body.
refusalClass :: Value -> Maybe Text
refusalClass = \case
    Object o -> case KM.lookup "error" o of
        Just (String t) -> Just t
        _ -> Nothing
    _ -> Nothing

-- | The signed events of a GET /kel/<prefix> body.
fetched :: Value -> Either String [SignedEvent]
fetched = \case
    Array xs -> traverse decodeSignedEvent (foldr (:) [] xs)
    v -> Left ("not an array: " <> show v)

refused :: Int -> Text -> (Int, Value) -> Property
refused st cls (st', body) =
    counterexample (show body) $
        (st', refusalClass body) === (st, Just cls)

-- | The 200 body of an accepted submission.
acceptedBody :: Event -> Value
acceptedBody e =
    object
        [ "prefix" .= eventPrefix e
        , "sn" .= eventSequenceNumber e
        , "digest" .= eventDigest e
        ]

landed :: SignedEvent -> (Int, Value) -> Property
landed se r = r === (200, acceptedBody (event se))

firstEvent :: Chain -> SignedEvent
firstEvent ch = case chEvents ch of
    (e : _) -> e
    [] -> error "empty chain"

spec :: Spec
spec = describe "member KEL endpoints (POST /kel, GET /kel/<prefix>)" $ do
    classSpec
    exeSpec
    modifyMaxSuccess (const 10) $ do
        prop
            "INV-38-ICP-NEXT/http: an inception without a next-key \
            \commitment is refused with 422 and nothing is stored"
            $ forAll ((,) <$> genKeySet <*> genKeySet)
            $ \(cur, next) -> ioProperty $ withSrv $ \srv -> do
                let icp = inceptionOf cur next
                    noNext =
                        signAll (ksPairs cur) . resaid $
                            mapInception
                                ( \InceptionData{..} ->
                                    InceptionData{nextKeys = [], ..}
                                )
                                icp
                    ok = signAll (ksPairs cur) icp
                r1 <- postKel srv noNext
                g1 <- getKel srv (eventPrefix (event noNext))
                r2 <- postKel srv ok
                g2 <- getKel srv (eventPrefix icp)
                pure $
                    conjoin
                        [ refused 422 "missingNextCommitment" r1
                        , refused 404 "unhosted" g1
                        , landed ok r2
                        , fmap fetched g2 === (200, Right [ok])
                        ]

        prop
            "INV-38-ROT-REVEAL/http: a rotation whose keys do not match \
            \the prior commitment is refused with 422 and nothing is \
            \stored"
            $ forAll ((,,) <$> genRotChain <*> genKeySet <*> genKeyPair)
            $ \(ch, n1, stranger) -> ioProperty $ withSrv $ \srv -> do
                rs <- mapM (postKel srv) (chEvents ch)
                let revealed = chNext ch
                    wrong =
                        revealed
                            { ksPairs = stranger : drop 1 (ksPairs revealed)
                            }
                    bad =
                        signAll (ksPairs wrong) $
                            rotationOf
                                (chPrefix ch)
                                (chSn ch + 1)
                                (chTip ch)
                                wrong
                                n1
                    (good, _) = rotateChain n1 ch
                r1 <- postKel srv bad
                g1 <- getKel srv (chPrefix ch)
                r2 <- postKel srv good
                pure $
                    conjoin
                        [ map fst rs === map (const 200) rs
                        , refused 422 "commitmentNotRevealed" r1
                        , fmap fetched g1 === (200, Right (chEvents ch))
                        , landed good r2
                        ]

        prop
            "INV-38-OLD-KEY/http: after an accepted rotation, a rotation \
            \signed with the superseded keys is refused with 422"
            $ forAll ((,,) <$> genRotChain <*> genKeySet <*> genKeySet)
            $ \(ch, n1, n2) -> ioProperty $ withSrv $ \srv -> do
                hostAll srv (chEvents ch)
                let (rot1, ch1) = rotateChain n1 ch
                    forged =
                        signAll (ksPairs (chCurrent ch)) $
                            rotationOf
                                (chPrefix ch1)
                                (chSn ch1 + 1)
                                (chTip ch1)
                                n1
                                n2
                r1 <- postKel srv rot1
                r2 <- postKel srv forged
                g <- getKel srv (chPrefix ch)
                pure $
                    conjoin
                        [ landed rot1 r1
                        , refused 422 "invalidSignatures" r2
                        , fmap fetched g === (200, Right (chEvents ch1))
                        ]

        prop
            "INV-38-IXN-ENDPOINT: an interaction submitted to POST /kel \
            \is refused with 422 and nothing is stored"
            $ forAll ((,) <$> genRotChain <*> genRotChain)
            $ \(ch, other) -> ioProperty $ withSrv $ \srv -> do
                hostAll srv (chEvents ch)
                let (ixn, _) = interactChain ch
                    (ixnUnhosted, _) = interactChain other
                r1 <- postKel srv ixn
                r2 <- postKel srv ixnUnhosted
                g1 <- getKel srv (chPrefix ch)
                g2 <- getKel srv (chPrefix other)
                pure $
                    conjoin
                        [ refused 422 "unexpectedEventKind" r1
                        , refused 422 "unexpectedEventKind" r2
                        , fmap fetched g1 === (200, Right (chEvents ch))
                        , refused 404 "unhosted" g2
                        ]

        prop
            "INV-38-FETCH: GET /kel/<prefix> returns exactly the hosted \
            \events and signatures, oldest first; 404 when unhosted"
            $ forAll ((,) <$> genRotChain <*> genRotChain)
            $ \(ch, other) -> ioProperty $ withSrv $ \srv -> do
                rs <- mapM (postKel srv) (chEvents ch)
                g <- getKel srv (chPrefix ch)
                g' <- getKel srv (chPrefix other)
                pure $
                    conjoin
                        [ conjoin (zipWith landed (chEvents ch) rs)
                        , fmap fetched g === (200, Right (chEvents ch))
                        , refused 404 "unhosted" g'
                        ]

        prop
            "INV-38-UNHOSTED: a rotation for an unhosted prefix is refused \
            \with 404 and nothing is stored"
            $ forAll ((,) <$> genRotChain <*> genKeySet)
            $ \(ch, n1) -> ioProperty $ withSrv $ \srv -> do
                let (rot, _) = rotateChain n1 ch
                r <- postKel srv rot
                g <- getKel srv (chPrefix ch)
                pure $
                    conjoin
                        [ refused 404 "unhosted" r
                        , refused 404 "unhosted" g
                        ]

        prop
            "INV-38-HOST-ONCE: re-submitting a hosted inception is \
            \refused with 409 (http)"
            $ forAll genRotChain
            $ \ch -> ioProperty $ withSrv $ \srv -> do
                let icp = firstEvent ch
                r1 <- postKel srv icp
                r2 <- postKel srv icp
                g <- getKel srv (chPrefix ch)
                pure $
                    conjoin
                        [ landed icp r1
                        , refused 409 "alreadyHosted" r2
                        , fmap fetched g === (200, Right [icp])
                        ]

        prop
            "INV-38-TIP: a rotation not extending the tip is refused \
            \with 409 (http)"
            $ forAll ((,,) <$> genRotChain <*> genKeySet <*> genKeySet)
            $ \(ch, n1, n2) -> ioProperty $ withSrv $ \srv -> do
                hostAll srv (chEvents ch)
                let (rot1, ch1) = rotateChain n1 ch
                    (stale, _) = rotateChain n2 ch
                r1 <- postKel srv rot1
                r2 <- postKel srv stale
                g <- getKel srv (chPrefix ch)
                pure $
                    conjoin
                        [ landed rot1 r1
                        , refused 409 "notTipSuccessor" r2
                        , fmap fetched g === (200, Right (chEvents ch1))
                        ]

        prop "a body that is not a signed event is refused with 400" $
            forAll genRotChain $ \ch -> ioProperty $ withSrv $ \srv -> do
                r1 <- request srv "POST" "/kel" (Just "not json")
                r2 <-
                    request srv "POST" "/kel" $
                        Just (encode (object ["event" .= ("x" :: Text)]))
                g <- getKel srv (chPrefix ch)
                pure $
                    conjoin
                        [ refused 400 "notDecodable" r1
                        , refused 400 "notDecodable" r2
                        , refused 404 "unhosted" g
                        ]

-- | Every 422 refusal class reaches the client by name.
classSpec :: Spec
classSpec = modifyMaxSuccess (const 10) $ do
    prop
        "every invalid-event refusal is a 422 naming its class, and \
        \stores nothing"
        $ forAll
            ((,,,) <$> genRotChain <*> genKeySet <*> genKeySet <*> genKeyPair)
        $ \(ch, n1, other, stranger) -> ioProperty $ withSrv $ \srv -> do
            rs0 <- mapM (postKel srv) (chEvents ch)
            let cur = other
                icp = inceptionOf cur n1
                icpVariant f =
                    signAll (ksPairs cur) . resaid $ mapInception f icp
                revealed = chNext ch
                rotEvt =
                    rotationOf (chPrefix ch) (chSn ch + 1) (chTip ch) revealed n1
                rotVariant f =
                    signAll (ksPairs revealed) . resaid $ mapRotation f rotEvt
                wrong =
                    revealed{ksPairs = stranger : drop 1 (ksPairs revealed)}
                cases =
                    [
                        ( "saidMismatch"
                        , signAll (ksPairs cur) $
                            mapInception
                                (\InceptionData{..} -> InceptionData{config = ["x"], ..})
                                icp
                        )
                    ,
                        ( "prefixNotSaid"
                        , signAll (ksPairs cur) $
                            mapInception
                                ( \InceptionData{..} ->
                                    InceptionData{prefix = eventDigest rotEvt, ..}
                                )
                                icp
                        )
                    ,
                        ( "inceptionNotFirst"
                        , icpVariant $
                            \InceptionData{..} -> InceptionData{sequenceNumber = 1, ..}
                        )
                    ,
                        ( "missingNextCommitment"
                        , icpVariant $
                            \InceptionData{..} -> InceptionData{nextKeys = [], ..}
                        )
                    ,
                        ( "thresholdOutOfRange"
                        , icpVariant $
                            \InceptionData{..} ->
                                InceptionData{signingThreshold = 0, ..}
                        )
                    ,
                        ( "witnessesPresent"
                        , icpVariant $
                            \InceptionData{..} ->
                                InceptionData{witnessThreshold = 1, ..}
                        )
                    ,
                        ( "invalidSignatures"
                        , icp `signedWith` []
                        )
                    ,
                        ( "missingNextCommitment"
                        , rotVariant $
                            \RotationData{..} -> RotationData{nextKeys = [], ..}
                        )
                    ,
                        ( "commitmentNotRevealed"
                        , signAll (ksPairs wrong) $
                            rotationOf
                                (chPrefix ch)
                                (chSn ch + 1)
                                (chTip ch)
                                wrong
                                n1
                        )
                    ,
                        ( "invalidSignatures"
                        , signAll (ksPairs (chCurrent ch)) rotEvt
                        )
                    ,
                        ( "unexpectedEventKind"
                        , fst (interactChain ch)
                        )
                    ]
            rs <- mapM (postKel srv . snd) cases
            g1 <- getKel srv (chPrefix ch)
            g2 <- getKel srv (eventPrefix icp)
            pure $
                conjoin $
                    [ map fst rs0 === map (const 200) rs0
                    , fmap fetched g1 === (200, Right (chEvents ch))
                    , refused 404 "unhosted" g2
                    ]
                        <> [ counterexample cls (refused 422 (T.pack cls) r)
                           | ((cls, _), r) <- zip cases rs
                           ]

    prop
        "INV-38-ATOMIC: concurrent POSTs of one inception land once; \
        \the others get 409, never 500 (http)"
        $ forAll ((,,) <$> genRotChain <*> genKeySet <*> genKeySet)
        $ \(ch, n1, n2) -> ioProperty $ withSrv $ \srv -> do
            let icp = firstEvent ch
            rs <- mapConcurrently (const (postKel srv icp)) [1 .. 8 :: Int]
            hostAll srv (drop 1 (chEvents ch))
            let competing = [fst (rotateChain k ch) | k <- [n1, n2]]
            rots <-
                mapConcurrently (postKel srv) (concat (replicate 4 competing))
            g <- getKel srv (chPrefix ch)
            let winners = [se | (se, (200, _)) <- zip (concat (replicate 4 competing)) rots]
            pure $
                conjoin
                    [ sort (map fst rs) === 200 : replicate 7 409
                    , sort (map fst rots) === 200 : replicate 7 409
                    , fmap fetched g
                        === (200, Right (chEvents ch <> take 1 winners))
                    ]

    prop "numbers out of range or negative are refused with 400" $
        forAll genRotChain $ \ch -> ioProperty $ withSrv $ \srv -> do
            let icp = firstEvent ch
                wire = case decode (encodingToLazyByteString (encodeSignedEvent icp)) of
                    Just (Object o) -> o
                    _ -> error "wire form is not an object"
                withField k v = case KM.lookup "event" wire of
                    Just (Object e) ->
                        encode (Object (KM.insert "event" (Object (KM.insert k v e)) wire))
                    _ -> error "no event"
                bodies =
                    [ withField "s" (String "-1")
                    , withField "s" (String "ffffffffffffffffffffffff")
                    , withField "kt" (String "-1")
                    , withField "kt" (String "99999999999999999999999")
                    ]
            rs <- mapM (request srv "POST" "/kel" . Just) bodies
            g <- getKel srv (chPrefix ch)
            pure $
                conjoin $
                    refused 404 "unhosted" g
                        : map (refused 400 "notDecodable") rs
  where
    signedWith evt sigs = SignedEvent{event = evt, signatures = sigs}

-- | The built executable on a free port and a fresh database.
withServerExe :: (Int -> IO a) -> IO a
withServerExe act = withDb $ \db -> do
    (port, sock) <- Warp.openFreePort
    Socket.close sock
    let cp =
            (proc "kelgroups-server" [show port, db, "pass"]){std_out = NoStream}
    withCreateProcess cp $ \_ _ _ ph -> do
        mgr <- HC.newManager HC.defaultManagerSettings
        let ready :: Int -> IO ()
            ready 0 = fail "kelgroups-server did not start"
            ready n = do
                r <- try (getPath mgr port "/kel/none")
                case r :: Either HC.HttpException (HC.Response LBS.ByteString) of
                    Right _ -> pure ()
                    Left _ -> threadDelay 100000 >> ready (n - 1)
        ready 100
        act port `finally` terminateProcess ph

getPath
    :: HC.Manager -> Int -> String -> IO (HC.Response LBS.ByteString)
getPath mgr port path = do
    req <- HC.parseRequest ("http://127.0.0.1:" <> show port <> path)
    HC.httpLbs req mgr

exeSpec :: Spec
exeSpec =
    it
        "INV-38-FETCH: the kelgroups-server executable serves POST /kel \
        \and GET /kel/<prefix>"
        $ withServerExe
        $ \port -> do
            ch <- generate genRotChain
            mgr <- HC.newManager HC.defaultManagerSettings
            forM_ (chEvents ch) $ \se -> do
                req0 <- HC.parseRequest ("http://127.0.0.1:" <> show port <> "/kel")
                let req =
                        req0
                            { HC.method = "POST"
                            , HC.requestBody =
                                HC.RequestBodyLBS
                                    (encodingToLazyByteString (encodeSignedEvent se))
                            }
                resp <- HC.httpLbs req mgr
                HC.responseStatus resp `shouldBe` status200
            resp <- getPath mgr port ("/kel/" <> T.unpack (chPrefix ch))
            HC.responseStatus resp `shouldBe` status200
            case decode (HC.responseBody resp) of
                Just (Array xs) ->
                    traverse decodeSignedEvent (foldr (:) [] xs)
                        `shouldBe` Right (chEvents ch)
                other -> fail ("not an array: " <> show other)
            unknown <- getPath mgr port "/kel/none"
            HC.responseStatus unknown `shouldBe` status404
