module Keri.Event.Rotation
  ( RotationConfig
  , mkRotation
  ) where

import Data.Argonaut.Core (Json)
import Data.String as String
import Keri.Crypto.Digest (computeSaid, saidPlaceholder)
import Keri.Event (Event(..), RotationData)
import Keri.Event.Serialize (serializeEvent)
import Keri.Event.Version (mkVersion, versionPlaceholder)

type RotationConfig =
  { prefix :: String
  , sequenceNumber :: Int
  , priorDigest :: String
  , keys :: Array String
  , signingThreshold :: Int
  , nextKeys :: Array String
  , nextThreshold :: Int
  , config :: Array String
  , anchors :: Array Json
  }

mkRotation :: RotationConfig -> Event
mkRotation cfg = Rotation finalData
  where
  placeholder :: RotationData
  placeholder =
    { version: versionPlaceholder
    , digest: saidPlaceholder
    , prefix: cfg.prefix
    , sequenceNumber: cfg.sequenceNumber
    , priorDigest: cfg.priorDigest
    , signingThreshold: cfg.signingThreshold
    , keys: cfg.keys
    , nextThreshold: cfg.nextThreshold
    , nextKeys: cfg.nextKeys
    , witnessThreshold: 0
    , witnessesRemoved: []
    , witnessesAdded: []
    , config: cfg.config
    , anchors: cfg.anchors
    }

  size0 = String.length (serializeEvent (Rotation placeholder))
  realVersion = mkVersion size0
  withVersion = placeholder { version = realVersion }
  saidJson = serializeEvent (Rotation withVersion)
  said = computeSaid saidJson
  finalData = withVersion { digest = said }
