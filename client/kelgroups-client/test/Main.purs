-- | The client checks. `KELGROUPS_SUITE=e2e` runs the end-to-end suite
-- | against the server at `KELGROUPS_URL` (a run without a URL fails);
-- | otherwise the unit checks run.
module Test.Main where

import Prelude

import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.Aff (launchAff_)
import Effect.Console (log)
import Test.Check (checkAll, setExitCode)
import Test.E2ESpec as E2ESpec
import Test.Env (lookupEnv)
import Test.GroupSpec as GroupSpec
import Test.JwkSpec as JwkSpec
import Test.KelSpec as KelSpec
import Test.SyncSpec as SyncSpec

main :: Effect Unit
main = do
  suite <- lookupEnv "KELGROUPS_SUITE"
  case suite of
    Just "e2e" -> do
      url <- lookupEnv "KELGROUPS_URL"
      case url of
        Just base | base /= "" -> do
          log ("=== Client against the server at " <> base <> " ===")
          launchAff_ $ void $ checkAll (E2ESpec.checks base)
        _ -> do
          log "FAIL INV-41-NOSERVER the end-to-end suite needs a server URL (KELGROUPS_URL)"
          setExitCode 1
    _ -> do
      log "=== JWK Key Export/Import ==="
      JwkSpec.run
      log ""
      log "=== Client validation, replay, fold and sync ==="
      launchAff_ $ void $ checkAll (KelSpec.checks <> GroupSpec.checks <> SyncSpec.checks)
