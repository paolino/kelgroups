{- |
Module      : GroupFixtures
Description : Legitimately signed group actions for tests
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

Group anchors written literally in the wire form of data model
D1, carried by interaction events built with keri-hs and signed
by the current keys of a member KEL fixture.
-}
module GroupFixtures
    ( -- * Anchors (data model D1)
      genesisAnchor
    , actionAnchor
    , appAnchor
    , appPayload
    , memberPayload
    , leavePayload
    , genAppData
    , genNumericData
    , respellNumbers

      -- * Actions
    , anchoredOf
    , actWith
    , genesisOf
    , appOf
    , genMember
    , genMultiKeyMember
    ) where

import Data.Aeson (Value (..), object, (.=))
import Data.Scientific (base10Exponent, coefficient, scientific)
import Data.Text (Text)
import Data.Text qualified as T
import Keri.Event (Event, eventDigest)
import Keri.Event.Interaction
    ( InteractionConfig (..)
    , mkInteraction
    )
import Keri.Kel (SignedEvent)
import MemberKelFixtures
    ( Chain (..)
    , KeySet (..)
    , genKeyPair
    , genRotChain
    , rotateChain
    , signAll
    , startChain
    )
import Test.QuickCheck (Gen, chooseInt, elements, oneof, vectorOf)

-- | @{"payload": {"t": "genesis"}}@.
genesisAnchor :: Value
genesisAnchor = object ["payload" .= object ["t" .= ("genesis" :: Text)]]

-- | @{"t": "app", "data": d}@.
appPayload :: Value -> Value
appPayload d = object ["t" .= ("app" :: Text), "data" .= d]

-- | @{"t": t, "member": x}@: an add, remove, grant or revoke of @x@.
memberPayload :: Text -> Text -> Value
memberPayload t x = object ["t" .= t, "member" .= x]

-- | @{"t": "leave"}@.
leavePayload :: Value
leavePayload = object ["t" .= ("leave" :: Text)]

-- | @{"group": g, "prev": h, "payload": pl}@.
actionAnchor :: Text -> Text -> Value -> Value
actionAnchor g h pl = object ["group" .= g, "prev" .= h, "payload" .= pl]

-- | @{"group": g, "prev": h, "payload": {"t": "app", "data": d}}@.
appAnchor :: Text -> Text -> Value -> Value
appAnchor g h d = actionAnchor g h (appPayload d)

-- | Small application data.
genAppData :: Gen Value
genAppData =
    oneof
        [ String . T.pack . show <$> chooseInt (0, 1000000)
        , Number . fromIntegral <$> chooseInt (-1000, 1000)
        , (\n -> object ["n" .= n]) <$> chooseInt (0, 1000)
        ]

{- | Application data holding numbers, nested in an object and an
array, so it has spellings that are equal values with other bytes.
-}
genNumericData :: Gen Value
genNumericData = do
    n <- chooseInt (-1000, 1000)
    ns <- vectorOf 2 (chooseInt (0, 1000))
    pure $ object ["n" .= n, "ns" .= ns]

{- | Spell every number with @k@ more trailing zero decimals:
@1@ becomes @1.0@ for @k = 1@. The value is equal (Eq on
@Value@ compares numbers by value); its serialization is not.
-}
respellNumbers :: Int -> Value -> Value
respellNumbers k = \case
    Number s ->
        Number $
            scientific
                (coefficient s * 10 ^ k)
                (base10Exponent s - k)
    Object o -> Object (fmap (respellNumbers k) o)
    Array xs -> Array (fmap (respellNumbers k) xs)
    other -> other

-- | An interaction with these anchors.
anchoredOf :: Text -> Int -> Text -> [Value] -> Event
anchoredOf pfx sn prior as =
    mkInteraction
        InteractionConfig
            { ixPrefix = pfx
            , ixSequenceNumber = sn
            , ixPriorDigest = prior
            , ixAnchors = as
            }

-- | Interact with these anchors, signed by the current keys.
actWith :: [Value] -> Chain -> (SignedEvent, Chain)
actWith as ch =
    let evt = anchoredOf (chPrefix ch) (chSn ch + 1) (chTip ch) as
        se = signAll (ksPairs (chCurrent ch)) evt
    in  ( se
        , ch
            { chEvents = chEvents ch <> [se]
            , chSn = chSn ch + 1
            , chTip = eventDigest evt
            }
        )

-- | A genesis action; its group id is the event's @d@.
genesisOf :: Chain -> (SignedEvent, Chain)
genesisOf = actWith [genesisAnchor]

-- | An app action in group @g@ extending head @h@.
appOf :: Text -> Text -> Value -> Chain -> (SignedEvent, Chain)
appOf g h d = actWith [appAnchor g h d]

-- | A member KEL: an inception and zero to four rotations.
genMember :: Gen Chain
genMember = genRotChain

{- | A member KEL whose every key set has two or three keys and a
threshold below their number, so the first @threshold@ keys and
all keys are two distinct signature sets meeting it.
-}
genMultiKeyMember :: Gen Chain
genMultiKeyMember = do
    ks0 <- genSubThreshold
    ks1 <- genSubThreshold
    rotations <- chooseInt (0, 2)
    nexts <- mapM (const genSubThreshold) [1 .. rotations]
    pure $
        foldl (\ch ks -> snd (rotateChain ks ch)) (startChain ks0 ks1) nexts
  where
    genSubThreshold = do
        n <- elements [2, 3]
        kps <- vectorOf n genKeyPair
        kt <- chooseInt (1, n - 1)
        pure KeySet{ksPairs = kps, ksThreshold = kt}
