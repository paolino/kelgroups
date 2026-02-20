module Keri.Cesr.Encode
  ( encode
  ) where

import Prelude

import Data.String as String
import FFI.Base64Url as B64
import FFI.Uint8Array as U8
import Keri.Cesr.DerivationCode (codeLength, codeText)
import Keri.Cesr.Primitive (Primitive)

-- | Encode a Primitive to CESR Base64url text.
-- Prepends zero-pad bytes (count = code length),
-- Base64url-encodes, then replaces leading chars with code.
encode :: Primitive -> String
encode p =
  let
    padLen = codeLength p.code
    padded = U8.concat (U8.zeros padLen) p.raw
    b64 = B64.encode padded
  in
    codeText p.code <> String.drop padLen b64
