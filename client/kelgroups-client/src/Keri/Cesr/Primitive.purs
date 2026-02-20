module Keri.Cesr.Primitive
  ( Primitive
  , mkPrimitive
  , code
  , raw
  ) where

import Prelude

import Data.ArrayBuffer.Types (Uint8Array)
import Data.Either (Either(..))
import FFI.Uint8Array as U8
import Keri.Cesr.DerivationCode (DerivationCode, rawSize)

type Primitive =
  { code :: DerivationCode
  , raw :: Uint8Array
  }

code :: Primitive -> DerivationCode
code p = p.code

raw :: Primitive -> Uint8Array
raw p = p.raw

mkPrimitive :: DerivationCode -> Uint8Array -> Either String Primitive
mkPrimitive c bs
  | U8.length bs /= rawSize c =
      Left ("Expected " <> show (rawSize c) <> " bytes, got " <> show (U8.length bs))
  | otherwise = Right { code: c, raw: bs }
