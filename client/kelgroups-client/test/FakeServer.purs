-- | An in-memory stand-in for the server's answers, for the /unit sync
-- | checks: the index of one group (its head and every KEL it holds), KEL
-- | reads with `?after=`, and `POST /actions` that appends the posted
-- | event to its signer's KEL and makes it the head (an identical resend
-- | is answered as its admission), judging nothing. It can lose answers
-- | after applying the request, and can be switched to another state.
module Test.FakeServer
  ( Fake
  , State
  , newFake
  , setState
  , loseAnswers
  , fakeTransport
  , fakeCalls
  ) where

import Prelude

import Data.Argonaut.Core (fromArray, fromNumber, fromObject, fromString, stringify)
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Int as Int
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Aff (throwError)
import Effect.Class (liftEffect)
import Effect.Exception (error)
import Effect.Ref (Ref)
import Effect.Ref as Ref
import Foreign.Object as Object
import KelGroups.Client.Kel (decodeSignedEvent, encodeSignedEvent)
import KelGroups.Client.Sync (Response, Transport)
import Keri.Event (eventDigest, eventPrefix, eventSequenceNumber)
import Keri.Kel (SignedEvent)

type State =
  { group :: String
  , head :: String
  , kels :: Map String (Array SignedEvent)
  , lose :: Int
  , posts :: Array String
  , kelCalls :: Array (Tuple String (Maybe Int))
  }

type Fake = Ref State

newFake :: String -> String -> Array (Tuple String (Array SignedEvent)) -> Effect Fake
newFake group head kels =
  Ref.new { group, head, kels: Map.fromFoldable kels, lose: 0, posts: [], kelCalls: [] }

-- | Replace the group head and the KELs.
setState :: Fake -> String -> Array (Tuple String (Array SignedEvent)) -> Effect Unit
setState f head kels = Ref.modify_ (_ { head = head, kels = Map.fromFoldable kels }) f

-- | Lose the next `n` answers to `POST /actions`, after applying them.
loseAnswers :: Fake -> Int -> Effect Unit
loseAnswers f n = Ref.modify_ (_ { lose = n }) f

fakeCalls :: Fake -> Effect { posts :: Array String, kelCalls :: Array (Tuple String (Maybe Int)) }
fakeCalls f = (\s -> { posts: s.posts, kelCalls: s.kelCalls }) <$> Ref.read f

ok :: String -> Response
ok body = { status: 200, body }

fakeTransport :: Fake -> Transport
fakeTransport f =
  { getIndex: \g -> liftEffect do
      s <- Ref.read f
      pure
        if g /= s.group then { status: 404, body: "{\"error\":\"noSuchGroup\"}" }
        else ok $ stringify $ fromObject $ Object.fromFoldable
          [ Tuple "head" (fromString s.head)
          , Tuple "kels" $ fromArray $ map
              ( \(Tuple p es) -> fromObject $ Object.fromFoldable
                  [ Tuple "prefix" (fromString p)
                  , Tuple "tip" (fromString (maybe' "" (map (\se -> eventDigest se.event) (Array.last es))))
                  ]
              )
              (Map.toUnfoldable s.kels)
          ]
  , getKel: \p after -> liftEffect do
      Ref.modify_ (\s -> s { kelCalls = Array.snoc s.kelCalls (Tuple p after) }) f
      s <- Ref.read f
      pure case Map.lookup p s.kels of
        Nothing -> { status: 404, body: "{\"error\":\"unhosted\"}" }
        Just es ->
          let
            keep se = case after of
              Just n -> eventSequenceNumber se.event > n
              Nothing -> true
          in
            ok (stringify (fromArray (map encodeSignedEvent (Array.filter keep es))))
  , postAction: \body -> do
      r <- liftEffect do
        Ref.modify_ (\s -> s { posts = Array.snoc s.posts body }) f
        s <- Ref.read f
        case jsonParser body >>= decodeSignedEvent of
          Left e -> pure { status: 400, body: "{\"error\":\"notDecodable\",\"detail\":" <> show e <> "}" }
          Right se -> do
            let
              p = eventPrefix se.event
              d = eventDigest se.event
              es = maybe' [] (Map.lookup p s.kels)
              known = Array.any (\x -> eventDigest x.event == d) es
            unless known $
              Ref.write (s { head = d, kels = Map.insert p (Array.snoc es se) s.kels }) f
            pure $ ok $ stringify $ fromObject $ Object.fromFoldable
              [ Tuple "group" (fromString s.group)
              , Tuple "head" (fromString d)
              , Tuple "prefix" (fromString p)
              , Tuple "sn" (fromNumber (Int.toNumber (eventSequenceNumber se.event)))
              ]
      s <- liftEffect (Ref.read f)
      if s.lose > 0 then do
        liftEffect (Ref.write (s { lose = s.lose - 1 }) f)
        throwError (error "answer lost")
      else pure r
  }

maybe' :: forall a. a -> Maybe a -> a
maybe' d = case _ of
  Just x -> x
  Nothing -> d
