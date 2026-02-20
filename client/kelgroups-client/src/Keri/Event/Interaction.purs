module Keri.Event.Interaction
  ( InteractionConfig
  , mkInteraction
  ) where

import Data.Argonaut.Core (Json)
import Data.String as String
import Keri.Crypto.Digest (computeSaid, saidPlaceholder)
import Keri.Event (Event(..), InteractionData)
import Keri.Event.Serialize (serializeEvent)
import Keri.Event.Version (mkVersion, versionPlaceholder)

type InteractionConfig =
  { prefix :: String
  , sequenceNumber :: Int
  , priorDigest :: String
  , anchors :: Array Json
  }

mkInteraction :: InteractionConfig -> Event
mkInteraction cfg = Interaction finalData
  where
  placeholder :: InteractionData
  placeholder =
    { version: versionPlaceholder
    , digest: saidPlaceholder
    , prefix: cfg.prefix
    , sequenceNumber: cfg.sequenceNumber
    , priorDigest: cfg.priorDigest
    , anchors: cfg.anchors
    }

  size0 = String.length (serializeEvent (Interaction placeholder))
  realVersion = mkVersion size0
  withVersion = placeholder { version = realVersion }
  saidJson = serializeEvent (Interaction withVersion)
  said = computeSaid saidJson
  finalData = withVersion { digest = said }
