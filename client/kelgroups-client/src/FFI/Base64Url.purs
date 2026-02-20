module FFI.Base64Url
  ( encode
  , decode
  ) where

import Data.ArrayBuffer.Types (Uint8Array)

foreign import encodeImpl :: Uint8Array -> String

foreign import decodeImpl :: String -> Uint8Array

encode :: Uint8Array -> String
encode = encodeImpl

decode :: String -> Uint8Array
decode = decodeImpl
