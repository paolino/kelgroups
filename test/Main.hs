{- |
Module      : Main
Description : Test suite entry point
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0
-}
module Main (main) where

import InvariantsSpec qualified
import StoreInvariantsSpec qualified
import StoreSpec qualified
import Test.Hspec (hspec)
import TransitionInvariantsSpec qualified

main :: IO ()
main = hspec $ do
    InvariantsSpec.spec
    TransitionInvariantsSpec.spec
    StoreSpec.spec
    StoreInvariantsSpec.spec
