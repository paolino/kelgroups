-- | The environment of the test process.
module Test.Env (lookupEnv) where

import Prelude

import Data.Maybe (Maybe)
import Data.Nullable (Nullable, toMaybe)
import Effect (Effect)

foreign import lookupEnvImpl :: String -> Effect (Nullable String)

-- | A variable of the process environment.
lookupEnv :: String -> Effect (Maybe String)
lookupEnv k = map toMaybe (lookupEnvImpl k)
