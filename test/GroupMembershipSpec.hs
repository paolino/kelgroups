{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : GroupMembershipSpec
Description : Membership actions and admin rules, pure
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

Checks of 'KelGroups.Group.admit' on membership actions (add,
remove, grant, revoke, leave) signed with real keys against the
current tips and heads of a 'Team' or of generated sequences.
Expected outcomes are those of requirements R2 and R3, data model
D4 and the Lean @membershipOk@ and @admin_guard@, through the
oracle of "GroupWorld".
-}
module GroupMembershipSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.List (foldl')
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GroupFixtures
    ( actionAnchor
    , appPayload
    , genAppData
    , leavePayload
    , memberPayload
    )
import GroupWorld
    ( Intent (..)
    , Op (..)
    , Step (..)
    , Team (..)
    , World (..)
    , act
    , attempt
    , chainOf
    , d4
    , found
    , genRun
    , genTeam
    , hostIn
    , r2
    , rosterOf
    , sets
    , sign
    , signAnchor
    )
import KelGroups.Group
    ( GroupRefusal (..)
    , Hosted (..)
    , Roster (..)
    , chainActions
    , decodeAction
    , membershipOk
    , rebuildChains
    , roster
    )
import KelGroups.Group qualified as Group
import Test.Hspec (Spec, describe)
import Test.Hspec.QuickCheck (modifyMaxSuccess, prop)
import Test.QuickCheck
    ( Property
    , checkCoverage
    , conjoin
    , counterexample
    , cover
    , forAll
    , property
    , (===)
    )

refusedWith :: GroupRefusal -> Either GroupRefusal World -> Property
refusedWith r x = (() <$ x) === Left r

admitted :: Either GroupRefusal World -> Property
admitted = \case
    Right _ -> property True
    Left r -> counterexample ("refused: " <> show r) False

-- | The world an admitted action leads to; a refusal fails.
admittedThen
    :: Either GroupRefusal World -> (World -> Property) -> Property
admittedThen x k = either (\r -> counterexample ("refused: " <> show r) False) k x

notAGroupAction :: Either GroupRefusal a -> Property
notAGroupAction = \case
    Left (NotAGroupAction _) -> property True
    Left r -> counterexample ("refused otherwise: " <> show r) False
    Right _ -> counterexample "admitted" False

spec :: Spec
spec = describe "KelGroups.Group (membership rule)" $
    modifyMaxSuccess (const 20) $ do
        prop
            "INV-40-ADMIN/rule: a current non-admin member's add, remove, \
            \grant or revoke, otherwise valid, is refused notAnAdmin; the \
            \same action by an admin is admitted"
            $ forAll genTeam
            $ \Team{..} ->
                let w = tWorld
                in  conjoin
                        [ counterexample (show i) $
                            conjoin
                                [ refusedWith NotAnAdmin $
                                    attempt (sign tGroup s i w) w
                                , admitted $ attempt (sign tGroup tA i w) w
                                ]
                        | i <- [IAdd tC, IRemove tD, IGrant tD, IRevoke tE]
                        , s <- [tB, tD]
                        , Just s /= target i
                        ]

        prop
            "INV-40-LAST-ADMIN/rule: with other members and no other admin \
            \the last admin's leave, revoke and remove of itself are \
            \refused lastAdmin; as sole member its revoke of itself is \
            \refused and its leave admitted (roster empty); with a second \
            \admin the same actions are admitted"
            $ forAll genTeam
            $ \Team{..} ->
                let selfActs = [ILeave, IRevoke tA, IRemove tA]
                    lone = act tGroup tA (IRevoke tE) tWorld
                    (g1, sole) = found tA tWorld
                in  conjoin
                        [ counterexample "other members, no other admin" $
                            conjoin
                                [ counterexample (show i) $
                                    refusedWith LastAdmin $
                                        attempt (sign tGroup tA i lone) lone
                                | i <- selfActs
                                ]
                        , counterexample "sole member, revoke" $
                            refusedWith LastAdmin $
                                attempt (sign g1 tA (IRevoke tA) sole) sole
                        , counterexample "sole member, leave" $
                            admittedThen (attempt (sign g1 tA ILeave sole) sole) $
                                \w -> rosterOf g1 w === Just (Set.empty, Set.empty)
                        , counterexample "sole member, remove of itself"
                            $ admittedThen
                                (attempt (sign g1 tA (IRemove tA) sole) sole)
                            $ \w -> rosterOf g1 w === Just (Set.empty, Set.empty)
                        , counterexample "second admin" $
                            conjoin
                                [ counterexample (show i)
                                    $ admittedThen
                                        (attempt (sign tGroup tA i tWorld) tWorld)
                                    $ \w ->
                                        rosterOf tGroup w
                                            === ( r2 tA i
                                                    <$> rosterOf tGroup tWorld
                                                )
                                | i <- selfActs
                                ]
                        ]

        prop
            "INV-40-ADD-HOSTED/rule: an admin's add of an identity with no \
            \hosted KEL is refused memberNotHosted; once that KEL is \
            \hosted the same add is admitted"
            $ forAll genTeam
            $ \Team{..} ->
                let se = sign tGroup tA (IAdd tU) tWorld
                    w' = hostIn tU tWorld
                in  conjoin
                        [ refusedWith MemberNotHosted (attempt se tWorld)
                        , admittedThen (attempt se w') $ \w ->
                            fmap (Set.member tU . fst) (rosterOf tGroup w)
                                === Just True
                        ]

        prop
            "INV-40-REMOVED/rule: after x is removed its earlier actions \
            \stay in the chain, the roster replays without x, the chains \
            \rebuild identically from the KELs; x's new action is refused \
            \notAMember; x may be added again"
            $ forAll ((,,) <$> genTeam <*> genAppData <*> genAppData)
            $ \(Team{..}, d1, d2) ->
                let before = sign tGroup tB (IApp d1) tWorld
                    w1 = act tGroup tB (IApp d1) tWorld
                    w2 = act tGroup tA (IRemove tB) w1
                    chainSigned w =
                        maybe [] (map Group.signed . chainActions) (chainOf tGroup w)
                in  conjoin
                        [ counterexample "earlier action dropped" $
                            property (before `elem` chainSigned w2)
                        , chainSigned w2 === chainSigned w1 <> [last (wLog w2)]
                        , fmap fst (rosterOf tGroup w2)
                            === fmap (Set.delete tB . fst) (rosterOf tGroup w1)
                        , fmap (sets . roster) (chainOf tGroup w2)
                            === rosterOf tGroup w2
                        , rebuildChains (hostedKels (wHosted w2))
                            === Right (hostedChains (wHosted w2))
                        , refusedWith NotAMember $
                            attempt (sign tGroup tB (IApp d2) w2) w2
                        , admitted $ attempt (sign tGroup tA (IAdd tB) w2) w2
                        ]

        prop
            "INV-40-STATE/rule: add of a member, remove or grant of a \
            \non-member, grant of an admin, revoke of a non-admin are \
            \refused alreadyMember, targetNotMember, alreadyAdmin, \
            \targetNotAdmin; valid targets are admitted"
            $ forAll genTeam
            $ \Team{..} ->
                let w = tWorld
                    try' i = attempt (sign tGroup tA i w) w
                in  conjoin
                        [ refusedWith AlreadyMember (try' (IAdd tB))
                        , refusedWith AlreadyMember (try' (IAdd tE))
                        , refusedWith TargetNotMember (try' (IRemove tC))
                        , refusedWith TargetNotMember (try' (IGrant tC))
                        , refusedWith AlreadyAdmin (try' (IGrant tE))
                        , refusedWith TargetNotAdmin (try' (IRevoke tB))
                        , refusedWith TargetNotAdmin (try' (IRevoke tC))
                        , admitted (try' (IAdd tC))
                        , admitted (try' (IRemove tB))
                        , admitted (try' (IGrant tB))
                        , admitted (try' (IRevoke tE))
                        ]

        prop
            "INV-40-LEAVE/rule: a non-admin member's leave is admitted and \
            \its later actions are refused notAMember; a non-member's \
            \leave is refused notAMember"
            $ forAll ((,) <$> genTeam <*> genAppData)
            $ \(Team{..}, d) ->
                let w = tWorld
                in  conjoin
                        [ admittedThen (attempt (sign tGroup tB ILeave w) w) $ \w' ->
                            conjoin
                                [ rosterOf tGroup w' === (r2 tB ILeave <$> rosterOf tGroup w)
                                , refusedWith NotAMember $
                                    attempt (sign tGroup tB (IApp d) w') w'
                                , refusedWith NotAMember $
                                    attempt (sign tGroup tB ILeave w') w'
                                ]
                        , refusedWith NotAMember $ attempt (sign tGroup tC ILeave w) w
                        ]

        prop
            "INV-40-SHAPE/rule: membership payloads with a missing or extra \
            \key, or a non-string member, are not group actions"
            $ forAll genTeam
            $ \Team{..} ->
                let w = tWorld
                    hd = maybe tGroup Group.head (chainOf tGroup w)
                    anchored pl = actionAnchor tGroup hd pl
                    t' t kvs = object (("t" .= (t :: Text)) : kvs)
                    shapes =
                        concat
                            [ [ (t <> " without member", anchored (t' t []))
                              ,
                                  ( t <> " with an extra key"
                                  , anchored (t' t ["member" .= tC, "x" .= (1 :: Int)])
                                  )
                              , (t <> " member a number", anchored (t' t ["member" .= (1 :: Int)]))
                              , (t <> " member null", anchored (t' t ["member" .= Null]))
                              , (t <> " member a list", anchored (t' t ["member" .= [tC]]))
                              ]
                            | t <- ["add", "remove", "grant", "revoke"]
                            ]
                            <> [ ("leave with a member", anchored (t' "leave" ["member" .= tB]))
                               , ("leave with an extra key", anchored (t' "leave" ["x" .= (1 :: Int)]))
                               ,
                                   ( "add in a genesis-shaped anchor"
                                   , object ["payload" .= memberPayload "add" tC]
                                   )
                               ,
                                   ( "add without prev"
                                   , object
                                        ["group" .= tGroup, "payload" .= memberPayload "add" tC]
                                   )
                               ]
                in  conjoin $
                        [ counterexample (T.unpack what) $
                            notAGroupAction (attempt (signAnchor tA anchor w) w)
                        | (what, anchor) <- shapes
                        ]
                            <> [ admitted $
                                    attempt
                                        (signAnchor tA (anchored (memberPayload "add" tC)) w)
                                        w
                               , admitted $
                                    attempt (signAnchor tB (anchored leavePayload) w) w
                               , admitted $
                                    attempt
                                        (signAnchor tB (anchored (appPayload (String "x"))) w)
                                        w
                               ]

        prop
            "INV-40-ORDER/rule: with two failing checks the earlier one of \
            \D4 decides; target state before the last-admin guard, on a \
            \roster no admission reaches (admin not a member)"
            $ forAll genTeam
            $ \Team{..} ->
                let se = sign tGroup tA (IRemove tA) tWorld
                in  case decodeAction se of
                        Left r -> counterexample (show r) False
                        Right a ->
                            membershipOk (const True) (Roster [tB] [tA]) a
                                === Left TargetNotMember

        modifyMaxSuccess (const 100) $ do
            prop
                "INV-40-GUARD/rule: over generated sequences of signed \
                \actions admitted through admit, every roster has no \
                \members or an admin and every admin is a member; an action \
                \is admitted iff R3 holds at its position"
                $ forAll genTeam
                $ \Team{tWorld} -> forAll (genRun 40 tWorld) $ \steps ->
                    checkCoverage $ coverRun steps $ conjoin $ map guardStep steps

            prop
                "INV-40-ROSTER/rule: over generated sequences, every admitted \
                \action changes its group's roster exactly as R2 and no \
                \other roster"
                $ forAll genTeam
                $ \Team{tWorld} -> forAll (genRun 40 tWorld) $ \steps ->
                    checkCoverage $ coverRun steps $ conjoin $ map rosterStep steps

            prop
                "INV-40-ORDER/rule: over generated sequences, every refusal is \
                \the first failing check of D4"
                $ forAll genTeam
                $ \Team{tWorld} -> forAll (genRun 40 tWorld) $ \steps ->
                    checkCoverage $ coverRun steps $ conjoin $ map orderStep steps
  where
    target = \case
        IAdd x -> Just x
        IRemove x -> Just x
        IGrant x -> Just x
        IRevoke x -> Just x
        _ -> Nothing

-- | Rosters of every group of a world, as sets.
rosters :: World -> Map.Map Text (Set.Set Text, Set.Set Text)
rosters w = Map.map (sets . roster) (hostedChains (wHosted w))

hostedIn :: World -> Text -> Bool
hostedIn w x = Map.member x (hostedKels (wHosted w))

-- | The D4 verdict for an action of a step, from the world before it.
expected :: World -> Text -> Text -> Intent -> Maybe GroupRefusal
expected w g s i = case i of
    IGenesis -> Nothing
    _ -> d4 (hostedIn w) s i (Map.findWithDefault empty g (rosters w))
  where
    empty = (Set.empty, Set.empty)

guardStep :: Step -> Property
guardStep Step{..} =
    conjoin $
        [ counterexample ("guard broken in " <> show g <> ": " <> show r) $
            property (guardOk' r && Set.isSubsetOf (snd r) (fst r))
        | (g, r) <- Map.toList (rosters stAfter)
        ]
            <> case stOp of
                HostOp _ -> []
                ActOp{..} ->
                    [ counterexample (show stOp) $
                        either (const False) (const True) opResult
                            === isNothing (expected stBefore opGroup opSigner opIntent)
                    ]
  where
    guardOk' (ms, as) = Set.null ms || not (Set.null as)

rosterStep :: Step -> Property
rosterStep Step{..} = case stOp of
    HostOp _ -> rosters stAfter === rosters stBefore
    ActOp{..} -> counterexample (show stOp) $ case opResult of
        Left _ -> rosters stAfter === rosters stBefore
        Right () ->
            let before = rosters stBefore
                prior = Map.findWithDefault (Set.empty, Set.empty) opGroup before
            in  rosters stAfter
                    === Map.insert opGroup (r2 opSigner opIntent prior) before

orderStep :: Step -> Property
orderStep Step{..} = case stOp of
    HostOp _ -> property True
    ActOp{..} ->
        counterexample (show stOp) $
            opResult
                === maybe (Right ()) Left (expected stBefore opGroup opSigner opIntent)

-- | Every payload admitted and every refusal class reached, per run.
coverRun :: [Step] -> Property -> Property
coverRun steps =
    foldl'
        (\p (label, hit) -> cover 15 hit label . p)
        id
        ( [ ("admitted " <> name, any (admittedOf f) steps)
          | (name, f) <- kinds
          ]
            <> [ ("refused " <> show r, any (refusedOf r) steps)
               | r <-
                    [ NotAMember
                    , NotAnAdmin
                    , MemberNotHosted
                    , AlreadyMember
                    , TargetNotMember
                    , AlreadyAdmin
                    , TargetNotAdmin
                    , LastAdmin
                    ]
               ]
        )
  where
    kinds =
        [ ("genesis", \case IGenesis -> True; _ -> False)
        , ("add", \case IAdd _ -> True; _ -> False)
        , ("remove", \case IRemove _ -> True; _ -> False)
        , ("grant", \case IGrant _ -> True; _ -> False)
        , ("revoke", \case IRevoke _ -> True; _ -> False)
        , ("leave", \case ILeave -> True; _ -> False)
        , ("app", \case IApp _ -> True; _ -> False)
        ]
    admittedOf f Step{stOp} = case stOp of
        ActOp{opIntent, opResult = Right ()} -> f opIntent
        _ -> False
    refusedOf r Step{stOp} = case stOp of
        ActOp{opResult = Left r'} -> r == r'
        _ -> False
