{-# LANGUAGE RecordWildCards #-}

{- |
Module      : MemberKelFixtures
Description : Legitimately signed member KEL events for tests
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

Builds member KEL events with keri-hs constructors, real
Ed25519 keys and real next-key commitments, and signs them
over their canonical serialization. Variants that break one
rule are built by changing one field and recomputing the
SAID, so every other rule still holds.
-}
module MemberKelFixtures
    ( -- * Keys
      KeySet (..)
    , genKeyPair
    , genKeySet
    , genKeySetSized
    , pubKey
    , commitment

      -- * Events
    , inceptionOf
    , rotationOf
    , interactionOf
    , resaid
    , mapInception
    , mapRotation
    , mapInteraction

      -- * Signing
    , signAll
    , signIdx
    , sigOf

      -- * Chains
    , Chain (..)
    , startChain
    , rotateChain
    , interactChain
    , genChain
    , genRotChain
    , genStep
    , Step (..)
    , applyStep
    ) where

import Crypto.Error (CryptoFailable (..))
import Crypto.PubKey.Ed25519 qualified as Ed
import Data.ByteString qualified as BS
import Data.Text (Text)
import Keri.Cesr.DerivationCode (DerivationCode (..))
import Keri.Cesr.Encode qualified as Cesr
import Keri.Cesr.Primitive (Primitive (..))
import Keri.Crypto.Digest (computeSaid, saidPlaceholder)
import Keri.Crypto.Ed25519 (KeyPair (..))
import Keri.Crypto.Ed25519 qualified as Ed25519
import Keri.Event
    ( Event (..)
    , InceptionData (..)
    , InteractionData (..)
    , ReceiptData (..)
    , RotationData (..)
    , eventDigest
    , eventPrefix
    , eventSequenceNumber
    )
import Keri.Event.Inception (InceptionConfig (..), mkInception)
import Keri.Event.Interaction
    ( InteractionConfig (..)
    , mkInteraction
    )
import Keri.Event.Rotation (RotationConfig (..), mkRotation)
import Keri.Event.Serialize (serializeEvent)
import Keri.Event.Version (mkVersion, versionPlaceholder)
import Keri.Kel (SignedEvent (..))
import Keri.KeyState.PreRotation (commitKey)
import Test.QuickCheck
    ( Gen
    , chooseInt
    , elements
    , listOf
    , resize
    , vectorOf
    )

-- --------------------------------------------------------
-- Keys
-- --------------------------------------------------------

-- | Keys of one establishment event and their threshold.
data KeySet = KeySet
    { ksPairs :: [KeyPair]
    , ksThreshold :: Int
    }
    deriving stock (Show)

-- | A deterministic Ed25519 keypair from generated seed bytes.
genKeyPair :: Gen KeyPair
genKeyPair = do
    seed <- BS.pack <$> vectorOf 32 (fromIntegral <$> chooseInt (0, 255))
    case Ed.secretKey seed of
        CryptoPassed sk ->
            pure KeyPair{secretKey = sk, publicKey = Ed.toPublic sk}
        CryptoFailed e -> error ("genKeyPair: " <> show e)

-- | One to three keys with a threshold in range.
genKeySet :: Gen KeySet
genKeySet = chooseInt (1, 3) >>= genKeySetSized

-- | Exactly @n@ keys with a threshold in range.
genKeySetSized :: Int -> Gen KeySet
genKeySetSized n = do
    kps <- vectorOf n genKeyPair
    kt <- chooseInt (1, n)
    pure KeySet{ksPairs = kps, ksThreshold = kt}

-- | CESR-encoded Ed25519 public key.
pubKey :: KeyPair -> Text
pubKey kp =
    Cesr.encode
        Primitive
            { code = Ed25519PubKey
            , raw = Ed25519.publicKeyBytes (publicKey kp)
            }

-- | keri-hs next-key commitment of a key.
commitment :: KeyPair -> Text
commitment = either error id . commitKey . pubKey

-- --------------------------------------------------------
-- Events
-- --------------------------------------------------------

-- | Inception with current keys and committed next keys.
inceptionOf :: KeySet -> KeySet -> Event
inceptionOf cur next =
    mkInception
        InceptionConfig
            { icKeys = map pubKey (ksPairs cur)
            , icSigningThreshold = ksThreshold cur
            , icNextKeys = map commitment (ksPairs next)
            , icNextThreshold = ksThreshold next
            , icConfig = []
            , icAnchors = []
            }

-- | Rotation revealing @cur@ and committing to @next@.
rotationOf :: Text -> Int -> Text -> KeySet -> KeySet -> Event
rotationOf pfx sn prior cur next =
    mkRotation
        RotationConfig
            { rcPrefix = pfx
            , rcSequenceNumber = sn
            , rcPriorDigest = prior
            , rcKeys = map pubKey (ksPairs cur)
            , rcSigningThreshold = ksThreshold cur
            , rcNextKeys = map commitment (ksPairs next)
            , rcNextThreshold = ksThreshold next
            , rcConfig = []
            , rcAnchors = []
            }

-- | Interaction with no anchors.
interactionOf :: Text -> Int -> Text -> Event
interactionOf pfx sn prior =
    mkInteraction
        InteractionConfig
            { ixPrefix = pfx
            , ixSequenceNumber = sn
            , ixPriorDigest = prior
            , ixAnchors = []
            }

{- | Recompute version size and SAID after a field change, as
the keri-hs constructors do (an inception's prefix is its SAID).
-}
resaid :: Event -> Event
resaid evt = finish (said withVersion)
  where
    blank = setVersion versionPlaceholder (clearDigest evt)
    withVersion =
        setVersion (mkVersion (BS.length (serializeEvent blank))) blank
    said = computeSaid . serializeEvent
    finish d = case withVersion of
        Inception InceptionData{..} ->
            Inception InceptionData{digest = d, prefix = d, ..}
        Rotation RotationData{..} ->
            Rotation RotationData{digest = d, ..}
        Interaction InteractionData{..} ->
            Interaction InteractionData{digest = d, ..}
        Receipt ReceiptData{..} ->
            Receipt ReceiptData{digest = d, ..}
    clearDigest = \case
        Inception InceptionData{..} ->
            Inception
                InceptionData
                    { digest = saidPlaceholder
                    , prefix = saidPlaceholder
                    , ..
                    }
        Rotation RotationData{..} ->
            Rotation RotationData{digest = saidPlaceholder, ..}
        Interaction InteractionData{..} ->
            Interaction InteractionData{digest = saidPlaceholder, ..}
        Receipt ReceiptData{..} ->
            Receipt ReceiptData{digest = saidPlaceholder, ..}
    setVersion v = \case
        Inception InceptionData{..} ->
            Inception InceptionData{version = v, ..}
        Rotation RotationData{..} ->
            Rotation RotationData{version = v, ..}
        Interaction InteractionData{..} ->
            Interaction InteractionData{version = v, ..}
        Receipt ReceiptData{..} ->
            Receipt ReceiptData{version = v, ..}

-- | Change an inception's fields (no SAID recomputation).
mapInception :: (InceptionData -> InceptionData) -> Event -> Event
mapInception f = \case
    Inception d -> Inception (f d)
    e -> e

-- | Change a rotation's fields (no SAID recomputation).
mapRotation :: (RotationData -> RotationData) -> Event -> Event
mapRotation f = \case
    Rotation d -> Rotation (f d)
    e -> e

-- | Change an interaction's fields (no SAID recomputation).
mapInteraction
    :: (InteractionData -> InteractionData) -> Event -> Event
mapInteraction f = \case
    Interaction d -> Interaction (f d)
    e -> e

-- --------------------------------------------------------
-- Signing
-- --------------------------------------------------------

-- | CESR Ed25519 signature over the canonical serialization.
sigOf :: KeyPair -> Event -> Text
sigOf kp evt =
    Cesr.encode
        Primitive
            { code = Ed25519Sig
            , raw = Ed25519.sign kp (serializeEvent evt)
            }

-- | Sign with every key, at its position.
signAll :: [KeyPair] -> Event -> SignedEvent
signAll kps = signIdx (zip [0 ..] kps)

-- | Sign with the given keys at the given indices.
signIdx :: [(Int, KeyPair)] -> Event -> SignedEvent
signIdx iks evt =
    SignedEvent
        { event = evt
        , signatures = [(i, sigOf kp evt) | (i, kp) <- iks]
        }

-- --------------------------------------------------------
-- Chains
-- --------------------------------------------------------

-- | A legitimately built KEL and the controller's key state.
data Chain = Chain
    { chEvents :: [SignedEvent]
    -- ^ oldest first
    , chPrefix :: Text
    , chSn :: Int
    , chTip :: Text
    , chCurrent :: KeySet
    , chNext :: KeySet
    }
    deriving stock (Show)

-- | A KEL holding only its inception.
startChain :: KeySet -> KeySet -> Chain
startChain cur next =
    let evt = inceptionOf cur next
        se = signAll (ksPairs cur) evt
    in  Chain
            { chEvents = [se]
            , chPrefix = eventPrefix evt
            , chSn = eventSequenceNumber evt
            , chTip = eventDigest evt
            , chCurrent = cur
            , chNext = next
            }

-- | Rotate to the committed keys, committing to @next'@.
rotateChain :: KeySet -> Chain -> (SignedEvent, Chain)
rotateChain next' ch =
    let revealed = chNext ch
        evt =
            rotationOf
                (chPrefix ch)
                (chSn ch + 1)
                (chTip ch)
                revealed
                next'
        se = signAll (ksPairs revealed) evt
    in  ( se
        , ch
            { chEvents = chEvents ch <> [se]
            , chSn = chSn ch + 1
            , chTip = eventDigest evt
            , chCurrent = revealed
            , chNext = next'
            }
        )

-- | Interact, signed by the current keys.
interactChain :: Chain -> (SignedEvent, Chain)
interactChain ch =
    let evt = interactionOf (chPrefix ch) (chSn ch + 1) (chTip ch)
        se = signAll (ksPairs (chCurrent ch)) evt
    in  ( se
        , ch
            { chEvents = chEvents ch <> [se]
            , chSn = chSn ch + 1
            , chTip = eventDigest evt
            }
        )

-- | One legitimate step of a controller.
data Step = StepRotate KeySet | StepInteract
    deriving stock (Show)

-- | A generated step.
genStep :: Gen Step
genStep = do
    rot <- elements [True, False]
    if rot then StepRotate <$> genKeySet else pure StepInteract

-- | Apply a step to a chain.
applyStep :: Step -> Chain -> (SignedEvent, Chain)
applyStep = \case
    StepRotate ks -> rotateChain ks
    StepInteract -> interactChain

-- | A legitimate KEL of one to five events.
genChain :: Gen Chain
genChain = do
    ch0 <- startChain <$> genKeySet <*> genKeySet
    steps <- resize 4 (listOf genStep)
    pure $ foldl (\ch s -> snd (applyStep s ch)) ch0 steps

-- | A legitimate KEL of an inception and zero to four rotations.
genRotChain :: Gen Chain
genRotChain = do
    ch0 <- startChain <$> genKeySet <*> genKeySet
    nexts <- resize 4 (listOf genKeySet)
    pure $ foldl (\ch ks -> snd (rotateChain ks ch)) ch0 nexts
