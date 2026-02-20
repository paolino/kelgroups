module Keri.Cesr.DerivationCode
  ( DerivationCode(..)
  , codeText
  , rawSize
  , codeLength
  , totalLength
  , identifyCode
  ) where

import Prelude

import Data.Either (Either(..))
import Data.String as String

data DerivationCode
  = Ed25519PubKey
  | Blake3Digest
  | Ed25519Sig

derive instance eqDerivationCode :: Eq DerivationCode
derive instance ordDerivationCode :: Ord DerivationCode

instance showDerivationCode :: Show DerivationCode where
  show Ed25519PubKey = "Ed25519PubKey"
  show Blake3Digest = "Blake3Digest"
  show Ed25519Sig = "Ed25519Sig"

codeText :: DerivationCode -> String
codeText Ed25519PubKey = "D"
codeText Blake3Digest = "E"
codeText Ed25519Sig = "0B"

rawSize :: DerivationCode -> Int
rawSize Ed25519PubKey = 32
rawSize Blake3Digest = 32
rawSize Ed25519Sig = 64

codeLength :: DerivationCode -> Int
codeLength Ed25519PubKey = 1
codeLength Blake3Digest = 1
codeLength Ed25519Sig = 2

totalLength :: DerivationCode -> Int
totalLength c =
  let
    padded = codeLength c + rawSize c
  in
    (padded * 4) / 3

identifyCode :: String -> Either String DerivationCode
identifyCode txt
  | String.take 2 txt == "0B" = Right Ed25519Sig
  | String.take 1 txt == "D" = Right Ed25519PubKey
  | String.take 1 txt == "E" = Right Blake3Digest
  | otherwise = Left ("Unknown CESR code: " <> String.take 2 txt)
