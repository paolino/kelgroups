module FFI.Blake3
  ( hash
  ) where

import Data.ArrayBuffer.Types (Uint8Array)

foreign import hashImpl :: Uint8Array -> Uint8Array

hash :: Uint8Array -> Uint8Array
hash = hashImpl
