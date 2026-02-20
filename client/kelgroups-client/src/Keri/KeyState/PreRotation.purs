module Keri.KeyState.PreRotation
  ( commitKey
  , verifyCommitment
  ) where

import Prelude

import Data.Either (Either(..))
import FFI.Blake3 as Blake3
import Keri.Cesr.Decode as Cesr
import Keri.Cesr.DerivationCode (DerivationCode(..))
import Keri.Cesr.Encode as CesrEncode

-- | Create a pre-rotation commitment for a CESR-encoded public key.
commitKey :: String -> Either String String
commitKey cesrKey = do
  prim <- Cesr.decode cesrKey
  let keyHash = Blake3.hash prim.raw
  pure (CesrEncode.encode { code: Blake3Digest, raw: keyHash })

-- | Verify that a CESR-encoded public key matches a commitment.
verifyCommitment :: String -> String -> Boolean
verifyCommitment cesrKey commitment =
  case commitKey cesrKey of
    Right computed -> computed == commitment
    Left _ -> false
