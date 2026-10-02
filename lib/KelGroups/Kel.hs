{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : KelGroups.Kel
Description : Member KELs and the KERI rule on append
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

A member KEL is the key event log of one member identifier,
hosted by the server. This module is pure: it holds the KEL
type and the KERI rule every appended event must satisfy
(the Lean model's abstract @icpOk@ and @rotOk@).

* The event's @d@ is its SAID; an inception's @i@ is its @d@
  and its @s@ is 0.
* Rotations and interactions extend the tip: @i@ is the KEL
  prefix, @p@ the tip digest, @s@ the tip's @s@ + 1.
* Pre-rotation is mandatory: inception and rotation commit to
  next keys (@n@ non-empty, 1 <= @nt@ <= |@n@|), with
  1 <= @kt@ <= |@k@|, and a rotation's @k@ reveals exactly the
  previous establishment event's commitment.
* Signatures are indexed into the controlling keys and verified
  over the keri-hs canonical serialization: an inception and a
  rotation by their own @k@ (a rotation also meets the prior
  @nt@ over the same revealed keys), an interaction by the
  current keys.
* No witnesses.

Built on keri-hs event types, serialization, SAID and
pre-rotation primitives; @Keri.Kel.Append@ is not used, as it
checks a rotation against the prior keys and does not require a
next-key commitment.
-}
module KelGroups.Kel
    ( MemberKel
    , KelRefusal (..)
    , kelPrefix
    , kelEvents
    , host
    , rotate
    , appendInteraction
    , replayKel
    , tip
    , currentKeys
    ) where

import Control.Monad (foldM, unless, when)
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.List (nub)
import Data.Sequence (Seq, (|>))
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Keri.Cesr.Decode qualified as Cesr
import Keri.Cesr.DerivationCode (DerivationCode (..))
import Keri.Cesr.Encode qualified as Cesr
import Keri.Cesr.Primitive (Primitive (..))
import Keri.Crypto.Ed25519 qualified as Ed25519
import Keri.Crypto.SAID (verifySaid)
import Keri.Event
    ( Event (..)
    , EventType
    , InceptionData (..)
    , InteractionData (..)
    , RotationData (..)
    , eventType
    )
import Keri.Event.Serialize (serializeEvent)
import Keri.Kel (SignedEvent (..))
import Keri.KeyState.PreRotation (verifyCommitment)

{- | A hosted member KEL: non-empty, oldest event first, every
event accepted by the rule against the events before it.
Built only by 'host' and extended only by 'rotate' and
'appendInteraction'.
-}
data MemberKel = MemberKel
    { kelPrefix :: Text
    -- ^ The identifier: the SAID of the inception
    , kelLog :: Seq SignedEvent
    , kelTip :: Text
    , kelSn :: Int
    , kelKeys :: [Text]
    , kelThreshold :: Int
    , kelNextKeys :: [Text]
    , kelNextThreshold :: Int
    }
    deriving stock (Show, Eq)

-- | Why an event is refused. A refused event changes nothing.
data KelRefusal
    = -- | Not the event kind this append accepts
      UnexpectedEventKind EventType
    | -- | @d@ is not the SAID of the event
      SaidMismatch
    | -- | An inception whose @i@ is not its @d@
      PrefixNotSaid
    | -- | An inception whose @s@ is not 0
      InceptionNotFirst
    | -- | No next-key commitment: @n@ empty or @nt@ 0
      MissingNextCommitment
    | -- | @kt@ or @nt@ outside 1 .. number of keys
      ThresholdOutOfRange
    | -- | Witnesses or a witness threshold
      WitnessesPresent
    | -- | @i@ is not the prefix of the KEL it extends
      ForeignPrefix
    | -- | @p@ is not the tip digest or @s@ not the tip's @s@ + 1
      NotTipSuccessor
    | -- | A rotation's @k@ is not the committed next keys
      CommitmentNotRevealed
    | -- | Signatures invalid or under the threshold
      InvalidSignatures
    | -- | An inception of a hosted prefix
      AlreadyHosted
    | -- | A rotation for a prefix that is not hosted
      Unhosted
    deriving stock (Show, Eq)

-- | The signed events of the KEL, oldest first.
kelEvents :: MemberKel -> [SignedEvent]
kelEvents = toList . kelLog

-- | Lean @tip@: the digest of the last event.
tip :: MemberKel -> Text
tip = kelTip

-- | The controlling keys and signing threshold.
currentKeys :: MemberKel -> ([Text], Int)
currentKeys kel = (kelKeys kel, kelThreshold kel)

-- | Lean @host@: a new KEL from a valid inception.
host :: SignedEvent -> Either KelRefusal MemberKel
host se@SignedEvent{event, signatures} = case event of
    Inception InceptionData{..} -> do
        unless (verifySaid event) $ Left SaidMismatch
        unless (prefix == digest) $ Left PrefixNotSaid
        unless (sequenceNumber == 0) $ Left InceptionNotFirst
        establishment
            keys
            signingThreshold
            nextKeys
            nextThreshold
            (witnessThreshold == 0 && null witnesses)
        unless
            ( signaturesMeet
                keys
                signingThreshold
                (serializeEvent event)
                signatures
            )
            $ Left InvalidSignatures
        pure
            MemberKel
                { kelPrefix = prefix
                , kelLog = Seq.singleton se
                , kelTip = digest
                , kelSn = 0
                , kelKeys = keys
                , kelThreshold = signingThreshold
                , kelNextKeys = nextKeys
                , kelNextThreshold = nextThreshold
                }
    other -> Left (UnexpectedEventKind (eventType other))

-- | Lean @rotate@: append a valid rotation extending the tip.
rotate :: MemberKel -> SignedEvent -> Either KelRefusal MemberKel
rotate kel se@SignedEvent{event, signatures} = case event of
    Rotation RotationData{..} -> do
        unless (verifySaid event) $ Left SaidMismatch
        extendsTip kel prefix priorDigest sequenceNumber
        establishment
            keys
            signingThreshold
            nextKeys
            nextThreshold
            ( witnessThreshold == 0
                && null witnessesAdded
                && null witnessesRemoved
            )
        unless (reveals (kelNextKeys kel) keys) $
            Left CommitmentNotRevealed
        let msg = serializeEvent event
        unless
            ( signaturesMeet keys signingThreshold msg signatures
                && signaturesMeet keys (kelNextThreshold kel) msg signatures
            )
            $ Left InvalidSignatures
        pure
            kel
                { kelLog = kelLog kel |> se
                , kelTip = digest
                , kelSn = sequenceNumber
                , kelKeys = keys
                , kelThreshold = signingThreshold
                , kelNextKeys = nextKeys
                , kelNextThreshold = nextThreshold
                }
    other -> Left (UnexpectedEventKind (eventType other))

-- | Append a valid interaction, signed by the current keys.
appendInteraction
    :: MemberKel -> SignedEvent -> Either KelRefusal MemberKel
appendInteraction kel se@SignedEvent{event, signatures} =
    case event of
        Interaction InteractionData{..} -> do
            unless (verifySaid event) $ Left SaidMismatch
            extendsTip kel prefix priorDigest sequenceNumber
            unless
                ( signaturesMeet
                    (kelKeys kel)
                    (kelThreshold kel)
                    (serializeEvent event)
                    signatures
                )
                $ Left InvalidSignatures
            pure
                kel
                    { kelLog = kelLog kel |> se
                    , kelTip = digest
                    , kelSn = sequenceNumber
                    }
        other -> Left (UnexpectedEventKind (eventType other))

{- | Rebuild a KEL from its inception and the events after it,
applying the rule to each.
-}
replayKel
    :: SignedEvent -> [SignedEvent] -> Either KelRefusal MemberKel
replayKel first rest = host first >>= \kel -> foldM extend kel rest
  where
    extend kel se = case event se of
        Rotation{} -> rotate kel se
        Interaction{} -> appendInteraction kel se
        other -> Left (UnexpectedEventKind (eventType other))

-- --------------------------------------------------------
-- Rule clauses
-- --------------------------------------------------------

-- | @i@, @p@ and @s@ extend the KEL tip.
extendsTip :: MemberKel -> Text -> Text -> Int -> Either KelRefusal ()
extendsTip kel prefix prior sn = do
    unless (prefix == kelPrefix kel) $ Left ForeignPrefix
    unless (prior == kelTip kel && sn == kelSn kel + 1) $
        Left NotTipSuccessor

-- | Thresholds, mandatory next-key commitment, no witnesses.
establishment
    :: [Text] -> Int -> [Text] -> Int -> Bool -> Either KelRefusal ()
establishment keys kt next nt noWitnesses = do
    when (null next || nt < 1) $ Left MissingNextCommitment
    unless (kt >= 1 && kt <= length keys && nt <= length next) $
        Left ThresholdOutOfRange
    unless noWitnesses $ Left WitnessesPresent

-- | The revealed keys are exactly the committed ones, in order.
reveals :: [Text] -> [Text] -> Bool
reveals commitments revealed =
    length commitments == length revealed
        && and (zipWith committed revealed commitments)
  where
    committed k c = verifyCommitment k c == Right True

{- | Every signature is a canonical Ed25519 signature at a
distinct index of a canonical Ed25519 key and verifies over the
message, and there are at least @threshold@ of them.
-}
signaturesMeet
    :: [Text] -> Int -> ByteString -> [(Int, Text)] -> Bool
signaturesMeet keys threshold msg sigs =
    length sigs >= threshold
        && length (nub (map fst sigs)) == length sigs
        && all valid sigs
  where
    valid (i, sig)
        | i < 0 || i >= length keys = False
        | otherwise = case (canonical Ed25519PubKey (keys !! i), canonical Ed25519Sig sig) of
            (Just k, Just s) -> case Ed25519.publicKeyFromBytes k of
                Right pk -> Ed25519.verify pk msg s
                Left _ -> False
            _ -> False

-- | The raw bytes of a primitive of this code, in canonical CESR.
canonical :: DerivationCode -> Text -> Maybe ByteString
canonical c t = case Cesr.decode t of
    Right p@Primitive{code, raw}
        | code == c && Cesr.encode p == t -> Just raw
    _ -> Nothing
