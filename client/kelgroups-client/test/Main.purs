module Test.Main where

import Prelude

import Effect (Effect)
import Effect.Console (log)
import Test.FoldSpec as FoldSpec
import Test.InvariantsSpec as InvariantsSpec
import Test.TransitionInvariantsSpec as TransitionInvariantsSpec

main :: Effect Unit
main = do
  log "=== Static Invariants ==="
  InvariantsSpec.run
  log ""
  log "=== Transition Invariants ==="
  TransitionInvariantsSpec.run
  log ""
  log "=== Fold Invariants ==="
  FoldSpec.run
  log ""
  log "=== All 24 properties passed ==="
