module FFI.TextEncoder
  ( encodeUtf8
  , decodeUtf8
  ) where

import Data.ArrayBuffer.Types (Uint8Array)

foreign import encodeUtf8 :: String -> Uint8Array

foreign import decodeUtf8 :: Uint8Array -> String
