{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : GroupWorld
Description : Legitimately signed membership scenarios and their oracle
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

A 'World' is a set of identities with their member KEL fixtures,
some hosted, and the hosted state reached by admitting signed
group actions one after the other through
'KelGroups.Group.admit'. Every event it holds was signed with the
identity's current keys against its current tip and the group's
current head, so it can be replayed against the store or over HTTP
in the order of 'wLog'.

The oracle is written from the specification, not from the code:
'r2' is the roster effect of requirement R2, 'd4' the first failing
check of data model D4 for an action signed by a hosted identity
against the current head (R3 and the last-admin guard), on rosters
seen as sets.
-}
module GroupWorld
    ( -- * Intents
      Intent (..)
    , intentPayload
    , intentTarget

      -- * Worlds
    , World (..)
    , worldOf
    , genIds
    , hostIn
    , signAt
    , sign
    , signAnchor
    , attempt
    , act
    , found
    , chainOf
    , eventsOf
    , rosterOf
    , headIn

      -- * Teams
    , Team (..)
    , genTeam

      -- * Oracle
    , Sets
    , sets
    , r2
    , d4

      -- * Generated runs
    , Step (..)
    , Op (..)
    , genRun
    ) where

import Data.Aeson (Value)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import GroupFixtures
    ( actWith
    , actionAnchor
    , appPayload
    , genAppData
    , genMember
    , genesisAnchor
    , leavePayload
    , memberPayload
    )
import KelGroups.Group
    ( GroupRefusal (..)
    , Hosted (..)
    , Roster (..)
    , admit
    , roster
    )
import KelGroups.Group qualified as Group
import KelGroups.Kel (replayKel)
import Keri.Event (eventDigest, eventPrefix)
import Keri.Kel (SignedEvent (..))
import MemberKelFixtures (Chain (..))
import MemberKelFixtures qualified as F
import Test.QuickCheck (Gen, chooseInt, elements, frequency, vectorOf)

-- --------------------------------------------------------
-- Intents
-- --------------------------------------------------------

-- | What an action means to do, in the words of R1.
data Intent
    = IGenesis
    | IAdd Text
    | IRemove Text
    | IGrant Text
    | IRevoke Text
    | ILeave
    | IApp Value
    deriving stock (Show, Eq)

-- | The payload of an intent in the wire form of D1.
intentPayload :: Intent -> Value
intentPayload = \case
    IGenesis -> genesisAnchor
    IAdd x -> memberPayload "add" x
    IRemove x -> memberPayload "remove" x
    IGrant x -> memberPayload "grant" x
    IRevoke x -> memberPayload "revoke" x
    ILeave -> leavePayload
    IApp d -> appPayload d

-- | The member an intent names, if any.
intentTarget :: Intent -> Maybe Text
intentTarget = \case
    IAdd x -> Just x
    IRemove x -> Just x
    IGrant x -> Just x
    IRevoke x -> Just x
    _ -> Nothing

-- --------------------------------------------------------
-- Worlds
-- --------------------------------------------------------

-- | Identities, their KEL fixtures, and the hosted state.
data World = World
    { wIds :: Map Text F.Chain
    -- ^ every identity's KEL fixture at its current tip
    , wHosted :: Hosted
    , wLog :: [SignedEvent]
    -- ^ every hosted or admitted event, in submission order
    }

instance Show World where
    show w = "World " <> show (Map.keys (wIds w))

-- | Host the first KELs, keep the others as unhosted identities.
worldOf :: [F.Chain] -> [F.Chain] -> World
worldOf hosted unhosted =
    foldl
        (flip hostIn)
        World
            { wIds = Map.fromList [(chPrefix c, c) | c <- hosted <> unhosted]
            , wHosted = Hosted Map.empty Map.empty
            , wLog = []
            }
        (map chPrefix hosted)

-- | @n@ member KELs.
genIds :: Int -> Gen [F.Chain]
genIds n = vectorOf n genMember

-- | Host an identity's KEL (inception and rotations) with the KERI rule.
hostIn :: Text -> World -> World
hostIn pfx w@World{wIds, wHosted, wLog} =
    case chEvents (fixture pfx w) of
        e : es -> case replayKel e es of
            Right kel ->
                w
                    { wHosted =
                        wHosted
                            { hostedKels = Map.insert pfx kel (hostedKels wHosted)
                            }
                    , wLog = wLog <> (e : es)
                    , wIds
                    }
            Left r -> error ("hostIn: " <> show r)
        [] -> error "hostIn: empty KEL fixture"

fixture :: Text -> World -> F.Chain
fixture pfx w =
    fromMaybe (error ("unknown identity " <> show pfx)) $
        Map.lookup pfx (wIds w)

-- | An action of @s@ in group @g@ extending @prev@.
signAt :: Text -> Text -> Text -> Intent -> World -> SignedEvent
signAt g prev s i w = case i of
    IGenesis -> fst (actWith [genesisAnchor] (fixture s w))
    _ ->
        fst (actWith [actionAnchor g prev (intentPayload i)] (fixture s w))

-- | An interaction of @s@ carrying exactly this anchor.
signAnchor :: Text -> Value -> World -> SignedEvent
signAnchor s anchor w = fst (actWith [anchor] (fixture s w))

-- | An action of @s@ in group @g@ extending its current head.
sign :: Text -> Text -> Intent -> World -> SignedEvent
sign g s i w = signAt g (fromMaybe g (headIn g w)) s i w

-- | Admit an action through 'admit'; the world it leads to, or the refusal.
attempt :: SignedEvent -> World -> Either GroupRefusal World
attempt se w = do
    (h, _) <- admit (wHosted w) se
    let pfx = eventPrefix (event se)
        c = fixture pfx w
    pure
        w
            { wHosted = h
            , wIds =
                Map.insert
                    pfx
                    c
                        { chEvents = chEvents c <> [se]
                        , chSn = chSn c + 1
                        , chTip = eventDigest (event se)
                        }
                    (wIds w)
            , wLog = wLog w <> [se]
            }

-- | Sign and admit; a refusal is a broken setup.
act :: Text -> Text -> Intent -> World -> World
act g s i w =
    either (error . ("setup refused: " <>) . show) id $
        attempt (sign g s i w) w

-- | A genesis by @s@ and the group id it founds.
found :: Text -> World -> (Text, World)
found s w =
    let se = signAt "" "" s IGenesis w
    in  (eventDigest (event se), either (error . show) id (attempt se w))

-- | The KEL fixture events of an identity, as hosted.
eventsOf :: Text -> World -> [SignedEvent]
eventsOf pfx = chEvents . fixture pfx

-- | The chain of a group.
chainOf :: Text -> World -> Maybe Group.Chain
chainOf g = Map.lookup g . hostedChains . wHosted

-- | The roster of a group, as sets.
rosterOf :: Text -> World -> Maybe Sets
rosterOf g w = sets . roster <$> chainOf g w

-- | The head of a group.
headIn :: Text -> World -> Maybe Text
headIn g w = Group.head <$> chainOf g w

-- --------------------------------------------------------
-- Teams
-- --------------------------------------------------------

{- | A group founded by @a@: admins @a@ and @e@, plain members @b@
and @d@; @c@ hosted outside the group; @u@ and two more
identities not hosted.
-}
data Team = Team
    { tWorld :: World
    , tGroup :: Text
    , tA :: Text
    , tE :: Text
    , tB :: Text
    , tD :: Text
    , tC :: Text
    , tU :: Text
    }
    deriving stock (Show)

-- | A team, its setup interleaved with zero to two app actions.
genTeam :: Gen Team
genTeam = do
    a <- genMember
    e <- genMember
    b <- genMember
    d <- genMember
    c <- genMember
    u <- genMember
    others <- genIds 2
    d1 <- genAppData
    d2 <- genAppData
    k <- chooseInt (0, 2)
    let w0 = worldOf [a, e, b, d, c] (u : others)
        pa = chPrefix a
        pe = chPrefix e
        pb = chPrefix b
        pd = chPrefix d
        (g, w1) = found pa w0
        steps =
            [ (pa, IAdd pb)
            , (pa, IAdd pd)
            , (pb, IApp d1)
            , (pa, IAdd pe)
            , (pa, IGrant pe)
            , (pd, IApp d2)
            ]
        keep (s, i) = case i of
            IApp _ -> s == pb && k >= 1 || s == pd && k >= 2
            _ -> True
        w = foldl (\acc (s, i) -> act g s i acc) w1 (filter keep steps)
    pure
        Team
            { tWorld = w
            , tGroup = g
            , tA = pa
            , tE = pe
            , tB = pb
            , tD = pd
            , tC = chPrefix c
            , tU = chPrefix u
            }

-- --------------------------------------------------------
-- Oracle
-- --------------------------------------------------------

-- | Members and admins.
type Sets = (Set Text, Set Text)

-- | A roster seen as sets (D2: order is not observable).
sets :: Roster -> Sets
sets Roster{members, admins} = (Set.fromList members, Set.fromList admins)

-- | R2: the roster after an admitted action of signer @s@.
r2 :: Text -> Intent -> Sets -> Sets
r2 s i (ms, as) = case i of
    IGenesis -> (Set.singleton s, Set.singleton s)
    IAdd x -> (Set.insert x ms, as)
    IRemove x -> (Set.delete x ms, Set.delete x as)
    IGrant x -> (ms, Set.insert x as)
    IRevoke x -> (ms, Set.delete x as)
    ILeave -> (Set.delete s ms, Set.delete s as)
    IApp _ -> (ms, as)

{- | D4 for a non-genesis action of a hosted signer, correctly signed
against its tip and the group's head: the first failing check, from
"signer a member" on, or nothing when admissible.
-}
d4 :: (Text -> Bool) -> Text -> Intent -> Sets -> Maybe GroupRefusal
d4 hosted s i r@(ms, as) =
    firstFail
        [ (Set.member s ms, NotAMember)
        , (not needsAdmin || Set.member s as, NotAnAdmin)
        , (case i of IAdd x -> hosted x; _ -> True, MemberNotHosted)
        , targetState
        , (guardSets (r2 s i r), LastAdmin)
        ]
  where
    needsAdmin = case intentTarget i of
        Just _ -> True
        Nothing -> False
    targetState = case i of
        IAdd x -> (not (Set.member x ms), AlreadyMember)
        IRemove x -> (Set.member x ms, TargetNotMember)
        IGrant x
            | not (Set.member x ms) -> (False, TargetNotMember)
            | otherwise -> (not (Set.member x as), AlreadyAdmin)
        IRevoke x -> (Set.member x as, TargetNotAdmin)
        _ -> (True, NotAMember)
    guardSets (ms', as') = Set.null ms' || not (Set.null as')
    firstFail cs = case [r' | (ok, r') <- cs, not ok] of
        r' : _ -> Just r'
        [] -> Nothing

-- --------------------------------------------------------
-- Generated runs
-- --------------------------------------------------------

-- | One generated step and the worlds around it.
data Step = Step
    { stBefore :: World
    , stOp :: Op
    , stAfter :: World
    }
    deriving stock (Show)

-- | What a step did.
data Op
    = -- | An identity's KEL hosted
      HostOp Text
    | -- | An action of a signer in a group, and its admission
      ActOp
        { opGroup :: Text
        , opSigner :: Text
        , opIntent :: Intent
        , opResult :: Either GroupRefusal ()
        }
    deriving stock (Show)

{- | A sequence of @n@ steps from a world: hostings of unhosted
identities, geneses, and actions of every payload by hosted
identities (members and admins or not) naming hosted and unhosted
targets, each signed against the current tips and heads and
submitted to 'admit'.
-}
genRun :: Int -> World -> Gen [Step]
genRun n w
    | n <= 0 = pure []
    | otherwise = do
        let ids = Map.keys (wIds w)
            hostedIds = Map.keys (hostedKels (wHosted w))
            unhosted = filter (`notElem` hostedIds) ids
            groups = Map.keys (hostedChains (wHosted w))
        pick <-
            frequency $
                [(1, Left <$> elements unhosted) | not (null unhosted)]
                    <> [(1, pure (Right Nothing))]
                    <> [(20, Right . Just <$> elements groups) | not (null groups)]
        (op, w') <- case pick of
            Left pfx -> pure (HostOp pfx, hostIn pfx w)
            Right Nothing -> do
                s <- elements hostedIds
                let se = signAt "" "" s IGenesis w
                pure $ acted (eventDigest (event se)) s IGenesis se
            Right (Just g) -> do
                let (ms, as) = fromMaybe (Set.empty, Set.empty) (rosterOf g w)
                s <-
                    frequency $
                        [(4, elements (Set.toList as)) | not (Set.null as)]
                            <> [(3, elements (Set.toList ms)) | not (Set.null ms)]
                            <> [(1, elements hostedIds)]
                x <-
                    frequency $
                        [(3, elements (Set.toList ms)) | not (Set.null ms)]
                            <> [(2, elements (Set.toList as)) | not (Set.null as)]
                            <> [(2, elements ids)]
                            <> [(2, elements unhosted) | not (null unhosted)]
                            <> [(1, pure s)]
                d <- genAppData
                i <-
                    elements
                        [IAdd x, IRemove x, IGrant x, IRevoke x, ILeave, IApp d]
                pure $ acted g s i (sign g s i w)
        (Step w op w' :) <$> genRun (n - 1) w'
  where
    acted g s i se =
        let result = attempt se w
        in  ( ActOp
                { opGroup = g
                , opSigner = s
                , opIntent = i
                , opResult = () <$ result
                }
            , either (const w) id result
            )
