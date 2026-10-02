-- | Legitimately signed group scenarios and their oracle. A `World` holds
-- | identities with their KELs, one group, its head and the actions
-- | signed into it in order. `act` signs an action of an identity
-- | against the current head on its current tip and appends it, without
-- | judging it: the scenario decides what is legal. The expected roster
-- | is kept as sets by the rule effects of the Lean `applyCore`, written
-- | here from the specification, not from the client.
module Test.World
  ( World
  , Intent(..)
  , Logged
  , found
  , act
  , actAt
  , rotateIn
  , ident
  , kels
  , kelsWithout
  , genTeam
  , Team
  , genRun
  , Pair
  , foundAlso
  , onOne
  , onTwo
  , genPair
  ) where

import Prelude

import Data.Argonaut.Core (Json, fromString)
import Data.Array as Array
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Set (Set)
import Data.Set as Set
import Data.Tuple (Tuple(..))
import Keri.Kel (SignedEvent)
import Test.Fixtures
  ( Ident
  , actionAnchor
  , addP
  , appP
  , digestOf
  , genKeys
  , genesisAnchor
  , grantP
  , incept
  , interact
  , leaveP
  , removeP
  , revokeP
  , rotate
  )
import Test.QuickCheck.Gen (Gen, chooseInt, elements)
import Data.Array.NonEmpty as NEA

-- | What an action means to do.
data Intent
  = IAdd String
  | IRemove String
  | IGrant String
  | IRevoke String
  | ILeave
  | IApp Json

-- | An action as signed into the world.
type Logged = { signer :: String, digest :: String, event :: SignedEvent }

type World =
  { ids :: Map String Ident
  , group :: String
  , head :: String
  , log :: Array Logged
  , members :: Set String
  , admins :: Set String
  }

ident :: String -> World -> Maybe Ident
ident pfx w = Map.lookup pfx w.ids

-- | A group founded by the first identity; every identity hosted.
found :: Ident -> Array Ident -> World
found founder others =
  let
    Tuple se founder' = interact [ genesisAnchor ] founder
    g = digestOf se
  in
    { ids: Map.fromFoldable
        (map (\i -> Tuple i.prefix i) (Array.cons founder' others))
    , group: g
    , head: g
    , log: [ { signer: founder.prefix, digest: g, event: se } ]
    , members: Set.singleton founder.prefix
    , admins: Set.singleton founder.prefix
    }

payloadOf :: Intent -> Json
payloadOf = case _ of
  IAdd x -> addP x
  IRemove x -> removeP x
  IGrant x -> grantP x
  IRevoke x -> revokeP x
  ILeave -> leaveP
  IApp d -> appP d

-- | The Lean `applyCore` effect of an admitted action, on sets.
effect :: String -> Intent -> World -> World
effect s i w = case i of
  IAdd x -> w { members = Set.insert x w.members }
  IRemove x -> w { members = Set.delete x w.members, admins = Set.delete x w.admins }
  IGrant x -> w { admins = Set.insert x w.admins }
  IRevoke x -> w { admins = Set.delete x w.admins }
  ILeave -> w { members = Set.delete s w.members, admins = Set.delete s w.admins }
  IApp _ -> w

-- | Sign an action of `s` against the head and append it.
act :: String -> Intent -> World -> World
act s i w = actAt w.head s i w

-- | Sign an action of `s` extending `prev` (not necessarily the head)
-- | and append it to the signer's KEL; the head becomes this action and
-- | the oracle applies its effect.
actAt :: String -> String -> Intent -> World -> World
actAt prev s i w = case ident s w of
  Nothing -> w
  Just id ->
    let
      Tuple se id' = interact [ actionAnchor w.group prev (payloadOf i) ] id
    in
      effect s i w
        { ids = Map.insert s id' w.ids
        , head = digestOf se
        , log = Array.snoc w.log { signer: s, digest: digestOf se, event: se }
        }

-- | Rotate an identity's keys.
rotateIn :: String -> World -> Gen World
rotateIn s w = case ident s w of
  Nothing -> pure w
  Just id -> do
    ks <- genKeys
    let Tuple _ id' = rotate ks id
    pure w { ids = Map.insert s id' w.ids }

-- | Every identity's KEL, by prefix.
kels :: World -> Array (Tuple String (Array SignedEvent))
kels w = map (\(Tuple p id) -> Tuple p id.events) (Map.toUnfoldable w.ids)

-- | Every KEL but those of these prefixes.
kelsWithout :: Array String -> World -> Array (Tuple String (Array SignedEvent))
kelsWithout ps w = Array.filter (\(Tuple p _) -> not (Array.elem p ps)) (kels w)

-- | A group founded by `a`, with `b` added as a plain member; `c` and
-- | `u` hosted outside it.
type Team = { world :: World, a :: String, b :: String, c :: String, u :: String }

genTeam :: Gen Team
genTeam = do
  a <- incept <$> genKeys <*> genKeys
  b <- incept <$> genKeys <*> genKeys
  c <- incept <$> genKeys <*> genKeys
  u <- incept <$> genKeys <*> genKeys
  let w = act a.prefix (IAdd b.prefix) (found a [ b, c, u ])
  pure { world: w, a: a.prefix, b: b.prefix, c: c.prefix, u: u.prefix }

-- | `n` legal steps: actions by members that the rule admits, and
-- | rotations of any identity.
genRun :: Int -> World -> Gen World
genRun n w
  | n <= 0 = pure w
  | otherwise =
      do
        let
          everyone = Array.fromFoldable (Map.keys w.ids)
          ms = Array.fromFoldable w.members
          as = Array.fromFoldable w.admins
          nonMembers = Array.filter (\x -> not (Set.member x w.members)) everyone
          plain = Array.filter (\x -> not (Set.member x w.admins)) ms
          guardAfter s i = guardOk (effect s i w)
          candidates = Array.concat
            [ do
                s <- as
                x <- nonMembers
                pure (Tuple s (IAdd x))
            , do
                s <- as
                x <- ms
                if guardAfter s (IRemove x) then pure (Tuple s (IRemove x)) else []
            , do
                s <- as
                x <- plain
                pure (Tuple s (IGrant x))
            , do
                s <- as
                x <- as
                if guardAfter s (IRevoke x) then pure (Tuple s (IRevoke x)) else []
            , do
                s <- ms
                if guardAfter s ILeave then pure (Tuple s ILeave) else []
            , do
                s <- ms
                pure (Tuple s (IApp (fromString s)))
            ]
        k <- chooseInt 0 4
        w' <- case NEA.fromArray candidates, NEA.fromArray everyone of
          Just cs, _ | k > 0 -> do
            Tuple s i <- elements cs
            pure (act s i w)
          _, Just es -> do
            s <- elements es
            rotateIn s w
          _, _ -> pure w
        genRun (n - 1) w'
      where
      guardOk v = Set.isEmpty v.members || not (Set.isEmpty v.admins)

-- | Two groups over the same identities: `one` and `two` hold the same
-- | KELs, each its own group, head, log and roster.
type Pair = { one :: World, two :: World }

-- | A second group founded by `s` over the identities of `w`.
foundAlso :: String -> World -> Pair
foundAlso s w = case ident s w of
  Nothing -> { one: w, two: w }
  Just id ->
    let
      Tuple se id' = interact [ genesisAnchor ] id
      g = digestOf se
      ids = Map.insert s id' w.ids
    in
      { one: w { ids = ids }
      , two:
          { ids
          , group: g
          , head: g
          , log: [ { signer: s, digest: g, event: se } ]
          , members: Set.singleton s
          , admins: Set.singleton s
          }
      }

-- | Act in the first group; the second sees the same KELs after.
onOne :: (World -> Gen World) -> Pair -> Gen Pair
onOne f p = do
  one <- f p.one
  pure { one, two: p.two { ids = one.ids } }

-- | Act in the second group; the first sees the same KELs after.
onTwo :: (World -> Gen World) -> Pair -> Gen Pair
onTwo f p = do
  two <- f p.two
  pure { one: p.one { ids = two.ids }, two }

-- | A team whose `b` founds a second group adding `a`, then `n` legal
-- | steps interleaved between the two groups.
genPair :: Int -> Gen { team :: Team, pair :: Pair }
genPair n = do
  t <- genTeam
  let p0 = foundAlso t.b t.world
  p1 <- onTwo (pure <<< act t.b (IAdd t.a)) p0
  let
    go k p
      | k <= 0 = pure p
      | otherwise = do
          side <- chooseInt 0 1
          p' <- if side == 0 then onOne (genRun 1) p else onTwo (genRun 1) p
          go (k - 1) p'
  pair <- go n p1
  pure { team: t, pair }
