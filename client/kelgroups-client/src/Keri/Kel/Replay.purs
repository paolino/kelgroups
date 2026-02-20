module Keri.Kel.Replay
  ( replay
  ) where

import Data.Array (uncons)
import Data.Either (Either(..))
import Data.Foldable (foldM)
import Data.Maybe (Maybe(..))
import Keri.Event (Event(..))
import Keri.Kel (Kel, SignedEvent)
import Keri.KeyState (KeyState, applyEvent, initialState)

-- | Replay a KEL to derive the current KeyState.
-- Does not re-verify signatures (done during append).
replay :: Kel -> Either String KeyState
replay kel = case uncons kel of
  Nothing -> Left "Empty KEL"
  Just { head, tail } -> case head.event of
    Inception d -> foldEvents (initialState d) tail
    _ -> Left "KEL must start with inception"

foldEvents :: KeyState -> Array SignedEvent -> Either String KeyState
foldEvents ks events = foldM (\s se -> applyEvent s se.event) ks events
