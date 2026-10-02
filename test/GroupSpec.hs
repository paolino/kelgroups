{-# LANGUAGE RecordWildCards #-}

{- |
Module      : GroupSpec
Description : The admission rule for group actions, pure
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

Checks of 'KelGroups.Group.admit' over hosted states reached by
legitimate operations: member KELs built and signed with real
keys, group actions admitted one after the other. Expected
refusals are those of data model D4 and the Lean @Admissible@.
-}
module GroupSpec
    ( spec
    , Scene (..)
    , genScene
    , hostedOf
    , admitAll
    ) where

import Control.Monad (foldM)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import GroupFixtures
    ( actWith
    , anchoredOf
    , appAnchor
    , appOf
    , appPayload
    , genAppData
    , genMember
    , genesisAnchor
    , genesisOf
    )
import KelGroups.Group
    ( Admission (..)
    , GroupRefusal (..)
    , Hosted (..)
    , Roster (..)
    , admit
    , chainActions
    , roster
    )
import KelGroups.Group qualified as Group
import KelGroups.Kel (KelRefusal (..), kelEvents, replayKel)
import Keri.Event
    ( EventType (..)
    , InteractionData (..)
    , eventDigest
    , eventSequenceNumber
    )
import Keri.Kel (SignedEvent (..))
import MemberKelFixtures
    ( Chain (..)
    , genKeySet
    , mapInteraction
    , resaid
    , rotateChain
    , signAll
    )
import MemberKelFixtures qualified as F
import Test.Hspec (Spec, describe)
import Test.Hspec.QuickCheck (modifyMaxSuccess, prop)
import Test.QuickCheck
    ( Gen
    , Property
    , chooseInt
    , conjoin
    , counterexample
    , forAll
    , property
    , vectorOf
    , (===)
    )

{- | A member hosting one group with zero to three app actions
after its genesis, and a second hosted member outside it.
-}
data Scene = Scene
    { scStart :: [Chain]
    -- ^ the two member KELs before any action
    , scSetup :: [SignedEvent]
    -- ^ the genesis and the app actions, in admission order
    , scMember :: Chain
    -- ^ the group member's KEL after its actions
    , scOther :: Chain
    -- ^ the non-member's KEL
    , scGroup :: Text
    , scHead :: Text
    }
    deriving stock (Show)

genScene :: Gen Scene
genScene = do
    a0 <- genMember
    b <- genMember
    n <- chooseInt (0, 3)
    ds <- vectorOf n genAppData
    let (g, a1) = genesisOf a0
        gid = eventDigest (event g)
        step (acts, h, ch) d =
            let (se, ch') = appOf gid h d ch
            in  (acts <> [se], eventDigest (event se), ch')
        (apps, hd, a2) = foldl step ([], gid, a1) ds
    pure
        Scene
            { scStart = [a0, b]
            , scSetup = g : apps
            , scMember = a2
            , scOther = b
            , scGroup = gid
            , scHead = hd
            }

-- | Hosted KELs of these member KEL fixtures, no group.
hostedOf :: [Chain] -> Hosted
hostedOf chs =
    Hosted
        { hostedKels = Map.fromList [(chPrefix c, kelOf c) | c <- chs]
        , hostedChains = Map.empty
        }
  where
    kelOf c = case chEvents c of
        e : es -> either (error . show) id (replayKel e es)
        [] -> error "empty KEL fixture"

-- | Admit actions one after the other.
admitAll :: Hosted -> [SignedEvent] -> Either GroupRefusal Hosted
admitAll = foldM (\h se -> fst <$> admit h se)

-- | The state the scene's setup reaches; a refusal fails the property.
withScene :: Scene -> (Hosted -> Property) -> Property
withScene Scene{..} k = case admitAll (hostedOf scStart) scSetup of
    Left r -> counterexample ("setup refused: " <> show r) False
    Right h -> k h

admitted :: Either GroupRefusal (Hosted, Admission) -> Property
admitted = \case
    Right _ -> property True
    Left r -> counterexample ("refused: " <> show r) False

refusedWith
    :: GroupRefusal -> Either GroupRefusal (Hosted, Admission) -> Property
refusedWith r x = fmap snd x === Left r

notAGroupAction :: Either GroupRefusal a -> Bool
notAGroupAction = \case
    Left (NotAGroupAction _) -> True
    _ -> False

-- | A digest of the member's KEL that is no group and no head.
inceptionDigest :: Chain -> Text
inceptionDigest ch = case chEvents ch of
    e : _ -> eventDigest (event e)
    [] -> error "empty KEL fixture"

-- | Replace the single anchor of an interaction.
withAnchor :: (Value -> Value) -> SignedEvent -> SignedEvent
withAnchor f se =
    se
        { event =
            mapInteraction
                (\InteractionData{..} -> InteractionData{anchors = map f anchors, ..})
                (event se)
        }

-- | Set a key of a JSON object.
setKey :: Text -> Value -> Value -> Value
setKey k v = \case
    Object o -> Object (KM.insert (Key.fromText k) v o)
    other -> other

spec :: Spec
spec = describe "KelGroups.Group (admission rule)" $
    modifyMaxSuccess (const 25) $ do
        prop
            "INV-39-GENESIS: a genesis by a hosted signer is admitted; \
            \group id = head = its d; roster = the signer as sole member \
            \and admin"
            $ forAll ((,) <$> genMember <*> genMember)
            $ \(a0, b) ->
                let (g, a1) = genesisOf a0
                    d = eventDigest (event g)
                    h0 = hostedOf [a0, b]
                in  case admit h0 g of
                        Left r -> counterexample (show r) False
                        Right (h1, adm) ->
                            let ch = Map.lookup d (hostedChains h1)
                            in  conjoin
                                    [ adm
                                        === Admission
                                            { admittedGroup = d
                                            , admittedHead = d
                                            , admittedPrefix = chPrefix a0
                                            , admittedSn = eventSequenceNumber (event g)
                                            }
                                    , Map.keys (hostedChains h1) === [d]
                                    , fmap Group.head ch === Just d
                                    , fmap roster ch
                                        === Just
                                            Roster
                                                { members = [chPrefix a0]
                                                , admins = [chPrefix a0]
                                                }
                                    , fmap (map Group.signed . chainActions) ch
                                        === Just [g]
                                    , fmap kelEvents (Map.lookup (chPrefix a0) (hostedKels h1))
                                        === Just (chEvents a1)
                                    , Map.lookup (chPrefix b) (hostedKels h1)
                                        === Map.lookup (chPrefix b) (hostedKels h0)
                                    ]

        prop
            "INV-39-REGENESIS: a genesis whose group id already has a \
            \chain is refused at the pure rule"
            $ forAll ((,) <$> genMember <*> genMember)
            $ \(a0, b) ->
                let (g, _) = genesisOf a0
                    h0 = hostedOf [a0, b]
                in  case admit h0 g of
                        Left r -> counterexample ("control refused: " <> show r) False
                        Right (h1, _) ->
                            -- the chain exists, the KEL is back before the genesis:
                            -- only the chain condition can refuse
                            refusedWith GroupExists $
                                admit h1{hostedKels = hostedKels h0} g

        prop
            "INV-39-MEMBER: an action by a hosted non-member with \
            \correct p and prev is refused"
            $ forAll ((,) <$> genScene <*> genAppData)
            $ \(sc@Scene{..}, d) -> withScene sc $ \h ->
                let (byOther, _) = appOf scGroup scHead d scOther
                    (byMember, _) = appOf scGroup scHead d scMember
                in  conjoin
                        [ refusedWith NotAMember (admit h byOther)
                        , admitted (admit h byMember)
                        ]

        prop
            "INV-39-LINK/rule: a correctly signed action with p not the \
            \signer's tip, prev not the head, or a group id with no chain \
            \is refused"
            $ forAll ((,) <$> genScene <*> genAppData)
            $ \(sc@Scene{..}, d) -> withScene sc $ \h ->
                let stale = inceptionDigest scMember
                    staleP =
                        signAll (F.ksPairs (chCurrent scMember)) $
                            anchoredOf
                                (chPrefix scMember)
                                (chSn scMember + 1)
                                stale
                                [appAnchor scGroup scHead d]
                    (staleHead, _) = appOf scGroup stale d scMember
                    (noGroup, _) = appOf stale scHead d scMember
                    (legit, _) = appOf scGroup scHead d scMember
                in  conjoin
                        [ refusedWith (KelRefused NotTipSuccessor) (admit h staleP)
                        , refusedWith PrevNotHead (admit h staleHead)
                        , refusedWith NoSuchGroup (admit h noGroup)
                        , admitted (admit h legit)
                        ]

        prop
            "INV-39-TAMPER/rule: a signed action with group id, payload, \
            \p or prev altered is refused, d as signed or recomputed"
            $ forAll ((,) <$> genScene <*> genAppData)
            $ \(sc@Scene{..}, d) -> withScene sc $ \h ->
                let (legit, _) = appOf scGroup scHead d scMember
                    elsewhere = inceptionDigest scMember
                    tampered = object ["tampered" .= True]
                    alterations =
                        [ ("group id", withAnchor (setKey "group" (String elsewhere)))
                        ,
                            ( "payload"
                            , withAnchor (setKey "payload" (appPayload tampered))
                            )
                        , ("prev", withAnchor (setKey "prev" (String elsewhere)))
                        ,
                            ( "p"
                            , \se ->
                                se
                                    { event =
                                        mapInteraction
                                            ( \InteractionData{..} ->
                                                InteractionData{priorDigest = elsewhere, ..}
                                            )
                                            (event se)
                                    }
                            )
                        ]
                    asSigned f = f legit
                    recomputed f = let se = f legit in se{event = resaid (event se)}
                    expectRecomputed = \case
                        "p" -> KelRefused NotTipSuccessor
                        _ -> KelRefused InvalidSignatures
                in  conjoin $
                        admitted (admit h legit)
                            : concat
                                [ [ counterexample (what <> ", d as signed") $
                                        refusedWith (KelRefused SaidMismatch) $
                                            admit h (asSigned f)
                                  , counterexample (what <> ", d recomputed") $
                                        refusedWith (expectRecomputed what) $
                                            admit h (recomputed f)
                                  ]
                                | (what, f) <- alterations
                                ]

        prop
            "INV-39-SHAPE: an ixn whose a is not exactly one well-formed \
            \anchor is not a group action; a non-ixn is refused as such"
            $ forAll ((,,) <$> genScene <*> genAppData <*> genKeySet)
            $ \(sc@Scene{..}, d, n1) -> withScene sc $ \h ->
                let app = appAnchor scGroup scHead d
                    genesisWith kvs =
                        object $
                            ("payload" .= object ["t" .= ("genesis" :: Text)]) : kvs
                    shapes =
                        [ ("no anchor", [])
                        , ("two anchors", [app, app])
                        , ("two geneses", [genesisAnchor, genesisAnchor])
                        , ("anchor not an object", [String scGroup])
                        , ("extra anchor key", [setKey "x" (Number 1) app])
                        ,
                            ( "extra payload key"
                            , [setKey "payload" (setKey "x" (Number 1) (appPayload d)) app]
                            )
                        ,
                            ( "unknown payload tag"
                            ,
                                [ setKey
                                    "payload"
                                    (object ["t" .= ("promote" :: Text), "member" .= chPrefix scOther])
                                    app
                                ]
                            )
                        ,
                            ( "app payload without data"
                            , [setKey "payload" (object ["t" .= ("app" :: Text)]) app]
                            )
                        , ("genesis with group", [genesisWith ["group" .= scGroup]])
                        , ("genesis with prev", [genesisWith ["prev" .= scHead]])
                        ,
                            ( "genesis with group and prev"
                            , [genesisWith ["group" .= scGroup, "prev" .= scHead]]
                            )
                        ,
                            ( "app without prev"
                            , [object ["group" .= scGroup, "payload" .= appPayload d]]
                            )
                        ,
                            ( "app without group"
                            , [object ["prev" .= scHead, "payload" .= appPayload d]]
                            )
                        , ("group not a string", [setKey "group" (Number 1) app])
                        ]
                    (rot, _) = rotateChain n1 scMember
                    fresh = case chEvents scOther of
                        e : _ -> e
                        [] -> error "empty KEL fixture"
                in  conjoin $
                        [ counterexample what $
                            property $
                                notAGroupAction (admit h (fst (actWith as scMember)))
                        | (what, as) <- shapes
                        ]
                            <> [ refusedWith (KelRefused (UnexpectedEventKind Rot)) (admit h rot)
                               , refusedWith (KelRefused (UnexpectedEventKind Icp)) (admit h fresh)
                               , admitted (admit h (fst (actWith [app] scMember)))
                               ]
