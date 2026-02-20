module Keri.KeyState.Verify
  ( verifySignatures
  ) where

import Prelude

import Data.Array (index)
import Data.ArrayBuffer.Types (Uint8Array)
import Data.Either (Either(..))
import Data.Foldable (foldl)
import Data.Maybe (Maybe(..))
import FFI.TextEncoder as TE
import FFI.TweetNaCl as NaCl
import Keri.Cesr.Decode as Cesr

type IndexedSignature = { index :: Int, signature :: String }

-- | Verify that enough valid signatures meet the threshold.
verifySignatures :: Array String -> Int -> String -> Array IndexedSignature -> Boolean
verifySignatures pubKeys threshold msgStr sigs =
  let
    msgBytes = TE.encodeUtf8 msgStr
    validCount = foldl (countOne pubKeys msgBytes) 0 sigs
  in
    validCount >= threshold

countOne :: Array String -> Uint8Array -> Int -> IndexedSignature -> Int
countOne pubKeys msgBytes acc sig =
  case index pubKeys sig.index of
    Nothing -> acc
    Just cesrKey -> case Cesr.decode cesrKey of
      Left _ -> acc
      Right keyPrim -> case Cesr.decode sig.signature of
        Left _ -> acc
        Right sigPrim ->
          if NaCl.verify msgBytes sigPrim.raw keyPrim.raw then acc + 1
          else acc
