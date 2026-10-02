-- | Transports around a real one for the end-to-end checks: recording
-- | what the client asks, and adversarial ones that alter or drop real
-- | answers of the server (an event removed from a KEL, a prefix removed
-- | from the index, an answer lost after the server got the request).
-- | The server itself is never changed.
module Test.Transports
  ( Calls
  , newCalls
  , posts
  , kelCalls
  , indexCalls
  , recording
  , dropEvent
  , omitPrefix
  , reverseIndex
  , losing
  ) where

import Prelude

import Data.Argonaut.Core (Json, fromArray, fromObject, stringify, toArray, toObject, toString)
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import Effect.Aff (Aff, throwError)
import Effect.Class (liftEffect)
import Effect.Exception (error)
import Effect.Ref (Ref)
import Effect.Ref as Ref
import Foreign.Object as Object
import KelGroups.Client.Sync (Response, Transport)

-- | What a client asked: posted bodies and KEL fetches with their `after`.
type Calls = Ref { index :: Int, posts :: Array String, kels :: Array (Tuple String (Maybe Int)) }

newCalls :: Aff Calls
newCalls = liftEffect $ Ref.new { index: 0, posts: [], kels: [] }

posts :: Calls -> Aff (Array String)
posts c = _.posts <$> liftEffect (Ref.read c)

kelCalls :: Calls -> Aff (Array (Tuple String (Maybe Int)))
kelCalls c = _.kels <$> liftEffect (Ref.read c)

indexCalls :: Calls -> Aff Int
indexCalls c = _.index <$> liftEffect (Ref.read c)

recording :: Calls -> Transport -> Transport
recording c t =
  { getIndex: \g -> do
      liftEffect $ Ref.modify_ (\s -> s { index = s.index + 1 }) c
      t.getIndex g
  , getKel: \p after -> do
      liftEffect $ Ref.modify_ (\s -> s { kels = Array.snoc s.kels (Tuple p after) }) c
      t.getKel p after
  , postAction: \body -> do
      liftEffect $ Ref.modify_ (\s -> s { posts = Array.snoc s.posts body }) c
      t.postAction body
  }

-- | A 200 body rewritten by `f`.
alter :: (Json -> Json) -> Response -> Response
alter f r
  | r.status == 200 = case jsonParser r.body of
      Right json -> r { body = stringify (f json) }
      Left _ -> r
  | otherwise = r

-- | Every KEL answer without the event of this digest.
dropEvent :: String -> Transport -> Transport
dropEvent d t = t { getKel = \p after -> alter withoutIt <$> t.getKel p after }
  where
  withoutIt json = case toArray json of
    Just xs -> fromArray (Array.filter (\x -> digestIn x /= Just d) xs)
    Nothing -> json
  digestIn x = toObject x >>= Object.lookup "event" >>= toObject >>= Object.lookup "d" >>= toString

-- | The index answer without this prefix.
omitPrefix :: String -> Transport -> Transport
omitPrefix p t = t { getIndex = \g -> alter (onKels (Array.filter (\e -> prefixIn e /= Just p))) <$> t.getIndex g }
  where
  prefixIn e = toObject e >>= Object.lookup "prefix" >>= toString

-- | The index answer with its KELs in reverse order (so they are fetched
-- | in reverse order).
reverseIndex :: Transport -> Transport
reverseIndex t = t { getIndex = \g -> alter (onKels Array.reverse) <$> t.getIndex g }

onKels :: (Array Json -> Array Json) -> Json -> Json
onKels f json = case toObject json of
  Just o -> case Object.lookup "kels" o >>= toArray of
    Just ks -> fromObject (Object.insert "kels" (fromArray (f ks)) o)
    Nothing -> json
  Nothing -> json

-- | The post reaches the server; its answer is lost while the counter is
-- | positive.
losing :: Ref Int -> Transport -> Transport
losing n t = t
  { postAction = \body -> do
      r <- t.postAction body
      left <- liftEffect (Ref.read n)
      if left > 0 then do
        liftEffect (Ref.write (left - 1) n)
        throwError (error ("answer lost (" <> show r.status <> ")"))
      else pure r
  }
