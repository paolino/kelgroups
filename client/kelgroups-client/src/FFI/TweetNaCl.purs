module FFI.TweetNaCl
  ( KeyPair
  , generateKeyPair
  , sign
  , verify
  ) where

import Data.ArrayBuffer.Types (Uint8Array)
import Effect (Effect)

type KeyPair =
  { publicKey :: Uint8Array
  , secretKey :: Uint8Array
  }

foreign import generateKeyPairImpl :: Effect KeyPair

foreign import signImpl :: Uint8Array -> Uint8Array -> Uint8Array

foreign import verifyImpl :: Uint8Array -> Uint8Array -> Uint8Array -> Boolean

generateKeyPair :: Effect KeyPair
generateKeyPair = generateKeyPairImpl

sign :: Uint8Array -> Uint8Array -> Uint8Array
sign = signImpl

verify :: Uint8Array -> Uint8Array -> Uint8Array -> Boolean
verify = verifyImpl
