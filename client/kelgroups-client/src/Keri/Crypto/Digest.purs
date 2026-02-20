module Keri.Crypto.Digest
  ( computeSaid
  , saidPlaceholder
  ) where

import Prelude

import FFI.Blake3 as Blake3
import FFI.TextEncoder as TE
import Keri.Cesr.DerivationCode (DerivationCode(..), totalLength)
import Keri.Cesr.Encode as Cesr

-- | Placeholder for the "d" field during SAID computation.
saidPlaceholder :: String
saidPlaceholder = repeatStr (totalLength Blake3Digest) "#"

-- | Compute the SAID of serialized event JSON string.
computeSaid :: String -> String
computeSaid str =
  let
    bytes = TE.encodeUtf8 str
    digest = Blake3.hash bytes
  in
    Cesr.encode { code: Blake3Digest, raw: digest }

repeatStr :: Int -> String -> String
repeatStr n s
  | n <= 0 = ""
  | n == 1 = s
  | otherwise =
      let
        half = repeatStr (n / 2) s
        rest = if n `mod` 2 == 0 then "" else s
      in
        half <> half <> rest
