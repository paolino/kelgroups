-- | Legitimately signed member KELs and group actions for the client
-- | checks: real Ed25519 keys (tweetnacl, from generated seeds), real
-- | next-key commitments, events built with the keri-purs constructors
-- | and signed over their canonical serialization. Variants that break
-- | one rule change one field, recompute the SAID and sign again, so
-- | every other rule still holds.
-- |
-- | Anchors are written here from the wire form of the server module
-- | header (`KelGroups.Group`), independently of the client's encoder.
module Test.Fixtures
  ( Keys
  , Ident
  , genKeys
  , genKeysN
  , pubKey
  , commit
  , signWith
  , signIdx
  , incept
  , inceptN
  , rotate
  , interact
  , resaid
  , withEvent
  , lastEvent
  , genesisAnchor
  , actionAnchor
  , addP
  , removeP
  , grantP
  , revokeP
  , leaveP
  , appP
  , digestOf
  , snOf
  , signer
  ) where

import Prelude

import Data.Argonaut.Core (Json, fromObject, fromString)
import Data.Array as Array
import Data.ArrayBuffer.Types (Uint8Array)
import Data.Either (fromRight)
import Data.Maybe (fromMaybe)
import Data.Tuple (Tuple(..))
import FFI.KeyBytes (fromArray, fromSeed)
import FFI.TextEncoder (encodeUtf8)
import FFI.TweetNaCl (KeyPair)
import FFI.TweetNaCl as NaCl
import Foreign.Object as Object
import Keri.Cesr.DerivationCode (DerivationCode(..))
import Keri.Cesr.Encode as Cesr
import Keri.Crypto.Digest (computeSaid, saidPlaceholder)
import Keri.Event (Event(..), eventDigest, eventSequenceNumber)
import Keri.Event.Inception (mkInception)
import Keri.Event.Interaction (mkInteraction)
import Keri.Event.Rotation (mkRotation)
import Keri.Event.Serialize (serializeEvent)
import Keri.Kel (SignedEvent)
import Keri.KeyState.PreRotation (commitKey)
import Test.QuickCheck.Gen (Gen, chooseInt, vectorOf)

-- | Key pairs and their signing threshold.
type Keys = { pairs :: Array KeyPair, threshold :: Int }

-- | An identity: its KEL so far and the keys that control it.
type Ident =
  { prefix :: String
  , events :: Array SignedEvent
  , sn :: Int
  , tip :: String
  , current :: Keys
  , next :: Keys
  }

genPair :: Gen KeyPair
genPair = fromSeed <<< fromArray <$> vectorOf 32 (chooseInt 0 255)

-- | One key, threshold 1.
genKeys :: Gen Keys
genKeys = genKeysN 1 1

-- | `n` keys with threshold `t`.
genKeysN :: Int -> Int -> Gen Keys
genKeysN n t = { pairs: _, threshold: t } <$> vectorOf n genPair

-- | The CESR form of a public key.
pubKey :: KeyPair -> String
pubKey kp = Cesr.encode { code: Ed25519PubKey, raw: kp.publicKey }

-- | The next-key commitment to a key.
commit :: KeyPair -> String
commit kp = fromRight "" (commitKey (pubKey kp))

sigOf :: Uint8Array -> Event -> String
sigOf sk e =
  Cesr.encode
    { code: Ed25519Sig, raw: NaCl.sign (encodeUtf8 (serializeEvent e)) sk }

-- | Sign with every pair, index = position.
signWith :: Array KeyPair -> Event -> SignedEvent
signWith pairs e =
  { event: e
  , signatures: Array.mapWithIndex
      (\i kp -> { index: i, signature: sigOf kp.secretKey e })
      pairs
  }

-- | Sign with chosen indices and pairs.
signIdx :: Array (Tuple Int KeyPair) -> Event -> SignedEvent
signIdx ips e =
  { event: e
  , signatures: map
      (\(Tuple i kp) -> { index: i, signature: sigOf kp.secretKey e })
      ips
  }

-- | A KEL holding only its inception.
incept :: Keys -> Keys -> Ident
incept = inceptN identity

-- | An inception, its fields changed before the SAID is computed.
inceptN :: (Event -> Event) -> Keys -> Keys -> Ident
inceptN f cur nxt =
  let
    e = resaid $ f $ mkInception
      { keys: map pubKey cur.pairs
      , signingThreshold: cur.threshold
      , nextKeys: map commit nxt.pairs
      , nextThreshold: nxt.threshold
      , config: []
      , anchors: []
      }
    se = signWith cur.pairs e
  in
    { prefix: eventDigest e
    , events: [ se ]
    , sn: 0
    , tip: eventDigest e
    , current: cur
    , next: nxt
    }

-- | Rotate to the committed keys, committing to `nxt`.
rotate :: Keys -> Ident -> Tuple SignedEvent Ident
rotate nxt id =
  let
    revealed = id.next
    e = mkRotation
      { prefix: id.prefix
      , sequenceNumber: id.sn + 1
      , priorDigest: id.tip
      , keys: map pubKey revealed.pairs
      , signingThreshold: revealed.threshold
      , nextKeys: map commit nxt.pairs
      , nextThreshold: nxt.threshold
      , config: []
      , anchors: []
      }
    se = signWith revealed.pairs e
  in
    Tuple se (withEvent se id) { current = revealed, next = nxt }

-- | Interact with these anchors, signed by the current keys.
interact :: Array Json -> Ident -> Tuple SignedEvent Ident
interact anchors id =
  let
    e = mkInteraction
      { prefix: id.prefix
      , sequenceNumber: id.sn + 1
      , priorDigest: id.tip
      , anchors
      }
    se = signWith id.current.pairs e
  in
    Tuple se (withEvent se id)

-- | Append a signed event as the new tip.
withEvent :: SignedEvent -> Ident -> Ident
withEvent se id =
  id
    { events = Array.snoc id.events se
    , sn = eventSequenceNumber se.event
    , tip = eventDigest se.event
    }

-- | The last event of an identity's KEL.
lastEvent :: Ident -> SignedEvent
lastEvent id = fromMaybe
  ( signWith []
      ( Receipt
          { version: "", digest: "", prefix: "", sequenceNumber: 0 }
      )
  )
  (Array.last id.events)

-- | Recompute `d` (and an inception's `i` when it was the SAID) over the
-- | event as it stands.
resaid :: Event -> Event
resaid = case _ of
  Inception d ->
    let
      self = d.prefix == d.digest
      ph = d { digest = saidPlaceholder, prefix = saidPlaceholder }
      said = computeSaid (serializeEvent (Inception ph))
    in
      Inception d { digest = said, prefix = if self then said else d.prefix }
  Rotation d ->
    Rotation d
      { digest = computeSaid
          (serializeEvent (Rotation d { digest = saidPlaceholder }))
      }
  Interaction d ->
    Interaction d
      { digest = computeSaid
          (serializeEvent (Interaction d { digest = saidPlaceholder }))
      }
  other -> other

obj :: Array (Tuple String Json) -> Json
obj = fromObject <<< Object.fromFoldable

-- | `{"payload": {"t": "genesis"}}`
genesisAnchor :: Json
genesisAnchor = obj [ Tuple "payload" (obj [ Tuple "t" (fromString "genesis") ]) ]

-- | `{"group": g, "payload": pl, "prev": h}`
actionAnchor :: String -> String -> Json -> Json
actionAnchor g h pl =
  obj [ Tuple "group" (fromString g), Tuple "payload" pl, Tuple "prev" (fromString h) ]

memberP :: String -> String -> Json
memberP t x = obj [ Tuple "member" (fromString x), Tuple "t" (fromString t) ]

addP :: String -> Json
addP = memberP "add"

removeP :: String -> Json
removeP = memberP "remove"

grantP :: String -> Json
grantP = memberP "grant"

revokeP :: String -> Json
revokeP = memberP "revoke"

leaveP :: Json
leaveP = obj [ Tuple "t" (fromString "leave") ]

appP :: Json -> Json
appP d = obj [ Tuple "data" d, Tuple "t" (fromString "app") ]

digestOf :: SignedEvent -> String
digestOf se = eventDigest se.event

snOf :: SignedEvent -> Int
snOf se = eventSequenceNumber se.event

-- | The prefix of an identity.
signer :: Ident -> String
signer id = id.prefix
