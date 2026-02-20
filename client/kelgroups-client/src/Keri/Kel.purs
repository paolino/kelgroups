module Keri.Kel
  ( Kel
  , SignedEvent
  , emptyKel
  ) where

import Keri.Event (Event)

type SignedEvent =
  { event :: Event
  , signatures :: Array { index :: Int, signature :: String }
  }

type Kel = Array SignedEvent

emptyKel :: Kel
emptyKel = []
