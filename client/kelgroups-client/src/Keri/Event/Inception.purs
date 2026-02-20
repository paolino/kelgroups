module Keri.Event.Inception
  ( InceptionConfig
  , mkInception
  ) where

import Data.Argonaut.Core (Json)
import Data.String as String
import Keri.Crypto.Digest (computeSaid, saidPlaceholder)
import Keri.Event (Event(..), InceptionData)
import Keri.Event.Serialize (serializeEvent)
import Keri.Event.Version (mkVersion, versionPlaceholder)

type InceptionConfig =
  { keys :: Array String
  , signingThreshold :: Int
  , nextKeys :: Array String
  , nextThreshold :: Int
  , config :: Array String
  , anchors :: Array Json
  }

-- | Create an inception event with computed SAID and version.
-- The prefix equals the SAID (self-addressing).
mkInception :: InceptionConfig -> Event
mkInception cfg = Inception finalData
  where
  placeholder :: InceptionData
  placeholder =
    { version: versionPlaceholder
    , digest: saidPlaceholder
    , prefix: saidPlaceholder
    , sequenceNumber: 0
    , signingThreshold: cfg.signingThreshold
    , keys: cfg.keys
    , nextThreshold: cfg.nextThreshold
    , nextKeys: cfg.nextKeys
    , witnessThreshold: 0
    , witnesses: []
    , config: cfg.config
    , anchors: cfg.anchors
    }

  size0 = String.length (serializeEvent (Inception placeholder))

  realVersion = mkVersion size0

  withVersion = placeholder { version = realVersion }

  saidJson = serializeEvent (Inception withVersion)

  said = computeSaid saidJson

  finalData = withVersion { digest = said, prefix = said }
