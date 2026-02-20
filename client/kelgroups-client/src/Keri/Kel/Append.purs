module Keri.Kel.Append
  ( append
  ) where

import Prelude

import Data.Array (snoc, null)
import Data.Either (Either(..))
import Keri.Event (Event(..), eventSequenceNumber)
import Keri.Event.Serialize (serializeEvent)
import Keri.Kel (Kel, SignedEvent)
import Keri.Kel.Replay (replay)
import Keri.KeyState (applyEvent, initialState)
import Keri.KeyState as KS
import Keri.KeyState.Verify (verifySignatures)

-- | Append a signed event to a KEL after verifying
-- signatures and chain integrity.
append :: Kel -> SignedEvent -> Either String Kel
append kel se
  | null kel = appendInception se
  | otherwise = appendToExisting kel se

appendInception :: SignedEvent -> Either String Kel
appendInception se = case se.event of
  Inception d -> do
    let
      msgStr = serializeEvent se.event
      ks = initialState d
    if verifySignatures (KS.stateKeys ks) (KS.stateSigningThreshold ks) msgStr se.signatures then Right [ se ]
    else Left "Inception signatures invalid"
  _ -> Left "First event must be inception"

appendToExisting :: Kel -> SignedEvent -> Either String Kel
appendToExisting kel se = do
  ks <- replay kel
  let msgStr = serializeEvent se.event
  if not (verifySignatures (KS.stateKeys ks) (KS.stateSigningThreshold ks) msgStr se.signatures) then Left "Signatures invalid"
  else do
    let
      expectedSn = KS.stateSequenceNumber ks + 1
      actualSn = eventSequenceNumber se.event
    if actualSn /= expectedSn then Left ("Expected sequence " <> show expectedSn <> ", got " <> show actualSn)
    else do
      _ <- applyEvent ks se.event
      Right (snoc kel se)
