{- |
Module      : VotePropertySpec
Description : The Lean vote theorems as QuickCheck properties
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

The theorems of @lean/KelGroups/Vote/Invariants.lean@ that are
statements about @foldVote@, @applyVoteEvent@, @sweepClosures@ and
@validateVoteEvent@, over generated rosters, thresholds, payloads and
signed traces; the invariants of the spec that have no Lean theorem
name; and a differential check of every exported function against
the independent transcription in "VoteReference", list order included.
-}
module VotePropertySpec
    ( spec
    ) where

import Data.List (isPrefixOf, nub)
import Data.Maybe (isJust)
import Data.Text (Text)
import KelGroups.GroupView (GroupView)
import KelGroups.Vote.Event (VoteEvent (..))
import KelGroups.Vote.Fold
    ( applyVoteEvent
    , applyVoteEventChecked
    , closeProposerQuestions
    , effectedState
    , foldFrom
    , foldVote
    , placeBallot
    , sweepClosures
    , sweepStep
    )
import KelGroups.Vote.State
    ( ClosureRecord (..)
    , Question (..)
    , VoteState (..)
    , closureCauseOf
    , emptyVoteState
    , franchise
    , franchiseSize
    , isResponsabile
    , lookupQuestion
    , verdictOf
    )
import KelGroups.Vote.Types
    ( Ballot (..)
    , ClosureCause (..)
    , QuestionKind (..)
    , Threshold
    , Verdict (..)
    )
import KelGroups.Vote.Validate (VoteError (..), validateVoteEvent)
import Test.Hspec (Spec, describe)
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
    ( Gen
    , Property
    , checkCoverage
    , choose
    , conjoin
    , cover
    , elements
    , forAll
    , property
    , (.&&.)
    , (===)
    , (==>)
    )
import VoteFixtures
import VoteReference

-- | A threshold, a view and a signed trace.
type Scenario = (Policy, GroupView, [(Text, VoteEvent)])

genScenario :: Gen Scenario
genScenario = do
    p <- genPolicy
    v <- genView
    evs <- genTraceFor (policyThreshold p) v
    pure (p, v, evs)

-- | A view and a trace under the threshold no tally reaches.
genUnreachableScenario :: Gen (GroupView, [(Text, VoteEvent)])
genUnreachableScenario = do
    v <- genView
    evs <- genTraceFor unreachable v
    pure (v, evs)

-- | A threshold no collective tally of the generated sizes can reach.
unreachable :: Threshold
unreachable = const 1000

prefixes :: [a] -> [[a]]
prefixes xs = [take n xs | n <- [0 .. length xs]]

openIds :: VoteState -> [Text]
openIds = map fst . openQuestions

closedIds :: VoteState -> [Text]
closedIds = map closureQuestionId . closed

clean :: Question -> Bool
clean q =
    nub (questionAssents q) == questionAssents q
        && nub (questionDissents q) == questionDissents q
        && not (any (`elem` questionDissents q) (questionAssents q))

tallyKeys :: VoteState -> [Text]
tallyKeys gs =
    concat
        [questionAssents q <> questionDissents q | (_, q) <- openQuestions gs]
        <> concat
            [ questionAssents q <> questionDissents q
            | r <- closed gs
            , let q = closureQuestion r
            ]

spec :: Spec
spec = describe "Vote properties" $ do
    describe
        "vote-machine-follows-lean: the library against a second transcription"
        $ do
            prop "foldVote is the reference fold, list order included" $
                forAll genScenario $ \(p, v, evs) ->
                    foldVote (policyThreshold p) v evs
                        === refFold (policyThreshold p) v evs

            prop "foldFrom continues the fold from any payload" $
                forAll ((,,) <$> genPolicy <*> genView <*> genRawState) $ \(p, v, gs) ->
                    forAll genRawTrace $ \evs ->
                        foldFrom (policyThreshold p) v gs evs
                            === refFoldFrom (policyThreshold p) v gs evs

            prop "foldVote is foldFrom from the empty payload" $
                forAll genScenario $ \(p, v, evs) ->
                    foldVote (policyThreshold p) v evs
                        === foldFrom (policyThreshold p) v emptyVoteState evs

            prop "one step, from an arbitrary payload, is the reference step" $
                forAll ((,,,) <$> genPolicy <*> genView <*> genRawState <*> genSigned) $
                    \(p, v, gs, (s, e)) ->
                        applyVoteEvent (policyThreshold p) v gs s e
                            === refStep (policyThreshold p) v gs s e

            prop "the checked step is the reference checked step" $
                forAll ((,,,) <$> genPolicy <*> genView <*> genRawState <*> genSigned) $
                    \(p, v, gs, (s, e)) ->
                        applyVoteEventChecked (policyThreshold p) v gs s e
                            === refChecked (policyThreshold p) v gs s e

            prop "validateVoteEvent is the reference validation" $
                forAll ((,,,) <$> genPolicy <*> genView <*> genRawState <*> genSigned) $
                    \(p, v, gs, (s, e)) ->
                        validateVoteEvent (policyThreshold p) v gs s e
                            === refValidate v gs s e

            prop "sweepClosures is the reference sweep, on any payload" $
                forAll ((,,) <$> genPolicy <*> genView <*> genRawState) $ \(p, v, gs) ->
                    sweepClosures (policyThreshold p) v gs
                        === refSweep (policyThreshold p) v gs

            prop "effectedState is the reference effect, on any payload" $
                forAll ((,) <$> genRawState <*> genSigned) $ \(gs, (s, e)) ->
                    effectedState gs s e === refEffect gs s e

            prop
                "closeProposerQuestions is the reference departure, on any payload"
                $ forAll ((,) <$> genKey <*> genRawState)
                $ \(k, gs) ->
                    closeProposerQuestions k gs === refDepart k gs

            prop "verdictOf and the closure cause are the reference ones" $
                forAll ((,,) <$> genPolicy <*> genView <*> genRawQuestion) $
                    \(p, v, q) ->
                        let th = policyThreshold p
                            verdict = verdictOf th v q
                        in  verdict === refVerdict th v q
                                .&&. conjoin
                                    [ closureCauseOf v q x === refCause v q x
                                    | x <- [Positive, Negative, Open]
                                    ]

            prop "placeBallot is the reference placement, on any question"
                $ forAll
                    ((,,) <$> genKey <*> elements [Assent, Dissent] <*> genRawQuestion)
                $ \(k, b, q) -> placeBallot k b q === refPlace k b q

            prop
                "sweepStep closes exactly the questions whose verdict is not open"
                $ forAll ((,,) <$> genPolicy <*> genView <*> genRawQuestion)
                $ \(p, v, q) ->
                    let th = policyThreshold p
                    in  sweepStep th v ("q", q) === case refVerdict th v q of
                            Open -> Nothing
                            x -> Just (ClosureRecord "q" q x (refCause v q x))

            prop "franchise is the view's admins, and its size their number" $
                forAll genView $ \v ->
                    toInteger (franchiseSize v) === toInteger (length (franchise v))

    describe "ballots_nodup_disjoint" $
        prop "every tally of a folded payload is duplicate-free and disjoint" $
            forAll genScenario $ \(p, v, evs) ->
                let gs = foldVote (policyThreshold p) v evs
                in  all (clean . snd) (openQuestions gs)
                        .&&. all (clean . closureQuestion) (closed gs)

    describe "open_questions_are_open" $
        prop "no open question of a folded payload already has a verdict" $
            forAll genScenario $ \(p, v, evs) ->
                let th = policyThreshold p
                    gs = foldVote th v evs
                in  all ((== Open) . verdictOf th v . snd) (openQuestions gs)

    describe "questions_partition" $ do
        prop "open ids, closed ids are unique and apart; no closure is open" $
            forAll genScenario $ \(p, v, evs) ->
                let gs = foldVote (policyThreshold p) v evs
                in  nub (openIds gs) === openIds gs
                        .&&. nub (closedIds gs) === closedIds gs
                        .&&. all (`notElem` closedIds gs) (openIds gs)
                        .&&. all ((/= Open) . closureVerdict) (closed gs)

        prop
            "a question open or closed after a prefix is open or closed after the trace"
            $ forAll genScenario
            $ \(p, v, evs) ->
                let th = policyThreshold p
                    whole = foldVote th v evs
                    seen gs = openIds gs <> closedIds gs
                in  all
                        (\pre -> all (`elem` seen whole) (seen (foldVote th v pre)))
                        (prefixes evs)

    describe "closure-is-never-silent"
        $ prop
            "a question leaves the open set only with a record appended after the log"
        $ forAll genScenario
        $ \(p, v, evs) ->
            let th = policyThreshold p
                step (gs, ok) (s, e) =
                    let gs' = applyVoteEvent th v gs s e
                        added = drop (length (closed gs)) (closed gs')
                        left = [i | i <- openIds gs, i `notElem` openIds gs']
                        good =
                            closed gs `isPrefixOf` closed gs'
                                && all (`elem` map closureQuestionId added) left
                                && all ((`notElem` openIds gs') . closureQuestionId) added
                    in  (gs', ok && good)
            in  property (snd (foldl step (emptyVoteState, True) evs))

    describe "no_expiry" $
        prop "an open question an event leaves as it was still has no verdict" $
            forAll genScenario $ \(p, v, evs) ->
                forAll genSigned $ \(s, e) ->
                    let th = policyThreshold p
                        pre = foldVote th v evs
                        post = applyVoteEvent th v pre s e
                    in  all
                            ( \(i, q) ->
                                lookupQuestion i post /= Just q
                                    || verdictOf th v q == Open
                            )
                            (openQuestions pre)

    describe "inadmissible_is_noop" $ do
        prop "a refused event leaves any payload exactly as it was" $
            forAll ((,,,) <$> genPolicy <*> genView <*> genRawState <*> genSigned) $
                \(p, v, gs, (s, e)) ->
                    let th = policyThreshold p
                    in  case validateVoteEvent th v gs s e of
                            Left _ -> applyVoteEvent th v gs s e === gs
                            Right () -> property True

        prop
            "refusals are the four typed errors, and the checked step reports the same one"
            $ forAll ((,,,) <$> genPolicy <*> genView <*> genRawState <*> genSigned)
            $ \(p, v, gs, (s, e)) ->
                let th = policyThreshold p
                in  case validateVoteEvent th v gs s e of
                        Left err ->
                            applyVoteEventChecked th v gs s e === Left err
                                .&&. property
                                    ( err
                                        `elem` [NotResponsabile, QuestionNotFound, NotDesignee, NotProposer]
                                    )
                        Right () -> property True

    describe "nonresponsabile_event_noop"
        $ prop
            "a signer who is no responsabile moves nothing, for every constructor"
        $ forAll ((,,) <$> genPolicy <*> genView <*> genRawState)
        $ \(p, v, gs) ->
            forAll genEvent $ \e ->
                forAnyOf (strangersOf v) $ \s ->
                    franchiseSize v > 0 ==>
                        validateVoteEvent (policyThreshold p) v gs s e
                            === Left NotResponsabile
                            .&&. applyVoteEvent (policyThreshold p) v gs s e === gs

    describe "unfranchised_cast_noop" $
        prop "a cast by a non-responsabile is a no-op on any payload" $
            forAll ((,,) <$> genPolicy <*> genView <*> genRawState) $ \(p, v, gs) ->
                forAll ((,) <$> genQid <*> elements [Assent, Dissent]) $ \(q, b) ->
                    forAnyOf (strangersOf v) $ \s ->
                        applyVoteEvent (policyThreshold p) v gs s (Cast q b) === gs

    describe "franchise_of_tallies" $
        prop "every key in a tally cast, as a responsabile, in the trace" $
            forAll genScenario $ \(p, v, evs) ->
                let gs = foldVote (policyThreshold p) v evs
                in  all
                        ( \k ->
                            isResponsabile k v
                                && any
                                    ( \(s, e) ->
                                        s == k && case e of
                                            Cast _ _ -> True
                                            _ -> False
                                    )
                                    evs
                        )
                        (tallyKeys gs)

    describe "sweepClosures_idempotent" $
        prop "sweeping a swept payload changes nothing, on any payload" $
            forAll ((,,) <$> genPolicy <*> genView <*> genRawState) $ \(p, v, gs) ->
                let th = policyThreshold p
                    once = sweepClosures th v gs
                in  sweepClosures th v once === once

    describe "foldVote_wellFormed" $
        prop "a folded payload is sweep-ready and has no stale open question" $
            forAll genScenario $ \(p, v, evs) ->
                let th = policyThreshold p
                    gs = foldVote th v evs
                in  nub (openIds gs) === openIds gs
                        .&&. nub (closedIds gs) === closedIds gs
                        .&&. all (`notElem` closedIds gs) (openIds gs)
                        .&&. all (clean . snd) (openQuestions gs)
                        .&&. all (clean . closureQuestion) (closed gs)
                        .&&. all ((/= Open) . closureVerdict) (closed gs)
                        .&&. all ((== Open) . verdictOf th v . snd) (openQuestions gs)

    describe "verdictOf_threshold_congr"
        $ prop
            "two thresholds that agree at the franchise size give one verdict"
        $ forAll ((,,) <$> genPolicy <*> genPolicy <*> genView)
        $ \(p, p', v) ->
            forAll genRawQuestion $ \q ->
                let th = policyThreshold p
                    n = franchiseSize v
                    th' m = if m == n then th n else policyThreshold p' m
                in  verdictOf th v q === verdictOf th' v q

    describe "proposer-is-not-an-assent (#68)"
        $ prop
            "a new question opens with both tallies empty, the signer its proposer"
        $ forAll ((,) <$> genUnreachableScenario <*> genQid)
        $ \((v, evs), qid) ->
            forAll genKind $ \kind ->
                forAnyOf (responsabiliOf v) $ \k ->
                    let pre = foldVote unreachable v evs
                        post = applyVoteEvent unreachable v pre k (OpenQuestion qid kind)
                        known =
                            isJust (lookupQuestion qid pre)
                                || qid `elem` closedIds pre
                    in  if known
                            then post === pre
                            else
                                lookupQuestion qid post
                                    === Just (Question kind k [] [])

    describe "renounce-and-departure-close-negatively (V-5)" $ do
        prop
            "a proposer's renounce closes the question negatively, cause renounced"
            $ forAll genUnreachableScenario
            $ \(v, evs) ->
                let pre = foldVote unreachable v evs
                in  conjoin
                        [ let post = applyVoteEvent unreachable v pre k (Renounce qid)
                              k = questionProposer q
                          in  lookupQuestion qid post === Nothing
                                .&&. closed post
                                    === closed pre
                                        <> [ClosureRecord qid q Negative Renounced]
                                .&&. openQuestions post
                                    === [e | e@(i, _) <- openQuestions pre, i /= qid]
                        | (qid, q) <- openQuestions pre
                        , isResponsabile (questionProposer q) v
                        ]

        prop
            "departure closes exactly the departing proposer's questions, in order"
            $ forAll ((,) <$> genKey <*> genRawState)
            $ \(k, gs) ->
                let post = closeProposerQuestions k gs
                    gone = [(i, q) | (i, q) <- openQuestions gs, questionProposer q == k]
                in  openQuestions post
                        === [e | e@(_, q) <- openQuestions gs, questionProposer q /= k]
                        .&&. closed post
                            === closed gs
                                <> [ClosureRecord i q Negative ProposerDeparted | (i, q) <- gone]

    describe
        "non-proposer-renounce-and-non-designee-ballot-refused (S-12)"
        $ prop
            "the refusal is notProposer / notDesignee exactly when the signer is not the identity"
        $ forAll genScenario
        $ \(p, v, evs) ->
            let th = policyThreshold p
                pre = foldVote th v evs
            in  all
                    ( \(qid, q) ->
                        all
                            ( \k ->
                                not (isResponsabile k v)
                                    || ( validateVoteEvent th v pre k (Renounce qid)
                                            == (if k == questionProposer q then Right () else Left NotProposer)
                                       )
                                        && ( validateVoteEvent th v pre k (Cast qid Assent)
                                                == case questionKind q of
                                                    Collective -> Right ()
                                                    Permission d
                                                        | d == k -> Right ()
                                                        | otherwise -> Left NotDesignee
                                           )
                            )
                            keyPool
                    )
                    (openQuestions pre)

    describe "one-position-per-responsabile (V-4)" $ do
        prop
            "a ballot moves the voter out of the other tally and keeps the rest"
            $ forAll
                ((,,) <$> genKey <*> elements [Assent, Dissent] <*> genQuestion)
            $ \(k, b, q) ->
                let q' = placeBallot k b q
                    (mine, other) = case b of
                        Assent -> (questionAssents, questionDissents)
                        Dissent -> (questionDissents, questionAssents)
                in  conjoin
                        [ property (k `elem` mine q')
                        , property (k `notElem` other q')
                        , property (clean q')
                        , filter (/= k) (mine q') === filter (/= k) (mine q)
                        , filter (/= k) (other q') === filter (/= k) (other q)
                        , length (mine q')
                            === length (mine q) + (if k `elem` mine q then 0 else 1)
                        , questionKind q' === questionKind q
                        , questionProposer q' === questionProposer q
                        ]

        prop "casting the same position twice changes nothing the second time"
            $ forAll
                ((,,) <$> genKey <*> elements [Assent, Dissent] <*> genQuestion)
            $ \(k, b, q) -> placeBallot k b (placeBallot k b q) === placeBallot k b q

    describe "checked-step-agrees-with-step"
        $ prop
            "the checked step is Right of the step exactly when validation is Right"
        $ forAll ((,,,) <$> genPolicy <*> genView <*> genRawState <*> genSigned)
        $ \(p, v, gs, (s, e)) ->
            let th = policyThreshold p
            in  case validateVoteEvent th v gs s e of
                    Right () ->
                        applyVoteEventChecked th v gs s e
                            === Right (applyVoteEvent th v gs s e)
                    Left err -> applyVoteEventChecked th v gs s e === Left err

    describe "the generators"
        $ prop
            "traces reach closures of each kind, refusals, admitted events and survivors"
        $ checkCoverage (forAll genScenario coverageOf)

    describe "threshold-is-explicit"
        $ prop
            "the verdict follows the threshold given, not any threshold of the library"
        $ forAll genView
        $ \v ->
            forAll ((,) <$> choose (0, 5) <*> choose (0, 5)) $ \(a, b) ->
                let q = Question Collective "a" (take a ["k1", "k2", "k3", "k4", "k5"]) []
                in  verdictOf (const (fromIntegral a)) v q === Positive
                        .&&. verdictOf (const (fromIntegral (a + 1 + b))) v q === Open

-- | Keys of the pool that hold no admin standing in the view.
strangersOf :: GroupView -> [Text]
strangersOf v = [k | k <- keyPool, not (isResponsabile k v)]

-- | Keys of the pool that are responsabili of the view.
responsabiliOf :: GroupView -> [Text]
responsabiliOf v = [k | k <- keyPool, isResponsabile k v]

-- | A property over every member of a list, vacuous when it is empty.
forAnyOf :: [Text] -> (Text -> Property) -> Property
forAnyOf [] _ = property True
forAnyOf ks f = forAll (elements ks) f

{- | Whether a generated trace is rich enough to make the properties above
non-vacuous: closures of each kind, refusals, admitted events, survivors.
-}
coverageOf :: Scenario -> Property
coverageOf (p, v, evs) =
    cover
        25
        (any ((== Positive) . closureVerdict) (closed gs))
        "a positive closure"
        . cover
            25
            (any ((== Negative) . closureVerdict) (closed gs))
            "a negative closure"
        . cover
            20
            (any ((== Renounced) . closureCause) (closed gs))
            "a closure by renounce"
        . cover
            15
            (any (isPermission . questionKind . closureQuestion) (closed gs))
            "a closed permission question"
        . cover 30 (not (null (openQuestions gs))) "an open question remains"
        . cover 50 (refused > 0) "a refused event"
        . cover 50 (refused < length evs) "an admitted event"
        . cover
            5
            ( any
                ( \(_, q) -> not (null (questionAssents q)) && not (null (questionDissents q))
                )
                (openQuestions gs)
            )
            "both positions recorded on an open question"
        $ property True
  where
    th = policyThreshold p
    gs = foldVote th v evs
    states = scanl (\g (s, e) -> applyVoteEvent th v g s e) emptyVoteState evs
    refused =
        length
            [ ()
            | (g, (s, e)) <- zip states evs
            , validateVoteEvent th v g s e /= Right ()
            ]
    isPermission = \case
        Permission _ -> True
        Collective -> False
