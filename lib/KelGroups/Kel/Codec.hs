{-# LANGUAGE NamedFieldPuns #-}

{- |
Module      : KelGroups.Kel.Codec
Description : JSON wire form of signed member KEL events
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

The wire form of a signed event is

> {"event": <KERI event>, "signatures": [{"index": i, "signature": "<CESR>"}]}

where the event object carries exactly the KERI labels keri-hs
serializes for its kind (@v t d i s p kt k nt n bt b br ba c a@),
@s@ in lowercase hexadecimal and the thresholds in decimal, as
keri-hs writes them. Decoding accepts only that form, so a decoded
event re-serializes to the fields that were submitted; signatures
and SAID are then checked over that canonical serialization.
-}
module KelGroups.Kel.Codec
    ( encodeSignedEvent
    , decodeSignedEvent
    , decodeEvent
    , encodeSignatures
    , decodeSignatures
    ) where

import Control.Monad (unless)
import Data.Aeson
    ( Encoding
    , Object
    , Value
    , withArray
    , withObject
    , withText
    , (.:)
    )
import Data.Aeson.Encoding (list, pair, pairs)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseEither, toEncoding)
import Data.Foldable (toList)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Keri.Event
    ( Event (..)
    , InceptionData (..)
    , InteractionData (..)
    , ReceiptData (..)
    , RotationData (..)
    )
import Keri.Event.Serialize (encodeEvent)
import Keri.Kel (SignedEvent (..))
import Numeric (readHex, showHex)

-- | The wire form of a signed event.
encodeSignedEvent :: SignedEvent -> Encoding
encodeSignedEvent SignedEvent{event, signatures} =
    pairs $
        pair "event" (encodeEvent event)
            <> pair "signatures" (encodeSignatures signatures)

-- | Indexed signatures as @[{"index": i, "signature": s}]@.
encodeSignatures :: [(Int, Text)] -> Encoding
encodeSignatures = list $ \(i, s) ->
    pairs $
        pair "index" (toEncoding i)
            <> pair "signature" (toEncoding s)

-- | Decode the wire form of a signed event.
decodeSignedEvent :: Value -> Either String SignedEvent
decodeSignedEvent = parseEither $ withObject "signed event" $ \o -> do
    exactKeys "signed event" ["event", "signatures"] o
    evt <- o .: "event" >>= parseEvent
    sigs <- o .: "signatures" >>= parseSignatures
    pure SignedEvent{event = evt, signatures = sigs}

-- | Decode a KERI event object.
decodeEvent :: Value -> Either String Event
decodeEvent = parseEither parseEvent

-- | Decode indexed signatures.
decodeSignatures :: Value -> Either String [(Int, Text)]
decodeSignatures = parseEither parseSignatures

parseSignatures :: Value -> Parser [(Int, Text)]
parseSignatures = withArray "signatures" $ \xs ->
    traverse parseSig (toList xs)
  where
    parseSig = withObject "signature" $ \o -> do
        exactKeys "signature" ["index", "signature"] o
        i <- o .: "index"
        unless (i >= 0) $ fail "negative signature index"
        s <- o .: "signature"
        pure (i, s)

parseEvent :: Value -> Parser Event
parseEvent = withObject "KERI event" $ \o -> do
    t <- o .: "t"
    case t :: Text of
        "icp" -> do
            exactKeys "icp" icpLabels o
            fmap Inception $
                InceptionData
                    <$> o .: "v"
                    <*> o .: "d"
                    <*> o .: "i"
                    <*> hexField o "s"
                    <*> decField o "kt"
                    <*> o .: "k"
                    <*> decField o "nt"
                    <*> o .: "n"
                    <*> decField o "bt"
                    <*> o .: "b"
                    <*> o .: "c"
                    <*> o .: "a"
        "rot" -> do
            exactKeys "rot" rotLabels o
            fmap Rotation $
                RotationData
                    <$> o .: "v"
                    <*> o .: "d"
                    <*> o .: "i"
                    <*> hexField o "s"
                    <*> o .: "p"
                    <*> decField o "kt"
                    <*> o .: "k"
                    <*> decField o "nt"
                    <*> o .: "n"
                    <*> decField o "bt"
                    <*> o .: "br"
                    <*> o .: "ba"
                    <*> o .: "c"
                    <*> o .: "a"
        "ixn" -> do
            exactKeys "ixn" ixnLabels o
            fmap Interaction $
                InteractionData
                    <$> o .: "v"
                    <*> o .: "d"
                    <*> o .: "i"
                    <*> hexField o "s"
                    <*> o .: "p"
                    <*> o .: "a"
        "rct" -> do
            exactKeys "rct" rctLabels o
            fmap Receipt $
                ReceiptData
                    <$> o .: "v"
                    <*> o .: "d"
                    <*> o .: "i"
                    <*> hexField o "s"
        other -> fail ("unknown event type " <> show other)
  where
    icpLabels =
        ["v", "t", "d", "i", "s", "kt", "k", "nt", "n", "bt", "b", "c", "a"]
    rotLabels =
        [ "v"
        , "t"
        , "d"
        , "i"
        , "s"
        , "p"
        , "kt"
        , "k"
        , "nt"
        , "n"
        , "bt"
        , "ba"
        , "br"
        , "c"
        , "a"
        ]
    ixnLabels = ["v", "t", "d", "i", "s", "p", "a"]
    rctLabels = ["v", "t", "d", "i", "s"]

-- | The object has exactly these labels.
exactKeys :: String -> [Text] -> Object -> Parser ()
exactKeys what labels o =
    unless (sort (map Key.toText (KM.keys o)) == sort labels) $
        fail (what <> ": fields must be exactly " <> show labels)

-- | A non-negative 'Int' in canonical lowercase hexadecimal.
hexField :: Object -> Text -> Parser Int
hexField o k = o .: Key.fromText k >>= withText (T.unpack k) canonicalHex
  where
    canonicalHex t = case readHex (T.unpack t) of
        [(n, "")]
            | n <= toInteger (maxBound :: Int)
            , T.pack (showHex n "") == t ->
                pure (fromInteger n)
        _ -> fail (T.unpack k <> ": not canonical hexadecimal")

-- | A non-negative 'Int' in canonical decimal.
decField :: Object -> Text -> Parser Int
decField o k = o .: Key.fromText k >>= withText (T.unpack k) canonicalDec
  where
    canonicalDec t = case reads (T.unpack t) :: [(Integer, String)] of
        [(n, "")]
            | n >= 0
            , n <= toInteger (maxBound :: Int)
            , T.pack (show n) == t ->
                pure (fromInteger n)
        _ -> fail (T.unpack k <> ": not canonical decimal")
