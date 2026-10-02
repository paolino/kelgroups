-- | Member KELs as the client holds them: the wire form of a signed
-- | event (as `KelGroups.Kel.Codec` on the server) and the KERI rule of
-- | `KelGroups.Kel`, re-checked locally on every fetched KEL.
-- |
-- | A `ValidatedKel` is built only here, by `validateKel` from a whole
-- | KEL or by `extendKel` from a validated KEL and the events after its
-- | tip. Every event it holds was accepted by the rule against the
-- | events before it:
-- |
-- | * `d` is the SAID of the event; an inception's `i` is its `d` and
-- |   its `s` is 0;
-- | * a later event extends the tip: `i` is the prefix, `p` the tip
-- |   digest, `s` the tip's `s` + 1;
-- | * inception and rotation commit to next keys (`n` non-empty,
-- |   1 <= `nt` <= |`n`|) with 1 <= `kt` <= |`k`|, and a rotation's `k`
-- |   reveals exactly the previous commitment;
-- | * signatures are canonical Ed25519 signatures at distinct indices of
-- |   canonical Ed25519 keys, valid over the canonical serialization, at
-- |   least the threshold of them: an inception and a rotation by their
-- |   own keys (a rotation also meets the prior `nt`), an interaction by
-- |   the current keys;
-- | * no witnesses.
-- |
-- | Events missing before an event (its `s` past the tip's successor
-- | and its `p` not the tip) are a `Gap` naming that `p`.
module KelGroups.Client.Kel
  ( Prefix
  , Digest
  , SyncRefusal(..)
  , ValidatedKel
  , kelPrefix
  , kelEvents
  , kelTip
  , kelSn
  , kelKeys
  , kelThreshold
  , validateKel
  , extendKel
  , decodeSignedEvent
  , encodeSignedEvent
  , wireBytes
  ) where

import Prelude

import Control.Monad.Rec.Class (Step(..), tailRec)
import Data.Argonaut.Core
  ( Json
  , fromArray
  , fromNumber
  , fromObject
  , fromString
  , jsonNull
  , stringify
  , toArray
  , toNumber
  , toObject
  , toString
  )
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.ArrayBuffer.Types (Uint8Array)
import Data.Either (Either(..), either, note)
import Data.Int as Int
import Data.Maybe (Maybe(..), isJust)
import Data.String as String
import Data.String.CodeUnits (toCharArray)
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import FFI.TextEncoder (encodeUtf8)
import FFI.TweetNaCl as NaCl
import Foreign.Object (Object)
import Foreign.Object as Object
import Keri.Cesr.Decode as CesrDecode
import Keri.Cesr.DerivationCode (DerivationCode(..), totalLength)
import Keri.Cesr.Encode as CesrEncode
import Keri.Crypto.Digest (computeSaid, saidPlaceholder)
import Keri.Event (Event(..), eventDigest, eventPrefix, eventSequenceNumber)
import Keri.Event.Serialize (serializeEvent)
import Keri.Event.Version (intToHex)
import Keri.Kel (SignedEvent)
import Keri.KeyState.PreRotation (verifyCommitment)

-- | A member identifier: the SAID of its inception.
type Prefix = String

-- | The digest (SAID) of an event.
type Digest = String

-- | Why a sync produced no view. Nothing is signed or sent after one.
data SyncRefusal
  = KelInvalid { prefix :: Prefix, s :: Int, reason :: String }
  | Gap { missing :: Digest }
  | NotOnLine { digest :: Digest }
  | RuleViolation { digest :: Digest, class :: String }
  | HistoryRewritten { prefix :: Prefix, s :: Int }
  | NotSigner { prefix :: Prefix }
  | Transport { status :: Int, detail :: String }

derive instance eqSyncRefusal :: Eq SyncRefusal

instance showSyncRefusal :: Show SyncRefusal where
  show = case _ of
    KelInvalid r -> "KelInvalid " <> show r
    Gap r -> "Gap " <> show r
    NotOnLine r -> "NotOnLine " <> show r
    RuleViolation r -> "RuleViolation " <> show r
    HistoryRewritten r -> "HistoryRewritten " <> show r
    NotSigner r -> "NotSigner " <> show r
    Transport r -> "Transport " <> show r

-- | A member KEL accepted by the KERI rule, oldest event first.
newtype ValidatedKel = ValidatedKel
  { prefix :: Prefix
  , events :: Array SignedEvent
  , tip :: Digest
  , sn :: Int
  , keys :: Array String
  , threshold :: Int
  , nextKeys :: Array String
  , nextThreshold :: Int
  }

instance eqValidatedKel :: Eq ValidatedKel where
  eq (ValidatedKel a) (ValidatedKel b) =
    a.prefix == b.prefix
      && a.tip == b.tip
      && a.sn == b.sn
      && a.keys == b.keys
      && a.threshold == b.threshold
      && a.nextKeys == b.nextKeys
      && a.nextThreshold == b.nextThreshold
      && map wireBytes a.events == map wireBytes b.events

instance showValidatedKel :: Show ValidatedKel where
  show (ValidatedKel k) =
    "ValidatedKel " <> k.prefix <> " s=" <> show k.sn <> " tip=" <> k.tip

kelPrefix :: ValidatedKel -> Prefix
kelPrefix (ValidatedKel k) = k.prefix

-- | The signed events, oldest first.
kelEvents :: ValidatedKel -> Array SignedEvent
kelEvents (ValidatedKel k) = k.events

-- | Lean `tip`: the digest of the last event.
kelTip :: ValidatedKel -> Digest
kelTip (ValidatedKel k) = k.tip

-- | The `s` of the tip.
kelSn :: ValidatedKel -> Int
kelSn (ValidatedKel k) = k.sn

-- | The controlling keys.
kelKeys :: ValidatedKel -> Array String
kelKeys (ValidatedKel k) = k.keys

-- | The signing threshold of the controlling keys.
kelThreshold :: ValidatedKel -> Int
kelThreshold (ValidatedKel k) = k.threshold

-- | Validate a whole KEL, inception first.
validateKel :: Array SignedEvent -> Either SyncRefusal ValidatedKel
validateKel events = case Array.uncons events of
  Nothing -> Left (KelInvalid { prefix: "", s: 0, reason: "empty" })
  Just { head, tail } -> host head >>= \kel -> appendAll kel tail
  where
  appendAll kel rest = tailRec go { kel, i: 0 }
    where
    go { kel: k, i } = case Array.index rest i of
      Nothing -> Done (Right k)
      Just se -> case appendEvent k se of
        Left r -> Done (Left r)
        Right k' -> Loop { kel: k', i: i + 1 }

-- | Extend a validated KEL with the events after its tip. Any event
-- | that does not extend it or breaks the rule refuses the whole
-- | suffix as `HistoryRewritten`; the validated KEL is unchanged.
extendKel :: ValidatedKel -> Array SignedEvent -> Either SyncRefusal ValidatedKel
extendKel kel suffix = tailRec go { k: kel, i: 0 }
  where
  go { k, i } = case Array.index suffix i of
    Nothing -> Done (Right k)
    Just se -> case appendEvent k se of
      Left _ ->
        Done $ Left $ HistoryRewritten
          { prefix: kelPrefix kel, s: eventSequenceNumber se.event }
      Right k' -> Loop { k: k', i: i + 1 }

-- --------------------------------------------------------
-- The KERI rule
-- --------------------------------------------------------

-- | Lean `host`: a KEL from a valid inception. A first event that is
-- | not an inception but sits past `s` 0 is a gap: the events before
-- | it, the inception included, are missing.
host :: SignedEvent -> Either SyncRefusal ValidatedKel
host se = case se.event of
  Inception d -> do
    let refuse = invalid d.prefix d.sequenceNumber
    unless (saidOk se.event) $ refuse "saidMismatch"
    unless (d.prefix == d.digest) $ refuse "prefixNotSaid"
    unless (d.sequenceNumber == 0) $ refuse "inceptionNotFirst"
    establishment refuse d.keys d.signingThreshold d.nextKeys d.nextThreshold
      (d.witnessThreshold == 0 && Array.null d.witnesses)
    unless (signaturesMeet d.keys d.signingThreshold (serializeEvent se.event) se.signatures)
      $ refuse "invalidSignatures"
    pure $ ValidatedKel
      { prefix: d.prefix
      , events: [ se ]
      , tip: d.digest
      , sn: 0
      , keys: d.keys
      , threshold: d.signingThreshold
      , nextKeys: d.nextKeys
      , nextThreshold: d.nextThreshold
      }
  Rotation d | d.sequenceNumber > 0 -> Left (Gap { missing: d.priorDigest })
  Interaction d | d.sequenceNumber > 0 -> Left (Gap { missing: d.priorDigest })
  other -> invalid (eventPrefix other) (eventSequenceNumber other) "unexpectedEventKind"

-- | Append a rotation (Lean `rotate`) or an interaction, signed by the
-- | current keys.
appendEvent :: ValidatedKel -> SignedEvent -> Either SyncRefusal ValidatedKel
appendEvent kel@(ValidatedKel k) se = case se.event of
  Rotation d -> do
    let refuse = invalid k.prefix d.sequenceNumber
    unless (saidOk se.event) $ refuse "saidMismatch"
    extendsTip kel refuse d.prefix d.priorDigest d.sequenceNumber
    establishment refuse d.keys d.signingThreshold d.nextKeys d.nextThreshold
      ( d.witnessThreshold == 0
          && Array.null d.witnessesAdded
          && Array.null d.witnessesRemoved
      )
    unless (reveals k.nextKeys d.keys) $ refuse "commitmentNotRevealed"
    let msg = serializeEvent se.event
    unless
      ( signaturesMeet d.keys d.signingThreshold msg se.signatures
          && signaturesMeet d.keys k.nextThreshold msg se.signatures
      )
      $ refuse "invalidSignatures"
    pure $ ValidatedKel k
      { events = Array.snoc k.events se
      , tip = d.digest
      , sn = d.sequenceNumber
      , keys = d.keys
      , threshold = d.signingThreshold
      , nextKeys = d.nextKeys
      , nextThreshold = d.nextThreshold
      }
  Interaction d -> do
    let refuse = invalid k.prefix d.sequenceNumber
    unless (saidOk se.event) $ refuse "saidMismatch"
    extendsTip kel refuse d.prefix d.priorDigest d.sequenceNumber
    unless (signaturesMeet k.keys k.threshold (serializeEvent se.event) se.signatures)
      $ refuse "invalidSignatures"
    pure $ ValidatedKel k
      { events = Array.snoc k.events se
      , tip = d.digest
      , sn = d.sequenceNumber
      }
  other -> invalid k.prefix (eventSequenceNumber other) "unexpectedEventKind"

invalid :: forall a. Prefix -> Int -> String -> Either SyncRefusal a
invalid prefix s reason = Left (KelInvalid { prefix, s, reason })

-- | `i`, `p` and `s` extend the tip; events missing before this one
-- | (its `s` past the successor, its `p` not the tip) are a gap.
extendsTip
  :: ValidatedKel
  -> (String -> Either SyncRefusal Unit)
  -> Prefix
  -> Digest
  -> Int
  -> Either SyncRefusal Unit
extendsTip (ValidatedKel k) refuse prefix prior s = do
  unless (prefix == k.prefix) $ refuse "foreignPrefix"
  when (prior /= k.tip && s > k.sn + 1) $ Left (Gap { missing: prior })
  unless (prior == k.tip && s == k.sn + 1) $ refuse "notTipSuccessor"

-- | Thresholds, mandatory next-key commitment, no witnesses.
establishment
  :: (String -> Either SyncRefusal Unit)
  -> Array String
  -> Int
  -> Array String
  -> Int
  -> Boolean
  -> Either SyncRefusal Unit
establishment refuse keys kt next nt noWitnesses = do
  when (Array.null next || nt < 1) $ refuse "missingNextCommitment"
  unless (kt >= 1 && kt <= Array.length keys && nt <= Array.length next)
    $ refuse "thresholdOutOfRange"
  unless noWitnesses $ refuse "witnessesPresent"

-- | The revealed keys are exactly the committed ones, in order.
reveals :: Array String -> Array String -> Boolean
reveals commitments revealed =
  Array.length commitments == Array.length revealed
    && Array.all identity (Array.zipWith committed revealed commitments)
  where
  committed key c = isJust (canonical Ed25519PubKey key) && verifyCommitment key c

-- | `d` is the SAID of the event: recomputed with `d` (and an
-- | inception's `i`) set to the placeholder.
saidOk :: Event -> Boolean
saidOk e = computeSaid (serializeEvent (placeholder e)) == eventDigest e
  where
  placeholder = case _ of
    Inception d -> Inception d { digest = saidPlaceholder, prefix = saidPlaceholder }
    Rotation d -> Rotation d { digest = saidPlaceholder }
    Interaction d -> Interaction d { digest = saidPlaceholder }
    Receipt d -> Receipt d { digest = saidPlaceholder }

-- | Every signature is a canonical Ed25519 signature at a distinct
-- | index of a canonical Ed25519 key and verifies over the message, and
-- | there are at least `threshold` of them.
signaturesMeet
  :: Array String -> Int -> String -> Array { index :: Int, signature :: String } -> Boolean
signaturesMeet keys threshold msg sigs =
  Array.length sigs >= threshold
    && Array.length (Array.nub (map _.index sigs)) == Array.length sigs
    && Array.all valid sigs
  where
  bytes = encodeUtf8 msg
  valid { index, signature } = case Array.index keys index of
    Nothing -> false
    Just key -> case canonical Ed25519PubKey key, canonical Ed25519Sig signature of
      Just k, Just s -> NaCl.verify bytes s k
      _, _ -> false

-- | The raw bytes of a primitive of this code in canonical CESR.
canonical :: DerivationCode -> String -> Maybe Uint8Array
canonical code t
  | String.length t /= totalLength code = Nothing
  | not (Array.all base64url (toCharArray t)) = Nothing
  | otherwise = case CesrDecode.decode t of
      Right p | p.code == code && CesrEncode.encode p == t -> Just p.raw
      _ -> Nothing

base64url :: Char -> Boolean
base64url c =
  (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
    || c == '-'
    || c == '_'

-- --------------------------------------------------------
-- Wire form
-- --------------------------------------------------------

-- | Decode the wire form of a signed event,
-- | `{"event": <KERI event>, "signatures": [{"index": i, "signature": s}]}`,
-- | accepting only the labels keri-hs serializes for each kind, `s` in
-- | canonical hexadecimal and the thresholds in canonical decimal.
decodeSignedEvent :: Json -> Either String SignedEvent
decodeSignedEvent json = do
  o <- object "signed event" json
  exactKeys "signed event" [ "event", "signatures" ] o
  event <- field o "event" >>= decodeEvent
  sigs <- field o "signatures" >>= array "signatures" >>= traverse signature
  pure { event, signatures: sigs }
  where
  signature j = do
    o <- object "signature" j
    exactKeys "signature" [ "index", "signature" ] o
    index <- field o "index" >>= nonNegative
    sig <- field o "signature" >>= string "signature"
    pure { index, signature: sig }
  nonNegative j = do
    n <- note "index: not a number" (toNumber j)
    i <- note "index: not an integer" (Int.fromNumber n)
    if i >= 0 then pure i else Left "negative signature index"

decodeEvent :: Json -> Either String Event
decodeEvent json = do
  o <- object "KERI event" json
  t <- field o "t" >>= string "t"
  let
    str k = field o k >>= string k
    strs k = field o k >>= array k >>= traverse (string k)
    hex k = str k >>= \v -> note (k <> ": not canonical hexadecimal") (canonicalHex v)
    dec k = str k >>= \v -> note (k <> ": not canonical decimal") (canonicalDec v)
  case t of
    "icp" -> do
      exactKeys "icp" [ "v", "t", "d", "i", "s", "kt", "k", "nt", "n", "bt", "b", "c", "a" ] o
      version <- str "v"
      digest <- str "d"
      prefix <- str "i"
      sequenceNumber <- hex "s"
      signingThreshold <- dec "kt"
      keys <- strs "k"
      nextThreshold <- dec "nt"
      nextKeys <- strs "n"
      witnessThreshold <- dec "bt"
      witnesses <- strs "b"
      config <- strs "c"
      anchors <- field o "a" >>= array "a"
      pure $ Inception
        { version, digest, prefix, sequenceNumber, signingThreshold, keys, nextThreshold, nextKeys, witnessThreshold, witnesses, config, anchors }
    "rot" -> do
      exactKeys "rot" [ "v", "t", "d", "i", "s", "p", "kt", "k", "nt", "n", "bt", "ba", "br", "c", "a" ] o
      version <- str "v"
      digest <- str "d"
      prefix <- str "i"
      sequenceNumber <- hex "s"
      priorDigest <- str "p"
      signingThreshold <- dec "kt"
      keys <- strs "k"
      nextThreshold <- dec "nt"
      nextKeys <- strs "n"
      witnessThreshold <- dec "bt"
      witnessesRemoved <- strs "br"
      witnessesAdded <- strs "ba"
      config <- strs "c"
      anchors <- field o "a" >>= array "a"
      pure $ Rotation
        { version, digest, prefix, sequenceNumber, priorDigest, signingThreshold, keys, nextThreshold, nextKeys, witnessThreshold, witnessesRemoved, witnessesAdded, config, anchors }
    "ixn" -> do
      exactKeys "ixn" [ "v", "t", "d", "i", "s", "p", "a" ] o
      version <- str "v"
      digest <- str "d"
      prefix <- str "i"
      sequenceNumber <- hex "s"
      priorDigest <- str "p"
      anchors <- field o "a" >>= array "a"
      pure $ Interaction { version, digest, prefix, sequenceNumber, priorDigest, anchors }
    "rct" -> do
      exactKeys "rct" [ "v", "t", "d", "i", "s" ] o
      version <- str "v"
      digest <- str "d"
      prefix <- str "i"
      sequenceNumber <- hex "s"
      pure $ Receipt { version, digest, prefix, sequenceNumber }
    other -> Left ("unknown event type " <> show other)

-- | The wire form of a signed event: the event in its canonical form.
encodeSignedEvent :: SignedEvent -> Json
encodeSignedEvent se =
  fromObject $ Object.fromFoldable
    [ Tuple "event" (either (const jsonNull) identity (jsonParser (serializeEvent se.event)))
    , Tuple "signatures" (signaturesJson se.signatures)
    ]

signaturesJson :: Array { index :: Int, signature :: String } -> Json
signaturesJson = fromArray <<< map \s ->
  fromObject $ Object.fromFoldable
    [ Tuple "index" (fromNumber (Int.toNumber s.index))
    , Tuple "signature" (fromString s.signature)
    ]

-- | The canonical bytes of a signed event: its serialization and its
-- | signatures, as a string that two equal events share.
wireBytes :: SignedEvent -> String
wireBytes se = serializeEvent se.event <> stringify (signaturesJson se.signatures)

object :: String -> Json -> Either String (Object Json)
object what = note (what <> ": not an object") <<< toObject

array :: String -> Json -> Either String (Array Json)
array what = note (what <> ": not an array") <<< toArray

string :: String -> Json -> Either String String
string what = note (what <> ": not a string") <<< toString

field :: Object Json -> String -> Either String Json
field o k = note ("missing " <> k) (Object.lookup k o)

-- | The object has exactly these labels.
exactKeys :: String -> Array String -> Object Json -> Either String Unit
exactKeys what labels o =
  unless (Array.sort (Object.keys o) == Array.sort labels)
    $ Left (what <> ": fields must be exactly " <> show labels)

canonicalHex :: String -> Maybe Int
canonicalHex t = do
  n <- Int.fromStringAs Int.hexadecimal t
  if n >= 0 && intToHex n == t then Just n else Nothing

canonicalDec :: String -> Maybe Int
canonicalDec t = do
  n <- Int.fromString t
  if n >= 0 && show n == t then Just n else Nothing
