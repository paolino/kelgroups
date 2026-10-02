-- | The group as the client replays it from validated KELs:
-- | INV-41-SAME/unit, INV-41-GAP/unit, INV-41-RULE/unit and
-- | INV-41-LINE/unit. Every scenario is legitimately signed; expected
-- | heads, chains, rosters and refusals come from the scenario's own
-- | record (`Test.World`), never from the client.
module Test.GroupSpec (checks, matches) where

import Prelude

import Data.Argonaut.Core (fromString)
import Data.ArrayBuffer.Types (Uint8Array)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Set as Set
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import Effect.Aff (Aff)
import KelGroups.Client.Group
  ( GroupView
  , viewRecord
  , Payload(..)
  , Roster(..)
  , replayGroup
  , signAction
  )
import KelGroups.Client.Kel (SyncRefusal(..), kelTip, validateKel)
import Keri.Event (Event(..))
import Keri.Kel (SignedEvent)
import Test.Check (check, property)
import Test.Fixtures (digestOf)
import Test.QuickCheck (Result(..), (===))
import Test.QuickCheck.Gen (Gen, chooseInt, elements, shuffle, vectorOf)
import Test.World
  ( Intent(..)
  , Team
  , World
  , act
  , actAt
  , genPair
  , genRun
  , genTeam
  , rotateIn
  , ident
  , kels
  , kelsWithout
  )
import Data.Array.NonEmpty as NEA

-- | What a client does with fetched KELs: validate each, then replay
-- | from the head.
replay
  :: World -> Array (Tuple String (Array SignedEvent)) -> String -> Either SyncRefusal GroupView
replay w ks h = do
  vs <- traverse (\(Tuple p es) -> Tuple p <$> validateKel es) ks
  replayGroup w.group h (Map.fromFoldable vs)

-- | Head, chain, members and admins.
type Seen =
  { head :: String, chain :: Array String, members :: Set.Set String, admins :: Set.Set String }

-- | What a view shows.
seen :: GroupView -> Seen
seen gv =
  let
    v = viewRecord gv
    Roster r = v.roster
  in
    { head: v.head
    , chain: map _.digest v.chain
    , members: Set.fromFoldable r.members
    , admins: Set.fromFoldable r.admins
    }

-- | What the scenario expects to be seen.
expected :: World -> Seen
expected w =
  { head: w.head
  , chain: map _.digest w.log
  , members: w.members
  , admins: w.admins
  }

matches :: World -> Either SyncRefusal GroupView -> Result
matches w = case _ of
  Left r -> Failed ("refused " <> show r)
  Right v -> showSeen (seen v) === showSeen (expected w)

showSeen :: Seen -> String
showSeen s =
  "head=" <> s.head <> " chain=" <> show s.chain <> " members=" <> show s.members
    <> " admins="
    <> show s.admins

refusedWith :: SyncRefusal -> Either SyncRefusal GroupView -> Result
refusedWith r = case _ of
  Left r' -> r' === r
  Right v -> Failed ("view produced: " <> show v <> ", expected " <> show r)

genWorld :: Gen World
genWorld = do
  t <- genTeam
  n <- chooseInt 0 10
  genRun n t.world

-- | A team in which `b` acted (`x`) and `a` acted after it, then a run.
genGapped :: Gen { team :: Team, world :: World, x :: String }
genGapped = do
  t <- genTeam
  let
    w1 = act t.b (IApp (fromString "x")) t.world
    x = w1.head
    w2 = act t.a (IApp (fromString "y")) w1
  n <- chooseInt 0 6
  w <- genRun n w2
  pure { team: t, world: w, x }

withoutEvent :: String -> World -> Array (Tuple String (Array SignedEvent))
withoutEvent d = withoutEvents [ d ]

withoutEvents :: Array String -> World -> Array (Tuple String (Array SignedEvent))
withoutEvents ds w =
  map (\(Tuple p es) -> Tuple p (Array.filter (\se -> not (Array.elem (digestOf se) ds)) es)) (kels w)
secretOf :: String -> World -> Maybe { prefix :: String, secretKey :: Uint8Array }
secretOf pfx w = do
  id <- ident pfx w
  kp <- Array.head id.current.pairs
  pure { prefix: pfx, secretKey: kp.secretKey }

checks :: Array (Aff Boolean)
checks =
  [ check "INV-41-SAME/unit"
      "every permutation of a member KEL set replays to the equal view, the scenario's"
      [ property "permutations of a generated multi-member KEL set" 25 do
          w <- genWorld
          perms <- vectorOf 4 (shuffle (kels w))
          let views = map (\ks -> replay w ks w.head) perms
          pure case Array.head views of
            Nothing -> Failed "no permutation"
            Just v0 ->
              if Array.all (_ == v0) views then matches w v0
              else Failed ("views differ: " <> show views)
      , property "permutations of a KEL set holding two groups, each replayed" 15 do
          n <- chooseInt 0 10
          { pair } <- genPair n
          perms <- vectorOf 3 (shuffle (kels pair.one))
          let
            same w = case map (\ks -> replay w ks w.head) perms of
              views@[ v0, _, _ ] ->
                if Array.all (_ == v0) views then matches w v0
                else Failed ("views differ: " <> show views)
              _ -> Failed "no permutation"
          pure $ allOf [ Tuple "first group" (same pair.one), Tuple "second group" (same pair.two) ]
      ]
  , check "INV-41-GAP/unit"
      "a removed interior action or an omitted signer KEL is a Gap naming the missing digest"
      [ property "action removed from the middle of its signer's KEL" 10 do
          t <- genTeam
          let
            w1 = act t.a (IApp (fromString "1")) t.world
            removed = case Array.index w1.log 1 of
              Just l -> l.digest
              Nothing -> ""
          n <- chooseInt 0 6
          w <- genRun n w1
          pure $ refusedWith (Gap { missing: removed }) (replay w (withoutEvent removed w) w.head)
      , property "action removed at the end of its signer's KEL, interior on the chain" 10 do
          g <- genGapped
          let
            w = g.world
          pure $ refusedWith (Gap { missing: g.x }) (replay w (withoutEvent g.x w) w.head)
      , property "KEL of a signer of an interior action omitted" 10 do
          g <- genGapped
          let
            w = g.world
            latestOfB = case Array.last (Array.filter (\l -> l.signer == g.team.b) w.log) of
              Just l -> l.digest
              Nothing -> ""
          pure $ refusedWith (Gap { missing: latestOfB }) (replay w (kelsWithout [ g.team.b ] w) w.head)
      , property "inception removed: the first event names it" 10 do
          g <- genGapped
          let
            w = g.world
            icpOfB = case ident g.team.b w >>= \id -> Array.head id.events of
              Just se -> digestOf se
              Nothing -> ""
          pure $ refusedWith (Gap { missing: icpOfB }) (replay w (withoutEvent icpOfB w) w.head)
      , property "two consecutive events removed: the later one is named" 10 do
          t <- genTeam
          let
            w1 = act t.a (IApp (fromString "1")) t.world
            genesis = case Array.index w1.log 0 of
              Just l -> l.digest
              Nothing -> ""
            addB = case Array.index w1.log 1 of
              Just l -> l.digest
              Nothing -> ""
          n <- chooseInt 0 6
          w <- genRun n w1
          pure $ refusedWith (Gap { missing: addB })
            (replay w (withoutEvents [ genesis, addB ] w) w.head)
      ]
  , check "INV-41-RULE/unit"
      "an action breaking the group conditions is a RuleViolation at that action with the server's class"
      [ property "the team itself replays" 8 do
          t <- genTeam
          pure $ matches t.world (replay t.world (kels t.world) t.world.head)
      , property "violations, at the head and followed by a legal action" 8 do
          t <- genTeam
          trailing <- elements (NEA.cons' false [ true ])
          let
            cases =
              [ { cls: "notAMember", s: t.c, i: IApp (fromString "c"), omit: [] }
              , { cls: "notAnAdmin", s: t.b, i: IAdd t.c, omit: [] }
              , { cls: "memberNotHosted", s: t.a, i: IAdd t.u, omit: [ t.u ] }
              , { cls: "lastAdmin", s: t.a, i: ILeave, omit: [] }
              , { cls: "alreadyMember", s: t.a, i: IAdd t.b, omit: [] }
              , { cls: "targetNotMember", s: t.a, i: IRemove t.c, omit: [] }
              , { cls: "alreadyAdmin", s: t.a, i: IGrant t.a, omit: [] }
              , { cls: "targetNotAdmin", s: t.a, i: IRevoke t.b, omit: [] }
              ]
            one c =
              let
                w1 = act c.s c.i t.world
                bad = w1.head
                w = if trailing then act t.b (IApp (fromString "after")) w1 else w1
              in
                Tuple c.cls
                  ( replay w (kelsWithout c.omit w) w.head
                      # refusedWith (RuleViolation { digest: bad, class: c.cls })
                  )
          pure $ allOf (map one cases)
      ]
  , check "INV-41-LINE/unit"
      "a second action on one prev is NotOnLine; actions past the index head, signed ones included, are followed"
      [ property "fork behind the head" 10 do
          w <- genWorld
          x <- case NEA.fromArray (map _.digest (Array.dropEnd 1 w.log)) of
            Just xs -> elements xs
            Nothing -> pure ""
          let forked = actAt x (founder w) (IApp (fromString "fork")) w
          pure $
            if x == "" then Failed "no action behind the head"
            else refusedWith (NotOnLine { digest: forked.head }) (replay forked (kels forked) w.head)
      , property "two actions on the index head" 10 do
          t <- genTeam
          let
            w = t.world
            w1 = actAt w.head t.a (IApp (fromString "one")) w
            w2 = actAt w.head t.b (IApp (fromString "two")) w1
            smaller = min w1.head w2.head
          pure $ refusedWith (NotOnLine { digest: smaller }) (replay w2 (kels w2) w.head)
      , property "an action of the group whose prev is an action of another group, off the line" 10 do
          n <- chooseInt 0 6
          { team, pair } <- genPair n
          x <- elements (NEA.cons' pair.two.head (map _.digest pair.two.log))
          let forged = actAt x team.a (IApp (fromString "cross")) pair.one
          pure $ refusedWith (NotOnLine { digest: forged.head }) (replay forged (kels forged) pair.one.head)
      , property "the index head is an action of the group extending another group" 10 do
          n <- chooseInt 0 6
          { team, pair } <- genPair n
          x <- elements (NEA.cons' pair.two.head (map _.digest pair.two.log))
          let forged = actAt x team.a (IApp (fromString "cross")) pair.one
          pure $ refusedWith (NotOnLine { digest: forged.head }) (replay forged (kels forged) forged.head)
      , property "the index head is an action of another group" 10 do
          n <- chooseInt 0 6
          { pair } <- genPair n
          h <- elements (NEA.cons' pair.two.head (map _.digest pair.two.log))
          pure $ refusedWith (NotOnLine { digest: h }) (replay pair.one (kels pair.one) h)
      , property "index head behind the line's end" 10 do
          w <- genWorld
          h <- elements (NEA.cons' w.head (map _.digest w.log))
          pure $ matches w (replay w (kels w) h)
      , property "actions signed against a view are followed from its head, p the signer's own tip" 8 do
          t <- genTeam
          rotated <- rotateIn t.a t.world
          pure $ allOf
            [ Tuple "admin app" (signedFollowed t.world t.a (App (fromString "signed")) (IApp (fromString "signed")))
            , Tuple "admin add" (signedFollowed t.world t.a (Add t.c) (IAdd t.c))
            , Tuple "member whose tip is not the head" (signedFollowed t.world t.b (App (fromString "b")) (IApp (fromString "b")))
            , Tuple "admin after a rotation" (signedFollowed rotated t.a (App (fromString "r")) (IApp (fromString "r")))
            ]
      ]
  ]

-- | Sign against the replayed view of `w`, append the event to the
-- | signer's KEL and replay from the view's head: the action is followed,
-- | equal to the scenario's own signing, and its `p` is the signer's
-- | validated tip.
signedFollowed :: World -> String -> Payload -> Intent -> Result
signedFollowed w s p intent = case replay w (kels w) w.head, secretOf s w of
  Right v, Just sg -> case signAction sg v p of
    Left r -> Failed ("not signed: " <> show r)
    Right se ->
      let
        vr = viewRecord v
        w' = act s intent w
        ks = map (\(Tuple pf es) -> if pf == s then Tuple pf (Array.snoc es se) else Tuple pf es) (kels w)
        tip = case Map.lookup s vr.kels of
          Just k -> kelTip k
          Nothing -> ""
        prior = case se.event of
          Interaction d -> d.priorDigest
          _ -> ""
      in
        allOf
          [ Tuple "p is the signer's validated tip" (prior === tip)
          , Tuple "followed from the view's head"
              ( Tuple (digestOf se) (map (showSeen <<< seen) (replay w' ks vr.head))
                  === Tuple w'.head (Right (showSeen (expected w')))
              )
          ]
  Left r, _ -> Failed ("refused: " <> show r)
  _, Nothing -> Failed "no key"

founder :: World -> String
founder w = case Array.head w.log of
  Just l -> l.signer
  Nothing -> ""

allOf :: Array (Tuple String Result) -> Result
allOf rs = case Array.find (\(Tuple _ r) -> isFailed r) rs of
  Just (Tuple l (Failed m)) -> Failed (l <> ": " <> m)
  _ -> Success
  where
  isFailed = case _ of
    Failed _ -> true
    Success -> false
