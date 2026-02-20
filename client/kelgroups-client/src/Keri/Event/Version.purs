module Keri.Event.Version
  ( mkVersion
  , versionPlaceholder
  , versionPrefix
  , parseVersionSize
  , intToHex
  ) where

import Prelude

import Data.Int (hexadecimal, fromStringAs)
import Data.Maybe (Maybe)
import Data.String as String
import Data.String.CodeUnits as CU

versionPrefix :: String
versionPrefix = "KERI10JSON"

mkVersion :: Int -> String
mkVersion size = versionPrefix <> padHex 6 size <> "_"

versionPlaceholder :: String
versionPlaceholder = mkVersion 0

parseVersionSize :: String -> Maybe Int
parseVersionSize v = do
  rest <- String.stripPrefix (String.Pattern versionPrefix) v
  hexPart <- String.stripSuffix (String.Pattern "_") rest
  fromStringAs hexadecimal hexPart

padHex :: Int -> Int -> String
padHex width n =
  let
    hex = intToHex n
    padding = repeatStr (width - CU.length hex) "0"
  in
    padding <> hex

intToHex :: Int -> String
intToHex = intToHexImpl

repeatStr :: Int -> String -> String
repeatStr n s
  | n <= 0 = ""
  | otherwise = s <> repeatStr (n - 1) s

foreign import intToHexImpl :: Int -> String
