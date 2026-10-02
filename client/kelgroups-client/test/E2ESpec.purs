-- | The client against the real `kelgroups-server` over HTTP:
-- | INV-41-SAME/e2e, INV-41-GAP/e2e, INV-41-RETRY/e2e, INV-41-RACE/e2e and
-- | INV-41-OWN/e2e. Identities and groups are built through the server's
-- | own `POST /kel` and `POST /actions` with legitimately signed events
-- | (`Test.World`); adversarial cases wrap the real transport and alter or
-- | drop real answers (`Test.Transports`). Expected heads come from the
-- | server's admission answers.
module Test.E2ESpec (checks) where

import Prelude

import Data.Argonaut.Core (fromString, stringify)
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..), fst)
import Effect.Aff (Aff, throwError)
import Effect.Class (liftEffect)
import Effect.Exception (error)
import Effect.Ref as Ref
import FFI.Fetch as Fetch
import KelGroups.Client.Api (httpTransport)
import KelGroups.Client.Group (GroupView, Payload(..), Signer, signAction, viewRecord)
import KelGroups.Client.Kel (SyncRefusal(..), decodeSignedEvent, encodeSignedEvent, kelSn, kelTip)
import KelGroups.Client.Sync (Submission(..), act, sync)
import Keri.Event (Event(..), eventDigest)
import Keri.Kel (SignedEvent)
import Test.Check (check, effectful)
import Test.GroupSpec (matches)
import Test.QuickCheck (Result(..), (===))
import Test.QuickCheck.Gen (randomSampleOne)
import Test.Transports (dropEvent, kelCalls, losing, newCalls, omitPrefix, posts, recording, reverseIndex)
import Test.World (Intent(..), Team, World, genTeam, ident, rotateIn, signerOf)
import Test.World as W

-- --------------------------------------------------------
-- Building on the server
-- --------------------------------------------------------

postTo :: String -> String -> SignedEvent -> Aff { status :: Int, body :: String }
postTo base path se =
  Fetch.fetch (base <> path) { method: "POST", body: stringify (encodeSignedEvent se) }

admitted :: String -> { status :: Int, body :: String } -> Aff Unit
admitted what r =
  unless (r.status == 200) $
    throwError (error (what <> " refused by the server: " <> show r.status <> " " <> r.body))

-- | A team (a admin, b member, c and u outside) hosted and set up on the
-- | server: every inception through `POST /kel`, every action through
-- | `POST /actions`.
serverTeam :: String -> Aff Team
serverTeam base = do
  t <- liftEffect (randomSampleOne genTeam)
  for_ [ t.a, t.b, t.c, t.u ] \p -> case ident p t.world >>= \id -> Array.head id.events of
    Just icp -> postTo base "/kel" icp >>= admitted "inception"
    Nothing -> throwError (error "no inception")
  for_ t.world.log \l -> postTo base "/actions" l.event >>= admitted "setup action"
  pure t

-- | An action signed by the scenario and admitted by the server.
serverAct :: String -> String -> Intent -> World -> Aff World
serverAct base s i w = do
  let w' = W.act s i w
  case Array.last w'.log of
    Just l -> postTo base "/actions" l.event >>= admitted "action"
    Nothing -> throwError (error "no action")
  pure w'

-- | A rotation hosted by the server.
serverRotate :: String -> String -> World -> Aff World
serverRotate base s w = do
  w' <- liftEffect (randomSampleOne (rotateIn s w))
  case ident s w' >>= \id -> Array.last id.events of
    Just rot -> postTo base "/kel" rot >>= admitted "rotation"
    Nothing -> throwError (error "no rotation")
  pure w'

-- --------------------------------------------------------
-- Views
-- --------------------------------------------------------

tipOf :: String -> GroupView -> String
tipOf p gv = case Map.lookup p (viewRecord gv).kels of
  Just k -> kelTip k
  Nothing -> ""

snIn :: String -> GroupView -> Int
snIn p gv = case Map.lookup p (viewRecord gv).kels of
  Just k -> kelSn k
  Nothing -> -1

chainDigests :: GroupView -> Array String
chainDigests gv = map _.digest (viewRecord gv).chain

headOf :: GroupView -> String
headOf gv = (viewRecord gv).head

occurrences :: String -> GroupView -> Int
occurrences d v = Array.length (Array.filter (_ == d) (chainDigests v))

priorOf :: SignedEvent -> String
priorOf se = case se.event of
  Interaction d -> d.priorDigest
  _ -> ""

postedDigest :: String -> String
postedDigest body = case jsonParser body >>= decodeSignedEvent of
  Right se -> eventDigest se.event
  Left _ -> ""

fail :: forall a. String -> Aff a
fail = throwError <<< error

viewOf :: Either SyncRefusal GroupView -> Aff GroupView
viewOf = case _ of
  Right v -> pure v
  Left r -> fail ("sync refused: " <> show r)

signer :: String -> World -> Aff Signer
signer p w = case signerOf p w of
  Just s -> pure s
  Nothing -> fail "no signer key"

-- --------------------------------------------------------
-- Checks
-- --------------------------------------------------------

checks :: String -> Array (Aff Boolean)
checks base =
  let
    http = httpTransport base
  in
    [ check "INV-41-SAME/e2e"
        "two clients syncing one group, KELs fetched in different orders, see the equal view"
        [ effectful "a group with membership changes and rotations" do
            t <- serverTeam base
            w <-
              serverAct base t.b (IApp (fromString "b1")) t.world
                >>= serverRotate base t.c
                >>= serverAct base t.a (IAdd t.c)
                >>= serverAct base t.c (IApp (fromString "c1"))
                >>= serverRotate base t.a
                >>= serverAct base t.a (IGrant t.b)
                >>= serverAct base t.b (IRemove t.c)
            callsOne <- newCalls
            callsTwo <- newCalls
            one <- sync (recording callsOne http) w.group Nothing
            two <- sync (recording callsTwo (reverseIndex http)) w.group Nothing
            stale <- sync http w.group Nothing
            orderOne <- map fst <$> kelCalls callsOne
            orderTwo <- map fst <$> kelCalls callsTwo
            pure
              [ Tuple "the two clients fetched the KELs in different orders"
                  ( Tuple (Array.length orderOne >= 3) (Tuple (orderTwo == Array.reverse orderOne) (orderTwo /= orderOne))
                      === Tuple true (Tuple true true)
                  )
              , Tuple "equal views" (bothViews one two)
              , Tuple "the scenario's view" (matches w one)
              , Tuple "a second instance" (bothViews stale one)
              ]
        , effectful "a view refreshed from an earlier sync equals a fresh one" do
            t <- serverTeam base
            early <- sync http t.world.group Nothing >>= viewOf
            w <-
              serverAct base t.b (IApp (fromString "b1")) t.world
                >>= serverRotate base t.b
                >>= serverAct base t.a (IAdd t.c)
            refreshed <- sync http w.group (Just early)
            fresh <- sync (reverseIndex http) w.group Nothing
            pure [ Tuple "refreshed = fresh" (bothViews refreshed fresh), Tuple "the scenario's view" (matches w fresh) ]
        , effectful "a real KEL answered for another index entry is refused, in either index order" do
            t <- serverTeam base
            w <- serverAct base t.b (IApp (fromString "b1")) t.world
            let
              substituted = http { getKel = \p after -> if p == t.b then http.getKel t.a after else http.getKel p after }
              mismatch = Left (KelInvalid { prefix: t.b, s: 0, reason: "prefixMismatch" })
            one <- sync substituted w.group Nothing
            two <- sync (reverseIndex substituted) w.group Nothing
            pure
              [ Tuple "index order" (map (const unit) one === mismatch)
              , Tuple "reversed index order" (map (const unit) two === mismatch)
              ]
        ]
    , check "INV-41-GAP/e2e"
        "an event removed from a real KEL answer or a KEL omitted from the real index is a Gap; nothing is sent"
        [ effectful "(a) interior action removed from its member KEL" do
            t <- serverTeam base
            before <- sync http t.world.group Nothing >>= viewOf
            w1 <- serverAct base t.b (IApp (fromString "x")) t.world
            let x = w1.head
            w <- serverAct base t.a (IApp (fromString "y")) w1
            fresh <- newCalls
            r1 <- sync (recording fresh (dropEvent x http)) w.group Nothing
            p1 <- posts fresh
            stale <- newCalls
            sa <- signer t.a w
            r2 <- act (recording stale (dropEvent x http)) sa before (App (fromString "z"))
            p2 <- posts stale
            pure
              [ Tuple "fresh sync: Gap" (map (const unit) r1 === Left (Gap { missing: x }))
              , Tuple "fresh sync: nothing sent" (Array.length p1 === 0)
              , Tuple "re-sign after a 409: Gap" (map (const unit) r2 === Left (Gap { missing: x }))
              , Tuple "re-sign after a 409: only the first post sent" (Array.length p2 === 1)
              ]
        , effectful "(b) KEL of the signer of an interior action omitted from the index" do
            t <- serverTeam base
            before <- sync http t.world.group Nothing >>= viewOf
            w1 <- serverAct base t.b (IApp (fromString "x")) t.world
            let x = w1.head
            w <- serverAct base t.a (IApp (fromString "y")) w1
            fresh <- newCalls
            r1 <- sync (recording fresh (omitPrefix t.b http)) w.group Nothing
            p1 <- posts fresh
            stale <- newCalls
            sa <- signer t.a w
            r2 <- act (recording stale (omitPrefix t.b http)) sa before (App (fromString "z"))
            p2 <- posts stale
            pure
              [ Tuple "fresh sync: Gap" (map (const unit) r1 === Left (Gap { missing: x }))
              , Tuple "fresh sync: nothing sent" (Array.length p1 === 0)
              , Tuple "re-sign after a 409: Gap" (map (const unit) r2 === Left (Gap { missing: x }))
              , Tuple "re-sign after a 409: only the first post sent" (Array.length p2 === 1)
              ]
        ]
    , check "INV-41-RETRY/e2e"
        "a lost answer is resent with identical bytes, admitted once, and both clients agree"
        [ effectful "first answer lost after the server admitted" do
            t <- serverTeam base
            view <- sync http t.world.group Nothing >>= viewOf
            sa <- signer t.a t.world
            lose <- liftEffect (Ref.new 1)
            calls <- newCalls
            r <- act (recording calls (losing lose http)) sa view (App (fromString "retry"))
            sent <- posts calls
            let d = maybe' "" (map postedDigest (Array.head sent))
            one <- sync http t.world.group Nothing >>= viewOf
            two <- sync (reverseIndex http) t.world.group Nothing >>= viewOf
            pure
              [ Tuple "two identical posts" (Tuple (Array.length sent) (Array.length (Array.nub sent)) === Tuple 2 1)
              , Tuple "the resend answered as the admission"
                  (map admittedHead r === Right d)
              , Tuple "on the chain exactly once" (occurrences d one === 1)
              , Tuple "it is the head" (headOf one === d)
              , Tuple "both clients agree" (one === two)
              ]
        ]
    , check "INV-41-RACE/e2e"
        "the loser of a race fetches only new suffixes of moved KELs, re-signs and is admitted"
        [ effectful "two members sign against one head" do
            t <- serverTeam base
            va <- sync http t.world.group Nothing >>= viewOf
            vb <- sync http t.world.group Nothing >>= viewOf
            sa <- signer t.a t.world
            sb <- signer t.b t.world
            ra <- act http sa va (App (fromString "a wins"))
            calls <- newCalls
            rb <- act (recording calls http) sb vb (App (fromString "b re-signs"))
            sent <- posts calls
            fetched <- kelCalls calls
            one <- sync http t.world.group Nothing >>= viewOf
            two <- sync (reverseIndex http) t.world.group Nothing >>= viewOf
            let
              da = either' "" admittedHead ra
              db = either' "" admittedHead rb
            pure
              [ Tuple "the winner admitted" (map isAdmitted ra === Right true)
              , Tuple "the loser admitted after re-signing"
                  (Tuple (map isAdmitted rb) (Array.length (Array.nub sent)) === Tuple (Right true) 2)
              , Tuple "only the moved KEL fetched, only its suffix"
                  (fetched === [ Tuple t.a (Just (snIn t.a vb)) ])
              , Tuple "both on the chain, the loser last"
                  (Array.takeEnd 2 (chainDigests one) === [ da, db ])
              , Tuple "final views equal" (one === two)
              ]
        ]
    , check "INV-41-OWN/e2e"
        "an own action is history only once a sync sees it; until then the next p is the validated tip"
        [ effectful "after a 200 and after lost answers" do
            t <- serverTeam base
            v0 <- sync http t.world.group Nothing >>= viewOf
            sa <- signer t.a t.world
            r1 <- act http sa v0 (App (fromString "one"))
            let
              d1 = either' "" admittedHead r1
              next0 = signAction sa v0 (App (fromString "next"))
            v1 <- sync http t.world.group (Just v0) >>= viewOf
            lose <- liftEffect (Ref.new 3)
            calls <- newCalls
            r2 <- act (recording calls (losing lose http)) sa v1 (App (fromString "lost"))
            sent <- posts calls
            let
              d2 = maybe' "" (map postedDigest (Array.head sent))
              next1 = signAction sa v1 (App (fromString "next"))
            v2 <- sync http t.world.group (Just v1) >>= viewOf
            pure
              [ Tuple "after a 200 the next p is the validated tip, not the answered action"
                  (Tuple (map priorOf next0) (occurrences d1 v0) === Tuple (Right (tipOf t.a v0)) 0)
              , Tuple "a sync that sees it makes it history"
                  (Tuple (tipOf t.a v1) (occurrences d1 v1) === Tuple d1 1)
              , Tuple "after lost answers: unanswered, the next p is the validated tip"
                  (Tuple r2 (map priorOf next1) === Tuple (Right Unanswered) (Right d1))
              , Tuple "a sync that sees the lost one makes it history"
                  (Tuple (tipOf t.a v2) (occurrences d2 v2) === Tuple d2 1)
              ]
        ]
    ]

-- | Two views, both produced, and equal.
bothViews :: Either SyncRefusal GroupView -> Either SyncRefusal GroupView -> Result
bothViews a b = case a, b of
  Right x, Right y -> x === y
  _, _ -> Failed ("no view: " <> show (map (const unit) a) <> " " <> show (map (const unit) b))

admittedHead :: Submission -> String
admittedHead = case _ of
  Admitted a -> a.head
  _ -> ""

isAdmitted :: Submission -> Boolean
isAdmitted = case _ of
  Admitted _ -> true
  _ -> false

maybe' :: forall a. a -> Maybe a -> a
maybe' d = case _ of
  Just x -> x
  Nothing -> d

either' :: forall e a b. b -> (a -> b) -> Either e a -> b
either' d f = case _ of
  Right a -> f a
  Left _ -> d

