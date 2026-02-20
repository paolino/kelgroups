module FFI.Uint8Array
  ( length
  , zeros
  , concat
  , drop
  , slice
  ) where

import Data.ArrayBuffer.Types (Uint8Array)

foreign import length :: Uint8Array -> Int

foreign import zeros :: Int -> Uint8Array

foreign import concat :: Uint8Array -> Uint8Array -> Uint8Array

foreign import drop :: Int -> Uint8Array -> Uint8Array

foreign import slice :: Int -> Int -> Uint8Array -> Uint8Array
