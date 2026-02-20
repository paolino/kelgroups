module Keri.Event.Serialize
  ( serializeEvent
  ) where

import Prelude

import Data.Argonaut.Core (stringify)
import Json.Canonical (jsonStr, jsonArr, jsonObj, kv)
import Keri.Event (Event(..), InceptionData, RotationData, InteractionData, ReceiptData)
import Keri.Event.Version (intToHex)

-- | Serialize an event to canonical JSON string.
-- Field order is protocol-defined and guaranteed.
serializeEvent :: Event -> String
serializeEvent (Inception d) = serializeInception d
serializeEvent (Rotation d) = serializeRotation d
serializeEvent (Interaction d) = serializeInteraction d
serializeEvent (Receipt d) = serializeReceipt d

serializeInception :: InceptionData -> String
serializeInception d = jsonObj
  [ kv "v" (jsonStr d.version)
  , kv "t" (jsonStr "icp")
  , kv "d" (jsonStr d.digest)
  , kv "i" (jsonStr d.prefix)
  , kv "s" (jsonStr (intToHex d.sequenceNumber))
  , kv "kt" (jsonStr (show d.signingThreshold))
  , kv "k" (jsonArr (map jsonStr d.keys))
  , kv "nt" (jsonStr (show d.nextThreshold))
  , kv "n" (jsonArr (map jsonStr d.nextKeys))
  , kv "bt" (jsonStr (show d.witnessThreshold))
  , kv "b" (jsonArr (map jsonStr d.witnesses))
  , kv "c" (jsonArr (map jsonStr d.config))
  , kv "a" (jsonArr (map stringify d.anchors))
  ]

serializeRotation :: RotationData -> String
serializeRotation d = jsonObj
  [ kv "v" (jsonStr d.version)
  , kv "t" (jsonStr "rot")
  , kv "d" (jsonStr d.digest)
  , kv "i" (jsonStr d.prefix)
  , kv "s" (jsonStr (intToHex d.sequenceNumber))
  , kv "p" (jsonStr d.priorDigest)
  , kv "kt" (jsonStr (show d.signingThreshold))
  , kv "k" (jsonArr (map jsonStr d.keys))
  , kv "nt" (jsonStr (show d.nextThreshold))
  , kv "n" (jsonArr (map jsonStr d.nextKeys))
  , kv "bt" (jsonStr (show d.witnessThreshold))
  , kv "br" (jsonArr (map jsonStr d.witnessesRemoved))
  , kv "ba" (jsonArr (map jsonStr d.witnessesAdded))
  , kv "c" (jsonArr (map jsonStr d.config))
  , kv "a" (jsonArr (map stringify d.anchors))
  ]

serializeInteraction :: InteractionData -> String
serializeInteraction d = jsonObj
  [ kv "v" (jsonStr d.version)
  , kv "t" (jsonStr "ixn")
  , kv "d" (jsonStr d.digest)
  , kv "i" (jsonStr d.prefix)
  , kv "s" (jsonStr (intToHex d.sequenceNumber))
  , kv "p" (jsonStr d.priorDigest)
  , kv "a" (jsonArr (map stringify d.anchors))
  ]

serializeReceipt :: ReceiptData -> String
serializeReceipt d = jsonObj
  [ kv "v" (jsonStr d.version)
  , kv "t" (jsonStr "rct")
  , kv "d" (jsonStr d.digest)
  , kv "i" (jsonStr d.prefix)
  , kv "s" (jsonStr (intToHex d.sequenceNumber))
  ]
