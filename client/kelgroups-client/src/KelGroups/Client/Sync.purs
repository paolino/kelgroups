-- | Sync of a group against a server, over an injectable `Transport`.
-- |
-- | `sync` reads the group index (where to look, never evidence),
-- | fetches every KEL it names, validates each and replays the group.
-- | With a previous view it refreshes: a KEL whose tip did not move is
-- | kept, a moved one is extended by `?after=<local s>` only and must
-- | chain onto the local tip (else `HistoryRewritten`), a new prefix is
-- | fetched whole; validated history is never re-fetched or rewritten.
-- | A KEL fetched for an index entry must validate as that prefix, and the
-- | index must name each prefix once; otherwise the sync is refused, so no
-- | answer can stand in for a held or another fetched KEL.
-- |
-- | `submit` posts a signed action and, when no answer arrives, resends
-- | the identical bytes, at most three times in all. `act` signs a
-- | payload against a view, submits it and, on a 409 for a stale head or
-- | tip, refreshes, re-validates and signs again against the new view,
-- | at most five rounds. Nothing local changes on an answer: an own
-- | action becomes history only when a later sync sees it in the server's
-- | KEL and on the chain.
module KelGroups.Client.Sync
  ( Response
  , Transport
  , Submission(..)
  , sync
  , submit
  , act
  ) where

import Prelude

import Data.Argonaut.Core (stringify, toArray, toNumber, toObject, toString)
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.Either (Either(..), note)
import Data.Int as Int
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import Effect.Aff (Aff, attempt)
import Effect.Exception (message)
import Foreign.Object as Object
import KelGroups.Client.Group
  ( GroupId
  , GroupView
  , Payload
  , Signer
  , replayGroup
  , signAction
  , viewRecord
  )
import KelGroups.Client.Kel
  ( Prefix
  , SyncRefusal(..)
  , decodeSignedEvent
  , encodeSignedEvent
  , extendKel
  , kelPrefix
  , kelSn
  , kelTip
  , validateKel
  )
import Keri.Kel (SignedEvent)

-- | An HTTP answer: status and body.
type Response = { status :: Int, body :: String }

-- | How the client reaches the server. A transport failure (no answer)
-- | is an error of the `Aff`.
type Transport =
  { getIndex :: GroupId -> Aff Response
  , getKel :: Prefix -> Maybe Int -> Aff Response
  , postAction :: String -> Aff Response
  }

-- | What a submission came to.
data Submission
  = Admitted { group :: GroupId, head :: String, prefix :: Prefix, sn :: Int }
  | Refused { status :: Int, error :: String }
  | Unanswered

derive instance eqSubmission :: Eq Submission

instance showSubmission :: Show Submission where
  show = case _ of
    Admitted a -> "Admitted " <> show a
    Refused r -> "Refused " <> show r
    Unanswered -> "Unanswered"

type Index = { head :: String, kels :: Array { prefix :: Prefix, tip :: String } }

-- | Sync a group: from scratch, or refreshing a previous view.
sync :: Transport -> GroupId -> Maybe GroupView -> Aff (Either SyncRefusal GroupView)
sync t g previous = do
  r <- fetch (t.getIndex g)
  case r >>= parseIndex of
    Left refusal -> pure (Left refusal)
    Right index -> do
      fetched <- traverse kelOf index.kels
      pure do
        kels <- Array.catMaybes <$> sequenceEither fetched
        replayGroup g index.head (Map.union (Map.fromFoldable kels) known)
  where
  known = case previous of
    Just v -> (viewRecord v).kels
    Nothing -> Map.empty

  kelOf { prefix, tip } = case Map.lookup prefix known of
    Just local
      | kelTip local == tip -> pure (Right (Just (Tuple prefix local)))
      | otherwise -> do
          r <- fetch (t.getKel prefix (Just (kelSn local)))
          pure do
            body <- r
            events <- either' (\_ -> Left (HistoryRewritten { prefix, s: kelSn local + 1 })) (decodeEvents body)
            kel <- extendKel local events
            pure (Just (Tuple prefix kel))
    Nothing -> do
      r <- fetch (t.getKel prefix Nothing)
      pure do
        body <- r
        events <- either'
          (\e -> Left (KelInvalid { prefix, s: 0, reason: "notDecodable: " <> e }))
          (decodeEvents body)
        if Array.null events then pure Nothing
        else do
          kel <- validateKel events
          if kelPrefix kel == prefix then pure (Just (Tuple prefix kel))
          else Left (KelInvalid { prefix, s: 0, reason: "prefixMismatch" })

either' :: forall e a b. (e -> Either b a) -> Either e a -> Either b a
either' f = case _ of
  Left e -> f e
  Right a -> Right a

sequenceEither :: forall e a. Array (Either e a) -> Either e (Array a)
sequenceEither = traverse identity

-- | A 200 body, or the refusal for a failed or refused request.
fetch :: Aff Response -> Aff (Either SyncRefusal String)
fetch request = do
  r <- attempt request
  pure case r of
    Left e -> Left (Transport { status: 0, detail: message e })
    Right { status: 200, body } -> Right body
    Right { status, body } -> Left (Transport { status, detail: body })

parseIndex :: String -> Either SyncRefusal Index
parseIndex body = lmapIndex do
  json <- jsonParser body
  o <- note "not an object" (toObject json)
  head <- note "head" (Object.lookup "head" o >>= toString)
  entries <- note "kels" (Object.lookup "kels" o >>= toArray)
  kels <- traverse entry entries
  let prefixes = map _.prefix kels
  unless (Array.length (Array.nub prefixes) == Array.length prefixes)
    $ Left "a prefix listed twice"
  pure { head, kels }
  where
  entry j = do
    e <- note "kels entry" (toObject j)
    prefix <- note "prefix" (Object.lookup "prefix" e >>= toString)
    tip <- note "tip" (Object.lookup "tip" e >>= toString)
    pure { prefix, tip }
  lmapIndex = case _ of
    Left e -> Left (Transport { status: 200, detail: "index: " <> e })
    Right x -> Right x

decodeEvents :: String -> Either String (Array SignedEvent)
decodeEvents body = do
  json <- jsonParser body
  xs <- note "not an array" (toArray json)
  traverse decodeSignedEvent xs

-- | Post a signed action; resend the identical bytes when no answer
-- | arrives, three attempts in all.
submit :: Transport -> SignedEvent -> Aff Submission
submit t se = go 3
  where
  body = stringify (encodeSignedEvent se)
  go n = do
    r <- attempt (t.postAction body)
    case r of
      Left _
        | n > 1 -> go (n - 1)
        | otherwise -> pure Unanswered
      Right res -> pure (answer res)

answer :: Response -> Submission
answer { status, body } = case status, parsed of
  200, Just o
    | Just group <- str "group" o
    , Just head <- str "head" o
    , Just prefix <- str "prefix" o
    , Just sn <- Object.lookup "sn" o >>= toNumber >>= Int.fromNumber ->
        Admitted { group, head, prefix, sn }
  _, Just o -> Refused { status, error: maybeStr (str "error" o) }
  _, Nothing -> Refused { status, error: "" }
  where
  parsed = case jsonParser body of
    Right json -> toObject json
    Left _ -> Nothing
  str k o = Object.lookup k o >>= toString
  maybeStr = case _ of
    Just s -> s
    Nothing -> ""

-- | Sign against the view, submit, and on a 409 for a stale head or tip
-- | refresh and sign again against the new view; five rounds at most,
-- | the last outcome returned. A refusal of the refresh stops it: nothing
-- | more is signed or sent.
act :: Transport -> Signer -> GroupView -> Payload -> Aff (Either SyncRefusal Submission)
act t s view0 p = go 5 view0
  where
  go n view = case signAction s view p of
    Left r -> pure (Left r)
    Right se -> do
      outcome <- submit t se
      case outcome of
        Refused { status: 409, error }
          | n > 1 && (error == "prevNotHead" || error == "notTipSuccessor") -> do
              r <- sync t (viewRecord view).group (Just view)
              case r of
                Left refusal -> pure (Left refusal)
                Right view' -> go (n - 1) view'
        _ -> pure (Right outcome)
