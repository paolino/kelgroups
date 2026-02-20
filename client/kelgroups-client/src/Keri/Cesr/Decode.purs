module Keri.Cesr.Decode
  ( decode
  ) where

import Prelude

import Data.Either (Either(..))
import Data.String as String
import FFI.Base64Url as B64
import FFI.Uint8Array as U8
import Keri.Cesr.DerivationCode (codeLength, identifyCode, totalLength)
import Keri.Cesr.Primitive (Primitive)

-- | Decode a CESR-encoded text to a Primitive.
decode :: String -> Either String Primitive
decode txt = do
  c <- identifyCode txt
  let
    padLen = codeLength c
    expected = totalLength c
  if String.length txt < expected then
    Left ("Too short: expected " <> show expected <> " chars, got " <> show (String.length txt))
  else do
    let
      body = String.take expected txt
      zeroPad = repeatStr padLen "A"
      b64Text = zeroPad <> String.drop padLen body
      rawWithPad = B64.decode b64Text
    Right { code: c, raw: U8.drop padLen rawWithPad }

repeatStr :: Int -> String -> String
repeatStr n s
  | n <= 0 = ""
  | otherwise = s <> repeatStr (n - 1) s
