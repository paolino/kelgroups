module Keri.Event
  ( Event(..)
  , InceptionData
  , RotationData
  , InteractionData
  , ReceiptData
  , eventDigest
  , eventPrefix
  , eventSequenceNumber
  ) where

import Data.Argonaut.Core (Json)

data Event
  = Inception InceptionData
  | Rotation RotationData
  | Interaction InteractionData
  | Receipt ReceiptData

type InceptionData =
  { version :: String
  , digest :: String
  , prefix :: String
  , sequenceNumber :: Int
  , signingThreshold :: Int
  , keys :: Array String
  , nextThreshold :: Int
  , nextKeys :: Array String
  , witnessThreshold :: Int
  , witnesses :: Array String
  , config :: Array String
  , anchors :: Array Json
  }

type RotationData =
  { version :: String
  , digest :: String
  , prefix :: String
  , sequenceNumber :: Int
  , priorDigest :: String
  , signingThreshold :: Int
  , keys :: Array String
  , nextThreshold :: Int
  , nextKeys :: Array String
  , witnessThreshold :: Int
  , witnessesRemoved :: Array String
  , witnessesAdded :: Array String
  , config :: Array String
  , anchors :: Array Json
  }

type InteractionData =
  { version :: String
  , digest :: String
  , prefix :: String
  , sequenceNumber :: Int
  , priorDigest :: String
  , anchors :: Array Json
  }

type ReceiptData =
  { version :: String
  , digest :: String
  , prefix :: String
  , sequenceNumber :: Int
  }

eventDigest :: Event -> String
eventDigest (Inception d) = d.digest
eventDigest (Rotation d) = d.digest
eventDigest (Interaction d) = d.digest
eventDigest (Receipt d) = d.digest

eventPrefix :: Event -> String
eventPrefix (Inception d) = d.prefix
eventPrefix (Rotation d) = d.prefix
eventPrefix (Interaction d) = d.prefix
eventPrefix (Receipt d) = d.prefix

eventSequenceNumber :: Event -> Int
eventSequenceNumber (Inception d) = d.sequenceNumber
eventSequenceNumber (Rotation d) = d.sequenceNumber
eventSequenceNumber (Interaction d) = d.sequenceNumber
eventSequenceNumber (Receipt d) = d.sequenceNumber
