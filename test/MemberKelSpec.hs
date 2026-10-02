{-# LANGUAGE RecordWildCards #-}

{- |
Module      : MemberKelSpec
Description : The KERI rule on member KEL append, and its wire form
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

Pure checks of 'KelGroups.Kel' (Lean @host@, @rotate@, @tip@)
and of the JSON codec of signed events. Every event is built
with keri-hs constructors and signed with real Ed25519 keys;
every refused variant breaks exactly one rule.
-}
module MemberKelSpec (spec) where

import Control.Monad (foldM)
import Data.Aeson (Value (..), decodeStrict)
import Data.Aeson.Encoding (encodingToLazyByteString)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import KelGroups.Kel
    ( KelRefusal (..)
    , MemberKel
    , appendInteraction
    , currentKeys
    , host
    , kelEvents
    , kelPrefix
    , replayKel
    , rotate
    , tip
    )
import KelGroups.Kel.Codec (decodeSignedEvent, encodeSignedEvent)
import Keri.Crypto.Digest (computeSaid)
import Keri.Event
    ( Event (..)
    , EventType (..)
    , InceptionData (..)
    , InteractionData (..)
    , RotationData (..)
    , eventDigest
    )
import Keri.Event.Serialize (serializeEvent)
import Keri.Kel (SignedEvent (..))
import MemberKelFixtures
    ( Chain (..)
    , KeySet (..)
    , genChain
    , genKeyPair
    , genKeySet
    , genKeySetSized
    , inceptionOf
    , interactChain
    , interactionOf
    , mapInception
    , mapInteraction
    , mapRotation
    , pubKey
    , resaid
    , rotateChain
    , rotationOf
    , sigOf
    , signAll
    , signIdx
    , startChain
    )
import Test.Hspec (Spec, describe)
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
    ( Gen
    , Property
    , chooseInt
    , conjoin
    , counterexample
    , forAll
    , property
    , (.&&.)
    , (===)
    )

-- | Host the first event, then append the rest by kind.
build :: [SignedEvent] -> Either KelRefusal MemberKel
build [] = error "build: empty KEL"
build (e : es) = host e >>= \k -> foldM extend k es
  where
    extend k se = case event se of
        Rotation{} -> rotate k se
        _ -> appendInteraction k se

-- | The legitimate KEL of a chain, which must be accepted.
kelOf :: Chain -> MemberKel
kelOf ch =
    either (error . ("kelOf: refused " <>) . show) id $
        build (chEvents ch)

accepted :: Either KelRefusal MemberKel -> Property
accepted =
    either
        (\r -> counterexample ("refused: " <> show r) False)
        (const (property True))

-- | A refusal of exactly this class.
refusedAs
    :: KelRefusal -> Either KelRefusal MemberKel -> Property
refusedAs r got =
    counterexample ("expected refusal " <> show r) $
        either (=== r) (const (property False)) got

-- | A next state to rotate to, and a key nobody committed to.
genRotationInputs :: Gen (Chain, KeySet, KeySet)
genRotationInputs = (,,) <$> genChain <*> genKeySet <*> genKeySet

otherSaid :: Text
otherSaid = computeSaid "not the event"

spec :: Spec
spec = describe "KelGroups.Kel (KERI rule on append)" $ do
    prop
        "legitimately built KELs are accepted event by event; \
        \tip is the last digest, current keys the last establishment's"
        $ forAll genChain
        $ \ch -> case build (chEvents ch) of
            Left r -> counterexample ("refused: " <> show r) False
            Right kel ->
                conjoin
                    [ kelEvents kel === chEvents ch
                    , tip kel === chTip ch
                    , kelPrefix kel === chPrefix ch
                    , currentKeys kel
                        === ( map pubKey (ksPairs (chCurrent ch))
                            , ksThreshold (chCurrent ch)
                            )
                    , replayKel (head' (chEvents ch)) (drop 1 (chEvents ch))
                        === Right kel
                    ]

    prop
        "INV-38-ICP-NEXT/rule: an inception without a next-key \
        \commitment (n empty or nt 0) is refused"
        $ forAll ((,) <$> genKeySet <*> genKeySet)
        $ \(cur, next) ->
            let icp = inceptionOf cur next
                variant f =
                    host . signAll (ksPairs cur) . resaid $
                        mapInception f icp
            in  conjoin
                    [ accepted (host (signAll (ksPairs cur) icp))
                    , refusedAs MissingNextCommitment $
                        variant $
                            \InceptionData{..} ->
                                InceptionData{nextKeys = [], ..}
                    , refusedAs MissingNextCommitment $
                        variant $
                            \InceptionData{..} ->
                                InceptionData{nextThreshold = 0, ..}
                    , refusedAs MissingNextCommitment $
                        variant $
                            \InceptionData{..} ->
                                InceptionData
                                    { nextKeys = []
                                    , nextThreshold = 0
                                    , ..
                                    }
                    ]

    prop
        "INV-38-ROT-REVEAL/rule: a rotation whose keys do not match \
        \the prior commitment (wrong key, wrong count, wrong order) \
        \is refused"
        $ forAll ((,) <$> genRotationInputs <*> genKeyPair)
        $ \((ch, next', _), stranger) ->
            let kel = kelOf ch
                revealed = chNext ch
                rot ks =
                    signAll (ksPairs ks) $
                        rotationOf
                            (chPrefix ch)
                            (chSn ch + 1)
                            (chTip ch)
                            ks
                            next'
                n = length (ksPairs revealed)
                wrongAt i =
                    revealed
                        { ksPairs =
                            [ if j == i then stranger else kp
                            | (j, kp) <- zip [0 :: Int ..] (ksPairs revealed)
                            ]
                        }
                extraKey =
                    revealed{ksPairs = ksPairs revealed <> [stranger]}
                fewerKeys =
                    KeySet
                        { ksPairs = take (n - 1) (ksPairs revealed)
                        , ksThreshold = min (ksThreshold revealed) (n - 1)
                        }
                reordered =
                    revealed{ksPairs = reverse (ksPairs revealed)}
            in  conjoin $
                    [ accepted (rotate kel (fst (rotateChain next' ch)))
                    , refusedAs CommitmentNotRevealed $
                        rotate kel (rot extraKey)
                    ]
                        <> [ counterexample ("stranger at index " <> show i) $
                                refusedAs CommitmentNotRevealed $
                                    rotate kel (rot (wrongAt i))
                           | i <- [0 .. n - 1]
                           ]
                        <> [ refusedAs CommitmentNotRevealed $
                                rotate kel (rot fewerKeys)
                           | n >= 2
                           ]
                        <> [ refusedAs CommitmentNotRevealed $
                                rotate kel (rot reordered)
                           | n >= 2
                           ]

    prop
        "INV-38-OLD-KEY/rule: after an accepted rotation, events \
        \signed with the superseded keys are refused"
        $ forAll genRotationInputs
        $ \(ch, n1, n2) ->
            let old = chCurrent ch
                (rotSe, ch1) = rotateChain n1 ch
                kel1 = kelOf ch1
                sn = chSn ch1 + 1
                ixnEvt = interactionOf (chPrefix ch1) sn (chTip ch1)
                rotNext = rotationOf (chPrefix ch1) sn (chTip ch1) n1 n2
                rotOld = rotationOf (chPrefix ch1) sn (chTip ch1) old n2
            in  conjoin
                    [ accepted (rotate (kelOf ch) rotSe)
                    , accepted
                        (appendInteraction kel1 (fst (interactChain ch1)))
                    , refusedAs InvalidSignatures $
                        appendInteraction kel1 $
                            signAll (ksPairs old) ixnEvt
                    , refusedAs InvalidSignatures $
                        rotate kel1 (signAll (ksPairs old) rotNext)
                    , refusedAs CommitmentNotRevealed $
                        rotate kel1 (signAll (ksPairs old) rotOld)
                    ]

    prop
        "INV-38-ROT-SIGNER: a rotation signed by the prior current \
        \keys instead of the revealed keys is refused"
        $ forAll genRotationInputs
        $ \(ch, n1, _) ->
            let kel = kelOf ch
                evt =
                    rotationOf
                        (chPrefix ch)
                        (chSn ch + 1)
                        (chTip ch)
                        (chNext ch)
                        n1
            in  accepted (rotate kel (signAll (ksPairs (chNext ch)) evt))
                    .&&. refusedAs
                        InvalidSignatures
                        (rotate kel (signAll (ksPairs (chCurrent ch)) evt))

    prop
        "INV-38-ROT-NEXT: a rotation without a next-key commitment \
        \(n empty or nt 0) is refused"
        $ forAll genRotationInputs
        $ \(ch, n1, _) ->
            let kel = kelOf ch
                revealed = ksPairs (chNext ch)
                evt =
                    rotationOf
                        (chPrefix ch)
                        (chSn ch + 1)
                        (chTip ch)
                        (chNext ch)
                        n1
                variant f =
                    rotate kel . signAll revealed . resaid $
                        mapRotation f evt
            in  conjoin
                    [ accepted (rotate kel (signAll revealed evt))
                    , refusedAs MissingNextCommitment $
                        variant $
                            \RotationData{..} ->
                                RotationData{nextKeys = [], ..}
                    , refusedAs MissingNextCommitment $
                        variant $
                            \RotationData{..} ->
                                RotationData{nextThreshold = 0, ..}
                    ]

    prop
        "INV-38-SAID: an event whose d is not its SAID, or an \
        \inception whose i is not d, is refused"
        $ forAll ((,) <$> genRotationInputs <*> genKeySet)
        $ \((ch, n1, _), stranger) ->
            let cur0 = stranger
                icp = inceptionOf stranger n1
                kel = kelOf ch
                revealed = ksPairs (chNext ch)
                rotEvt =
                    rotationOf
                        (chPrefix ch)
                        (chSn ch + 1)
                        (chTip ch)
                        (chNext ch)
                        n1
                ixnEvt =
                    interactionOf (chPrefix ch) (chSn ch + 1) (chTip ch)
                curNow = ksPairs (chCurrent ch)
                icpBadD =
                    mapInception
                        ( \InceptionData{..} ->
                            InceptionData
                                { digest = otherSaid
                                , prefix = otherSaid
                                , ..
                                }
                        )
                        icp
                icpBodyChanged =
                    mapInception
                        ( \InceptionData{..} ->
                            InceptionData{config = ["changed"], ..}
                        )
                        icp
                icpForeignI =
                    mapInception
                        ( \InceptionData{..} ->
                            InceptionData
                                { prefix =
                                    eventDigest
                                        (inceptionOf n1 stranger)
                                , ..
                                }
                        )
                        icp
                rotBadD =
                    mapRotation
                        (\RotationData{..} -> RotationData{digest = otherSaid, ..})
                        rotEvt
                ixnBadD =
                    mapInteraction
                        ( \InteractionData{..} ->
                            InteractionData{digest = otherSaid, ..}
                        )
                        ixnEvt
            in  conjoin
                    [ accepted (host (signAll (ksPairs cur0) icp))
                    , refusedAs SaidMismatch $
                        host (signAll (ksPairs cur0) icpBadD)
                    , refusedAs SaidMismatch $
                        host (signAll (ksPairs cur0) icpBodyChanged)
                    , refusedAs PrefixNotSaid $
                        host (signAll (ksPairs cur0) icpForeignI)
                    , accepted (rotate kel (signAll revealed rotEvt))
                    , refusedAs SaidMismatch $
                        rotate kel (signAll revealed rotBadD)
                    , accepted (appendInteraction kel (signAll curNow ixnEvt))
                    , refusedAs SaidMismatch $
                        appendInteraction kel (signAll curNow ixnBadD)
                    ]

    prop
        "INV-38-SIG: missing, wrong-key, under-threshold, duplicated, \
        \out-of-range, malformed or altered-event signatures are refused"
        $ forAll
            ( (,,,)
                <$> (chooseInt (2, 3) >>= genKeySetSized)
                <*> genKeySet
                <*> genKeyPair
                <*> genKeySet
            )
        $ \(cur', next, stranger, n1) ->
            let cur = cur'{ksThreshold = length (ksPairs cur')}
                kps = ksPairs cur
                kt = ksThreshold cur
                icp = inceptionOf cur next
                icpAltered =
                    resaid $
                        mapInception
                            ( \InceptionData{..} ->
                                InceptionData{config = ["altered"], ..}
                            )
                            icp
                withSigs sigs = SignedEvent{event = icp, signatures = sigs}
                good = signatures (signAll kps icp)
                k0 = head' kps
                ch = snd (interactChain (startChain cur next))
                kel = kelOf ch
                ixnEvt = interactionOf (chPrefix ch) (chSn ch + 1) (chTip ch)
                rotEvt =
                    rotationOf (chPrefix ch) (chSn ch + 1) (chTip ch) next n1
                rotAltered =
                    resaid $
                        mapRotation
                            (\RotationData{..} -> RotationData{config = ["x"], ..})
                            rotEvt
            in  conjoin
                    [ accepted (host (withSigs good))
                    , refusedAs InvalidSignatures $ host (withSigs [])
                    , refusedAs InvalidSignatures $
                        host (withSigs ((0, sigOf stranger icp) : drop 1 good))
                    , refusedAs InvalidSignatures $
                        host (withSigs (take (kt - 1) good))
                    , refusedAs InvalidSignatures $
                        host (withSigs (replicate kt (0, sigOf k0 icp)))
                    , refusedAs InvalidSignatures $
                        host (withSigs (good <> [(length kps, sigOf k0 icp)]))
                    , refusedAs InvalidSignatures $
                        host
                            ( withSigs
                                [(i, s <> "AAAA") | (i, s) <- good]
                            )
                    , refusedAs InvalidSignatures $
                        host SignedEvent{event = icpAltered, signatures = good}
                    , accepted (appendInteraction kel (signAll kps ixnEvt))
                    , refusedAs InvalidSignatures $
                        appendInteraction kel $
                            signIdx (take (kt - 1) (zip [0 ..] kps)) ixnEvt
                    , accepted (rotate kel (signAll (ksPairs next) rotEvt))
                    , refusedAs InvalidSignatures $
                        rotate
                            kel
                            SignedEvent
                                { event = rotAltered
                                , signatures =
                                    signatures (signAll (ksPairs next) rotEvt)
                                }
                    ]

    prop
        "INV-38-SIG: a rotation meeting its own kt but under the prior \
        \nt is refused"
        $ forAll
            ( (,,)
                <$> genKeySet
                <*> (chooseInt (2, 3) >>= genKeySetSized)
                <*> genKeySet
            )
        $ \(cur, next', n1) ->
            let next = next'{ksThreshold = length (ksPairs next')}
                ch = startChain cur next
                kel = kelOf ch
                -- the revealed keys, with their own threshold lowered to 1
                revealed = next{ksThreshold = 1}
                evt =
                    rotationOf
                        (chPrefix ch)
                        (chSn ch + 1)
                        (chTip ch)
                        revealed
                        n1
                kps = ksPairs next
            in  accepted (rotate kel (signAll kps evt))
                    .&&. refusedAs
                        InvalidSignatures
                        ( rotate kel $
                            signIdx (take (length kps - 1) (zip [0 ..] kps)) evt
                        )

    prop
        "INV-38-TIP: a rotation or interaction whose p is not the tip \
        \digest, whose s is not the tip's s + 1, or whose i is foreign \
        \is refused"
        $ forAll ((,) <$> genRotationInputs <*> genChain)
        $ \((ch0, n1, _), other) ->
            let ch = snd (interactChain ch0)
                kel = kelOf ch
                nonTip = [eventDigest (event e) | e <- init (chEvents ch)]
                sn = chSn ch + 1
                pfx = chPrefix ch
                revealed = ksPairs (chNext ch)
                curNow = ksPairs (chCurrent ch)
                rot p s i = signAll revealed (rotationOf i s p (chNext ch) n1)
                ixn p s i = signAll curNow (interactionOf i s p)
            in  conjoin
                    [ accepted (rotate kel (rot (chTip ch) sn pfx))
                    , refusedAs NotTipSuccessor $
                        rotate kel (rot otherSaid sn pfx)
                    , refusedAs NotTipSuccessor $
                        rotate kel (rot (chTip ch) (sn - 1) pfx)
                    , refusedAs NotTipSuccessor $
                        rotate kel (rot (chTip ch) (sn + 1) pfx)
                    , refusedAs ForeignPrefix $
                        rotate kel (rot (chTip ch) sn (chPrefix other))
                    , accepted (appendInteraction kel (ixn (chTip ch) sn pfx))
                    , refusedAs NotTipSuccessor $
                        appendInteraction kel (ixn otherSaid sn pfx)
                    , refusedAs NotTipSuccessor $
                        appendInteraction kel (ixn (chTip ch) (sn + 1) pfx)
                    , refusedAs ForeignPrefix $
                        appendInteraction kel (ixn (chTip ch) sn (chPrefix other))
                    ]
                    .&&. conjoin
                        ( concat
                            [ [ counterexample ("non-tip p " <> show p) $
                                    refusedAs NotTipSuccessor $
                                        rotate kel (rot p sn pfx)
                              , counterexample ("non-tip p " <> show p) $
                                    refusedAs NotTipSuccessor $
                                        appendInteraction kel (ixn p sn pfx)
                              ]
                            | p <- nonTip
                            ]
                        )
                    .&&. counterexample "no non-tip event" (not (null nonTip))

    prop
        "R3c R3f: an inception with s not 0, a threshold out of range \
        \or witnesses is refused"
        $ forAll ((,) <$> genKeySet <*> genKeySet)
        $ \(cur, next) ->
            let icp = inceptionOf cur next
                variant f =
                    host . signAll (ksPairs cur) . resaid $
                        mapInception f icp
            in  conjoin
                    [ accepted (host (signAll (ksPairs cur) icp))
                    , refusedAs InceptionNotFirst $
                        variant $
                            \InceptionData{..} ->
                                InceptionData{sequenceNumber = 1, ..}
                    , refusedAs ThresholdOutOfRange $
                        variant $
                            \InceptionData{..} ->
                                InceptionData{signingThreshold = 0, ..}
                    , refusedAs ThresholdOutOfRange $
                        variant $
                            \InceptionData{..} ->
                                InceptionData
                                    { signingThreshold = length keys + 1
                                    , ..
                                    }
                    , refusedAs ThresholdOutOfRange $
                        variant $
                            \InceptionData{..} ->
                                InceptionData
                                    { nextThreshold = length nextKeys + 1
                                    , ..
                                    }
                    , refusedAs WitnessesPresent $
                        variant $
                            \InceptionData{..} ->
                                InceptionData{witnesses = [pubKey' cur], ..}
                    , refusedAs WitnessesPresent $
                        variant $
                            \InceptionData{..} ->
                                InceptionData{witnessThreshold = 1, ..}
                    ]

    prop
        "R3c R3f: a rotation with a threshold out of range or witnesses \
        \is refused"
        $ forAll genRotationInputs
        $ \(ch, n1, _) ->
            let kel = kelOf ch
                revealed = ksPairs (chNext ch)
                evt =
                    rotationOf
                        (chPrefix ch)
                        (chSn ch + 1)
                        (chTip ch)
                        (chNext ch)
                        n1
                variant f =
                    rotate kel . signAll revealed . resaid $
                        mapRotation f evt
                w = pubKey (head' revealed)
            in  conjoin
                    [ accepted (rotate kel (signAll revealed evt))
                    , refusedAs ThresholdOutOfRange $
                        variant $
                            \RotationData{..} ->
                                RotationData{signingThreshold = 0, ..}
                    , refusedAs ThresholdOutOfRange $
                        variant $
                            \RotationData{..} ->
                                RotationData
                                    { signingThreshold = length keys + 1
                                    , ..
                                    }
                    , refusedAs ThresholdOutOfRange $
                        variant $
                            \RotationData{..} ->
                                RotationData
                                    { nextThreshold = length nextKeys + 1
                                    , ..
                                    }
                    , refusedAs WitnessesPresent $
                        variant $
                            \RotationData{..} ->
                                RotationData{witnessThreshold = 1, ..}
                    , refusedAs WitnessesPresent $
                        variant $
                            \RotationData{..} ->
                                RotationData{witnessesAdded = [w], ..}
                    , refusedAs WitnessesPresent $
                        variant $
                            \RotationData{..} ->
                                RotationData{witnessesRemoved = [w], ..}
                    ]

    prop "each append function refuses the other event kinds" $
        forAll genRotationInputs $ \(ch, n1, _) ->
            let kel = kelOf ch
                (rotSe, _) = rotateChain n1 ch
                (ixnSe, _) = interactChain ch
                icpSe = head' (chEvents ch)
            in  conjoin
                    [ refusedAs (UnexpectedEventKind Rot) (host rotSe)
                    , refusedAs (UnexpectedEventKind Ixn) (host ixnSe)
                    , refusedAs (UnexpectedEventKind Ixn) (rotate kel ixnSe)
                    , refusedAs (UnexpectedEventKind Icp) (rotate kel icpSe)
                    , refusedAs
                        (UnexpectedEventKind Rot)
                        (appendInteraction kel rotSe)
                    , refusedAs
                        (UnexpectedEventKind Icp)
                        (appendInteraction kel icpSe)
                    ]

    describe "wire form (data model D5)" $ do
        prop "decoding the encoding of a signed event gives it back" $
            forAll genChain $ \ch ->
                conjoin
                    [ decodeSignedEvent (toValue se) === Right se
                    | se <- chEvents ch
                    ]
        prop "the event of the wire form is its canonical serialization" $
            forAll genChain $ \ch ->
                conjoin
                    [ BS.isPrefixOf
                        ("{\"event\":" <> serializeEvent (event se))
                        (LBS.toStrict (encoded se))
                        === True
                    | se <- chEvents ch
                    ]
        prop
            "non-canonical numbers, unknown fields and unknown kinds \
            \are not decodable"
            $ forAll genChain
            $ \ch ->
                let se = head' (chEvents ch)
                    evtObj = case decodeStrict (serializeEvent (event se)) of
                        Just (Object o) -> o
                        _ -> error "event is not an object"
                    sigsVal = case toValue se of
                        Object o -> fromMaybe Null (KM.lookup "signatures" o)
                        _ -> Null
                    wire o =
                        Object $
                            KM.fromList
                                [("event", Object o), ("signatures", sigsVal)]
                    undecodable o =
                        either
                            (const (property True))
                            (const (counterexample (show o) False))
                            (decodeSignedEvent (wire o))
                in  conjoin
                        [ decodeSignedEvent (wire evtObj) === Right se
                        , undecodable (KM.insert "s" (String "00") evtObj)
                        , undecodable (KM.insert "kt" (Number 1) evtObj)
                        , undecodable (KM.insert "x" (String "y") evtObj)
                        , undecodable (KM.insert "s" (String "-1") evtObj)
                        , undecodable
                            (KM.insert "s" (String "ffffffffffffffffffffffff") evtObj)
                        , undecodable (KM.insert "kt" (String "-1") evtObj)
                        , undecodable
                            (KM.insert "kt" (String "99999999999999999999999") evtObj)
                        , undecodable (KM.delete "n" evtObj)
                        , undecodable (KM.insert "t" (String "dip") evtObj)
                        ]
  where
    head' = \case
        (x : _) -> x
        [] -> error "empty list"
    pubKey' = pubKey . head' . ksPairs
    encoded = encodingToLazyByteString . encodeSignedEvent
    toValue se = case decodeStrict (LBS.toStrict (encoded se)) of
        Just v -> v
        Nothing -> error "wire form is not JSON"
