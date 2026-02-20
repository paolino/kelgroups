module Json.Canonical
  ( jsonStr
  , jsonInt
  , jsonArr
  , jsonObj
  , kv
  ) where

import Prelude

import Data.Array (intercalate)

-- | JSON string builders for canonical serialization.
-- | Guarantees deterministic field order (whatever order you write).

jsonStr :: String -> String
jsonStr s = "\"" <> escapeJson s <> "\""

jsonInt :: Int -> String
jsonInt = show

jsonArr :: Array String -> String
jsonArr items = "[" <> intercalate "," items <> "]"

jsonObj :: Array String -> String
jsonObj pairs = "{" <> intercalate "," pairs <> "}"

kv :: String -> String -> String
kv k v = jsonStr k <> ":" <> v

foreign import escapeJson :: String -> String
