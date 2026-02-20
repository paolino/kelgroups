{- |
Module      : Main
Description : Test suite entry point
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0
-}
module Main (main) where

import InvariantsSpec qualified
import Test.Hspec (hspec)

main :: IO ()
main = hspec InvariantsSpec.spec
