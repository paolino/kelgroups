module Keri.KeyState
  ( KeyState
  , initialState
  , applyEvent
  , statePrefix
  , stateSequenceNumber
  , stateLastDigest
  , stateSigningThreshold
  , stateKeys
  , stateNextKeys
  ) where

import Prelude

import Data.Array (length, zip) as Array
import Data.Either (Either(..))
import Data.Traversable (traverse_)
import Data.Tuple (Tuple(..))
import Keri.Event (Event(..), InceptionData, RotationData, InteractionData)
import Keri.KeyState.PreRotation (verifyCommitment)

type KeyState =
  { prefix :: String
  , sequenceNumber :: Int
  , lastDigest :: String
  , signingThreshold :: Int
  , keys :: Array String
  , nextThreshold :: Int
  , nextKeys :: Array String
  }

statePrefix :: KeyState -> String
statePrefix ks = ks.prefix

stateSequenceNumber :: KeyState -> Int
stateSequenceNumber ks = ks.sequenceNumber

stateLastDigest :: KeyState -> String
stateLastDigest ks = ks.lastDigest

stateSigningThreshold :: KeyState -> Int
stateSigningThreshold ks = ks.signingThreshold

stateKeys :: KeyState -> Array String
stateKeys ks = ks.keys

stateNextKeys :: KeyState -> Array String
stateNextKeys ks = ks.nextKeys

initialState :: InceptionData -> KeyState
initialState d =
  { prefix: d.prefix
  , sequenceNumber: d.sequenceNumber
  , lastDigest: d.digest
  , signingThreshold: d.signingThreshold
  , keys: d.keys
  , nextThreshold: d.nextThreshold
  , nextKeys: d.nextKeys
  }

applyEvent :: KeyState -> Event -> Either String KeyState
applyEvent _ks (Inception _) = Left "Cannot apply inception to existing state"
applyEvent ks (Rotation d) = applyRotation ks d
applyEvent ks (Interaction d) = applyInteraction ks d
applyEvent ks (Receipt _) = Right ks

applyRotation :: KeyState -> RotationData -> Either String KeyState
applyRotation ks d = do
  checkPrefix ks d.prefix
  checkSequence ks d.sequenceNumber
  checkPrior ks d.priorDigest
  verifyPreRotation ks.nextKeys d.keys
  Right ks
    { sequenceNumber = d.sequenceNumber
    , lastDigest = d.digest
    , signingThreshold = d.signingThreshold
    , keys = d.keys
    , nextThreshold = d.nextThreshold
    , nextKeys = d.nextKeys
    }

applyInteraction :: KeyState -> InteractionData -> Either String KeyState
applyInteraction ks d = do
  checkPrefix ks d.prefix
  checkSequence ks d.sequenceNumber
  checkPrior ks d.priorDigest
  Right ks
    { sequenceNumber = d.sequenceNumber
    , lastDigest = d.digest
    }

checkPrefix :: KeyState -> String -> Either String Unit
checkPrefix ks p
  | ks.prefix /= p = Left "Prefix mismatch"
  | otherwise = Right unit

checkSequence :: KeyState -> Int -> Either String Unit
checkSequence ks sn
  | sn /= ks.sequenceNumber + 1 =
      Left ("Expected sequence " <> show (ks.sequenceNumber + 1) <> ", got " <> show sn)
  | otherwise = Right unit

checkPrior :: KeyState -> String -> Either String Unit
checkPrior ks p
  | ks.lastDigest /= p = Left "Prior digest mismatch"
  | otherwise = Right unit

verifyPreRotation :: Array String -> Array String -> Either String Unit
verifyPreRotation commitments newKeys
  | Array.length commitments /= Array.length newKeys =
      Left "Key count mismatch with commitments"
  | otherwise =
      traverse_ checkOne (Array.zip newKeys commitments)
      where
      checkOne (Tuple key commitment) =
        if verifyCommitment key commitment then Right unit
        else Left "Pre-rotation commitment mismatch"
