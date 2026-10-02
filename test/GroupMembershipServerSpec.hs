{-# LANGUAGE RecordWildCards #-}

{- |
Module      : GroupMembershipServerSpec
Description : Membership actions over POST /actions
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

Membership histories built by legitimate signing ("GroupWorld")
posted through warp and http-client to @POST /actions@ against the
member KEL store on a real SQLite file. Status codes and @error@
classes are those of data model D4; a refused action leaves the
signer's KEL as @GET /kel@ returns it.
-}
module GroupMembershipServerSpec (spec) where

import Control.Monad (forM, forM_, unless)
import Data.Aeson (Value, object, (.=))
import Data.Aeson.Encoding (encodingToLazyByteString)
import Data.Text (Text)
import Database.SQLite.Simple (Query (..), execute_, withConnection)
import GroupFixtures (actionAnchor, genAppData, memberPayload)
import GroupStoreSpec (memberTable, withKels)
import GroupWorld
    ( Intent (..)
    , Team (..)
    , World (..)
    , act
    , eventsOf
    , found
    , genTeam
    , headIn
    , rosterOf
    , sets
    , sign
    , signAnchor
    , signAt
    )
import KelGroups.Group (chainActions, roster)
import KelGroups.Group qualified as Group
import KelGroups.Kel (kelEvents)
import KelGroups.Kel.Codec (encodeSignedEvent)
import KelGroups.Kel.Store
    ( lookupChain
    , lookupMemberKel
    , openMemberKels
    )
import KelGroups.Server (kelApp)
import Keri.Event
    ( Event (..)
    , eventDigest
    , eventPrefix
    , eventSequenceNumber
    )
import Keri.Kel (SignedEvent (..))
import MemberKelServerSpec
    ( Srv (..)
    , fetched
    , getKel
    , postKel
    , refused
    , request
    )
import MemberKelStoreSpec (withDb)
import Network.HTTP.Client qualified as HC
import Network.Wai (Application)
import Network.Wai.Handler.Warp qualified as Warp
import Test.Hspec (Spec, describe)
import Test.Hspec.QuickCheck (modifyMaxSuccess, prop)
import Test.QuickCheck
    ( Property
    , conjoin
    , counterexample
    , forAll
    , ioProperty
    , (===)
    )

-- | A running server on a fresh database file, member KELs only.
withSrv :: (FilePath -> Srv -> IO a) -> IO a
withSrv = withSrvBy Warp.testWithApplication

{- | A running server whose handler exceptions are answered as
.run@ answers them (500), not rethrown into the test.
-}
withProductionSrv :: (FilePath -> Srv -> IO a) -> IO a
withProductionSrv = withSrvBy Warp.withApplication

withSrvBy
    :: (IO Application -> (Warp.Port -> IO a) -> IO a)
    -> (FilePath -> Srv -> IO a)
    -> IO a
withSrvBy serve k = withDb $ \path -> withConnection path $ \c -> do
    kels <- openMemberKels c
    mgr <- HC.newManager HC.defaultManagerSettings
    serve
        (pure (kelApp kels Nothing))
        (\port -> k path Srv{srvPort = port, srvMgr = mgr})

-- | POST /actions with the wire form of a signed event.
postAction :: Srv -> SignedEvent -> IO (Int, Value)
postAction srv se =
    request srv "POST" "/actions" $
        Just (encodingToLazyByteString (encodeSignedEvent se))

-- | Post a world's log in order; a refusal fails the setup.
replay :: Srv -> World -> IO ()
replay srv w = forM_ (wLog w) $ \se -> do
    (st, body) <- case event se of
        Interaction{} -> postAction srv se
        _ -> postKel srv se
    unless (st == 200) $ fail ("setup refused: " <> show body)

-- | The 200 body of an admitted action in group @g@ (#39 D3).
admittedBody :: Text -> SignedEvent -> Value
admittedBody g se =
    object
        [ "group" .= g
        , "head" .= eventDigest (event se)
        , "prefix" .= eventPrefix (event se)
        , "sn" .= eventSequenceNumber (event se)
        ]

admitted :: Text -> SignedEvent -> (Int, Value) -> Property
admitted g se r = r === (200, admittedBody g se)

-- | The KEL of a prefix as GET /kel returns it.
kelOf :: Srv -> Text -> IO (Int, Either String [SignedEvent])
kelOf srv pfx = fmap fetched <$> getKel srv pfx

-- | A refused action stored nothing: the signer's KEL is as hosted.
unchanged :: Srv -> World -> Text -> IO Property
unchanged srv w s = do
    k <- kelOf srv s
    pure $
        counterexample "KEL changed" $
            k === (200, Right (eventsOf s w))

spec :: Spec
spec = describe "POST /actions (membership actions)" $
    modifyMaxSuccess (const 5) $ do
        prop
            "INV-40-ADMIN/http: a current non-admin member's add, remove, \
            \grant or revoke, otherwise valid, is refused 403 notAnAdmin, \
            \nothing stored; an admin's add is admitted"
            $ forAll genTeam
            $ \Team{..} -> ioProperty $ withSrv $ \_ srv -> do
                replay srv tWorld
                rs <- forM [IAdd tC, IRemove tD, IGrant tD, IRevoke tE] $ \i ->
                    counterexample (show i) . refused 403 "notAnAdmin"
                        <$> postAction srv (sign tGroup tB i tWorld)
                k <- unchanged srv tWorld tB
                let ok = sign tGroup tA (IAdd tC) tWorld
                r <- postAction srv ok
                pure $ conjoin (rs <> [k, admitted tGroup ok r])

        prop
            "INV-40-LAST-ADMIN/http: with other members and no other admin \
            \the last admin's leave, revoke and remove of itself are \
            \refused 409 lastAdmin; as sole member its revoke of itself is \
            \refused and its leave admitted; with a second admin its leave \
            \is admitted"
            $ forAll genTeam
            $ \Team{..} -> ioProperty $ do
                let lone = act tGroup tA (IRevoke tE) tWorld
                    (g1, sole) = found tA tWorld
                p1 <- withSrv $ \_ srv -> do
                    replay srv lone
                    rs <- forM [ILeave, IRevoke tA, IRemove tA] $ \i ->
                        counterexample (show i) . refused 409 "lastAdmin"
                            <$> postAction srv (sign tGroup tA i lone)
                    k <- unchanged srv lone tA
                    pure $ conjoin (k : rs)
                p2 <- withSrv $ \_ srv -> do
                    replay srv sole
                    r1 <- postAction srv (sign g1 tA (IRevoke tA) sole)
                    let leave = sign g1 tA ILeave sole
                    r2 <- postAction srv leave
                    pure $ conjoin [refused 409 "lastAdmin" r1, admitted g1 leave r2]
                p3 <- withSrv $ \_ srv -> do
                    replay srv tWorld
                    let leave = sign tGroup tA ILeave tWorld
                    admitted tGroup leave <$> postAction srv leave
                pure $
                    conjoin
                        [ counterexample "other members" p1
                        , counterexample "sole member" p2
                        , counterexample "second admin" p3
                        ]

        prop
            "INV-40-ADD-HOSTED/http: an admin's add of an identity with no \
            \hosted KEL is refused 404 memberNotHosted, nothing stored; \
            \after that KEL is hosted the add is admitted"
            $ forAll genTeam
            $ \Team{..} -> ioProperty $ withSrv $ \_ srv -> do
                replay srv tWorld
                let se = sign tGroup tA (IAdd tU) tWorld
                r1 <- postAction srv se
                k <- unchanged srv tWorld tA
                forM_ (eventsOf tU tWorld) $ postKel srv
                r2 <- postAction srv se
                pure $
                    conjoin
                        [refused 404 "memberNotHosted" r1, k, admitted tGroup se r2]

        prop
            "INV-40-REMOVED/http: after x is removed its new action is \
            \refused 403 notAMember, nothing stored; its earlier actions \
            \stay in the chain after reopen"
            $ forAll ((,,) <$> genTeam <*> genAppData <*> genAppData)
            $ \(Team{..}, d1, d2) -> ioProperty $ withSrv $ \path srv -> do
                let earlier = sign tGroup tB (IApp d1) tWorld
                    w1 = act tGroup tB (IApp d1) tWorld
                    w2 = act tGroup tA (IRemove tB) w1
                replay srv w2
                r <- postAction srv (sign tGroup tB (IApp d2) w2)
                k <- unchanged srv w2 tB
                (chain, rost) <- withKels path $ \_ kels -> do
                    ch <- lookupChain kels tGroup
                    pure
                        ( map Group.signed . chainActions <$> ch
                        , sets . roster <$> ch
                        )
                pure $
                    conjoin
                        [ refused 403 "notAMember" r
                        , k
                        , counterexample "earlier action dropped" $
                            maybe False (earlier `elem`) chain
                        , rost === rosterOf tGroup w2
                        ]

        prop
            "INV-40-STATE/http: add of a member, remove or grant of a \
            \non-member, grant of an admin, revoke of a non-admin are \
            \refused 409 alreadyMember, targetNotMember, alreadyAdmin, \
            \targetNotAdmin; nothing stored"
            $ forAll genTeam
            $ \Team{..} -> ioProperty $ withSrv $ \_ srv -> do
                replay srv tWorld
                rs <-
                    forM
                        [ (IAdd tB, "alreadyMember")
                        , (IRemove tC, "targetNotMember")
                        , (IGrant tC, "targetNotMember")
                        , (IGrant tE, "alreadyAdmin")
                        , (IRevoke tB, "targetNotAdmin")
                        ]
                        $ \(i, cls) ->
                            counterexample (show i) . refused 409 cls
                                <$> postAction srv (sign tGroup tA i tWorld)
                k <- unchanged srv tWorld tA
                pure $ conjoin (k : rs)

        prop
            "INV-40-LEAVE/http: a non-admin member's leave is admitted and \
            \its later actions are refused 403; a non-member's leave is \
            \refused 403"
            $ forAll ((,) <$> genTeam <*> genAppData)
            $ \(Team{..}, d) -> ioProperty $ withSrv $ \_ srv -> do
                replay srv tWorld
                let leave = sign tGroup tB ILeave tWorld
                    w1 = act tGroup tB ILeave tWorld
                r1 <- postAction srv leave
                r2 <- postAction srv (sign tGroup tB (IApp d) w1)
                r3 <- postAction srv (sign tGroup tC ILeave w1)
                pure $
                    conjoin
                        [ admitted tGroup leave r1
                        , refused 403 "notAMember" r2
                        , refused 403 "notAMember" r3
                        ]

        prop
            "INV-40-SHAPE/http: membership payloads with a missing or extra \
            \key, or a non-string member, are refused 400 notAGroupAction; \
            \nothing stored"
            $ forAll genTeam
            $ \Team{..} -> ioProperty $ withSrv $ \_ srv -> do
                replay srv tWorld
                let hd = maybe tGroup id (headIn tGroup tWorld)
                    anchored pl = actionAnchor tGroup hd pl
                    shapes =
                        [ ("add without member", anchored (object ["t" .= ("add" :: Text)]))
                        ,
                            ( "remove with an extra key"
                            , anchored
                                ( object
                                    [ "t" .= ("remove" :: Text)
                                    , "member" .= tB
                                    , "x" .= (1 :: Int)
                                    ]
                                )
                            )
                        ,
                            ( "grant member a number"
                            , anchored (object ["t" .= ("grant" :: Text), "member" .= (1 :: Int)])
                            )
                        ,
                            ( "revoke member a list"
                            , anchored (object ["t" .= ("revoke" :: Text), "member" .= [tE]])
                            )
                        ,
                            ( "leave with a member"
                            , anchored (object ["t" .= ("leave" :: Text), "member" .= tA])
                            )
                        ]
                rs <- forM shapes $ \(what, anchor) ->
                    counterexample what . refused 400 "notAGroupAction"
                        <$> postAction srv (signAnchor tA anchor tWorld)
                k <- unchanged srv tWorld tA
                let ok = signAnchor tA (anchored (memberPayload "add" tC)) tWorld
                r <- postAction srv ok
                pure $ conjoin (rs <> [k, admitted tGroup ok r])

        prop
            "INV-40-ORDER/http: with two failing checks the earlier one of \
            \D4 decides: member before admin, admin before target hosted, \
            \admin before target state, prev before admin"
            $ forAll genTeam
            $ \Team{..} -> ioProperty $ withSrv $ \_ srv -> do
                replay srv tWorld
                let w = tWorld
                    cases =
                        [ ("member+admin", sign tGroup tC (IRevoke tE) w, 403, "notAMember")
                        , ("admin+hosted", sign tGroup tB (IAdd tU) w, 403, "notAnAdmin")
                        , ("admin+target", sign tGroup tB (IAdd tD) w, 403, "notAnAdmin")
                        ,
                            ( "prev+admin"
                            , signAt tGroup tGroup tB (IAdd tC) w
                            , 409
                            , "prevNotHead"
                            )
                        ]
                rs <- forM cases $ \(what, se, st, cls) ->
                    counterexample what . refused st cls <$> postAction srv se
                ks <- mapM (unchanged srv w) [tB, tC]
                pure $ conjoin (rs <> ks)

        prop
            "INV-40-WRITE500/http: a store write failure during POST /actions \
            \of a membership action answers 500 and stores nothing, in \
            \memory and after reopen; retried, it is admitted"
            $ forAll genTeam
            $ \Team{..} -> ioProperty $ withProductionSrv $ \path srv -> do
                replay srv tWorld
                let se = sign tGroup tA (IAdd tC) tWorld
                    observe = withKels path $ \_ kels ->
                        (,)
                            <$> (fmap Group.head <$> lookupChain kels tGroup)
                            <*> (fmap kelEvents <$> lookupMemberKel kels tA)
                table <- withConnection path memberTable
                withConnection path $ \c ->
                    execute_ c $
                        Query $
                            "CREATE TRIGGER injected BEFORE INSERT ON \""
                                <> table
                                <> "\" BEGIN SELECT RAISE(ABORT, 'injected'); END"
                (st, _) <- postAction srv se
                k <- unchanged srv tWorld tA
                withConnection path $ \c -> execute_ c "DROP TRIGGER injected"
                re <- observe
                r <- postAction srv se
                pure $
                    conjoin
                        [ counterexample "status" $ st === 500
                        , k
                        , re === (headIn tGroup tWorld, Just (eventsOf tA tWorld))
                        , admitted tGroup se r
                        ]
