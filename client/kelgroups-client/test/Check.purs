-- | The output contract of the invariant checks: each check prints
-- | exactly one line, `PASS <ID>/<layer> <description> cases=<n>` when
-- | every case passed and at least one ran, or a line starting `FAIL `;
-- | a failed check sets the process exit code to 1.
module Test.Check
  ( Part
  , property
  , example
  , examples
  , effectful
  , check
  , checkAll
  ) where

import Prelude

import Data.Array as Array
import Data.Foldable (all, foldl)
import Data.List as List
import Data.String (joinWith)
import Data.Traversable (sequence, traverse)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Data.Either (Either(..))
import Effect.Aff (Aff, attempt)
import Effect.Class (liftEffect)
import Effect.Console (log)
import Effect.Exception (message)
import Test.QuickCheck (Result(..), checkResults, quickCheckGenPure', randomSeed)
import Test.QuickCheck.Gen (Gen)

-- | Some cases of a check: how many ran and the failures among them.
type Part = Aff { cases :: Int, failures :: Array String }

-- | `n` generated cases of a property.
property :: String -> Int -> Gen Result -> Part
property label n gen = liftEffect do
  seed <- randomSeed
  let summary = checkResults (quickCheckGenPure' seed n gen)
  pure
    { cases: summary.total
    , failures: Array.fromFoldable $ map
        (\f -> label <> " (seed " <> show f.seed <> "): " <> f.message)
        (List.take 3 summary.failures)
    }

-- | One case.
example :: String -> Result -> Part
example label r = pure (oneCase label r)

-- | Named cases.
examples :: Array (Tuple String Result) -> Part
examples rs = pure (foldl addCounts { cases: 0, failures: [] } (map (\(Tuple l r) -> oneCase l r) rs))

-- | Cases computed by an effect (a run against a server); an exception
-- | is a failure of one case.
effectful :: String -> Aff (Array (Tuple String Result)) -> Part
effectful label run = do
  r <- attempt run
  case r of
    Left e -> pure { cases: 1, failures: [ label <> ": " <> message e ] }
    Right rs -> examples rs

oneCase :: String -> Result -> { cases :: Int, failures :: Array String }
oneCase label = case _ of
  Success -> { cases: 1, failures: [] }
  Failed msg -> { cases: 1, failures: [ label <> ": " <> msg ] }

addCounts
  :: { cases :: Int, failures :: Array String }
  -> { cases :: Int, failures :: Array String }
  -> { cases :: Int, failures :: Array String }
addCounts a b = { cases: a.cases + b.cases, failures: a.failures <> b.failures }

-- | Run the parts of one check and print its line.
check :: String -> String -> Array Part -> Aff Boolean
check idLayer description parts = do
  results <- sequence parts
  let total = foldl addCounts { cases: 0, failures: [] } results
  if Array.null total.failures && total.cases >= 1 then do
    liftEffect $ log $
      "PASS " <> idLayer <> " " <> description <> " cases=" <> show total.cases
    pure true
  else do
    liftEffect $ log $
      "FAIL " <> idLayer <> " " <> description
        <> " cases="
        <> show total.cases
        <> " "
        <> joinWith " | " (Array.take 5 total.failures)
    pure false

-- | Run checks; any failure sets the exit code.
checkAll :: Array (Aff Boolean) -> Aff Boolean
checkAll cs = do
  oks <- traverse identity cs
  let ok = all identity oks
  unless ok $ liftEffect (setExitCode 1)
  pure ok

foreign import setExitCode :: Int -> Effect Unit
