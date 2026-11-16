{- |
Module      : VoteWitnessSpec
Description : The executed witnesses of the Lean vote machine
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

Every executed witness of @lean/KelGroups/Vote/Tests.lean@ on
reactivegas master, reproduced as a unit case against the Haskell
fold (Lean section names in the case names), followed by the unit cases
for the refusals, closures and verdicts the Lean specifies in its
definitions (S-12, V-5, #68, V-4, R-55, R-64).
-}
module VoteWitnessSpec
    ( spec
    ) where

import Data.Text (Text)
import KelGroups.Group (Roster (Roster))
import KelGroups.GroupView (groupView)
import KelGroups.Vote.Event (VoteEvent (..))
import KelGroups.Vote.Fold
    ( applyVoteEvent
    , applyVoteEventChecked
    , closeProposerQuestions
    , effectedState
    , foldVote
    , placeBallot
    , sweepClosures
    )
import KelGroups.Vote.State
    ( ClosureRecord (..)
    , Question (..)
    , VoteState (..)
    , closureCauseOf
    , emptyVoteState
    , franchiseSize
    , isResponsabile
    , lookupQuestion
    , verdictOf
    )
import KelGroups.Vote.Types
    ( Ballot (..)
    , ClosureCause (..)
    , QuestionKind (..)
    , Verdict (..)
    )
import KelGroups.Vote.Validate (VoteError (..), validateVoteEvent)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import VoteFixtures

tie :: [(Text, VoteEvent)]
tie = [vOpen "a" "q", vCast "a" "q" Assent, vCast "b" "q" Assent]

votePointState :: VoteState
votePointState = foldVote legacyThreshold oneAdminView [vOpen "a" "q"]

-- | Lean @PreservesQuestionSemantics@ (decidable form), under the three-admin view.
preservesQuestion
    :: VoteState -> Text -> VoteEvent -> Text -> Bool
preservesQuestion gs signer ev qid = case lookupQuestion qid gs of
    Nothing -> True
    Just q ->
        lookupQuestion
            qid
            (applyVoteEvent legacyThreshold threeAdminView gs signer ev)
            == Just q

spec :: Spec
spec = describe "Vote Lean witnesses" $ do
    describe "R-48a legacy policy, a tie passes" $
        it "four responsabili, two assents close positive by tally" $ do
            let gs = foldVote legacyThreshold fourAdminView tie
            witnessTraceValid legacyThreshold fourAdminView tie `shouldBe` True
            lookupQuestion "q" gs `shouldBe` Nothing
            fmap closureVerdict (soleClosure gs "q") `shouldBe` Just Positive
            fmap closureCause (soleClosure gs "q") `shouldBe` Just Tally
            fmap (questionAssents . closureQuestion) (soleClosure gs "q")
                `shouldBe` Just ["b", "a"]
            fmap (questionDissents . closureQuestion) (soleClosure gs "q")
                `shouldBe` Just []

    describe "R-48b zero policy, everything passes instantly" $
        it "a question opens and closes positive with no ballot cast" $ do
            let evs = [vOpen "a" "q"]
                gs = foldVote zeroThreshold oneAdminView evs
            witnessTraceValid zeroThreshold oneAdminView evs `shouldBe` True
            lookupQuestion "q" gs `shouldBe` Nothing
            fmap closureVerdict (soleClosure gs "q") `shouldBe` Just Positive
            fmap (questionAssents . closureQuestion) (soleClosure gs "q")
                `shouldBe` Just []
            fmap (questionDissents . closureQuestion) (soleClosure gs "q")
                `shouldBe` Just []

    describe "R-53 a question can pass because a responsabile left" $
        it "the same payload closes by franchise change under the post view" $ do
            let open = foldVote legacyThreshold fiveAdminView tie
                swept = sweepClosures legacyThreshold fourAdminAfterALeftView open
            witnessTraceValid legacyThreshold fiveAdminView tie `shouldBe` True
            lookupQuestion "q" open `shouldSatisfy` (/= Nothing)
            isResponsabile "a" fiveAdminView `shouldBe` True
            isResponsabile "a" fourAdminAfterALeftView `shouldBe` False
            lookupQuestion "q" swept `shouldBe` Nothing
            fmap closureVerdict (soleClosure swept "q") `shouldBe` Just Positive
            fmap closureCause (soleClosure swept "q")
                `shouldBe` Just FranchiseChange
            fmap (questionAssents . closureQuestion) (soleClosure swept "q")
                `shouldBe` Just ["b", "a"]

    describe "V-7 the just-vote-no escape" $ do
        it "a switcher is counted once, on the assent side" $ do
            let evs =
                    [ vOpen "a" "q"
                    , vCast "b" "q" Dissent
                    , vCast "b" "q" Assent
                    ]
                gs = foldVote legacyThreshold threeAdminView evs
            witnessTraceValid legacyThreshold threeAdminView evs `shouldBe` True
            fmap questionAssents (lookupQuestion "q" gs) `shouldBe` Just ["b"]
            fmap questionDissents (lookupQuestion "q" gs) `shouldBe` Just []

        it "two dissents of three close negative by tally" $ do
            let evs =
                    [ vOpen "a" "q"
                    , vCast "a" "q" Dissent
                    , vCast "b" "q" Dissent
                    ]
                gs = foldVote legacyThreshold threeAdminView evs
            witnessTraceValid legacyThreshold threeAdminView evs `shouldBe` True
            lookupQuestion "q" gs `shouldBe` Nothing
            fmap closureVerdict (soleClosure gs "q") `shouldBe` Just Negative
            fmap closureCause (soleClosure gs "q") `shouldBe` Just Tally
            fmap (questionDissents . closureQuestion) (soleClosure gs "q")
                `shouldBe` Just ["b", "a"]
            fmap (questionAssents . closureQuestion) (soleClosure gs "q")
                `shouldBe` Just []

    describe "R-61 a decided question stays decided" $
        it "reopening a closed id is a no-op" $ do
            let evs = tie <> [vOpen "a" "q"]
                gs = foldVote legacyThreshold fourAdminView evs
            witnessTraceValid legacyThreshold fourAdminView evs `shouldBe` True
            lookupQuestion "q" gs `shouldBe` Nothing
            length (closed gs) `shouldBe` 1
            fmap closureVerdict (soleClosure gs "q") `shouldBe` Just Positive

    describe "admissibility point tests" $ do
        it "a cast by a non-member is refused as not a responsabile (R-44)" $
            validateVoteEvent
                legacyThreshold
                oneAdminView
                votePointState
                "stranger"
                (Cast "q" Assent)
                `shouldBe` Left NotResponsabile

        it "a cast by a member without an admin role is refused alike (R-44)" $
            validateVoteEvent
                legacyThreshold
                (viewOfMixed ["a"] ["b"])
                votePointState
                "b"
                (Cast "q" Assent)
                `shouldBe` Left NotResponsabile

        it "a question opening by a non-responsabile is refused (R-45)" $
            validateVoteEvent
                legacyThreshold
                oneAdminView
                votePointState
                "stranger"
                (OpenQuestion "r" Collective)
                `shouldBe` Left NotResponsabile

        it
            "R-45 on the fold: a stranger's opening is a no-op under zero policy"
            $ do
                let gs =
                        foldVote
                            zeroThreshold
                            oneAdminView
                            [("stranger", OpenQuestion "q" Collective)]
                lookupQuestion "q" gs `shouldBe` Nothing
                closed gs `shouldBe` []

        it "a cast on an unknown question id is refused as not found" $
            validateVoteEvent
                legacyThreshold
                oneAdminView
                votePointState
                "a"
                (Cast "missing" Assent)
                `shouldBe` Left QuestionNotFound

        it "an admissible cast is accepted" $
            validateVoteEvent
                legacyThreshold
                oneAdminView
                votePointState
                "a"
                (Cast "q" Assent)
                `shouldBe` Right ()

        it "INV-54-FRANCHISE: after losing standing a recast cannot switch" $ do
            let evs = [vOpen "a" "q", vCast "a" "q" Assent]
                gs = foldVote legacyThreshold fourAdminView evs
                after =
                    applyVoteEvent
                        legacyThreshold
                        aLostAdminView
                        gs
                        "a"
                        (Cast "q" Dissent)
            witnessTraceValid legacyThreshold fourAdminView evs `shouldBe` True
            fmap questionAssents (lookupQuestion "q" after) `shouldBe` Just ["a"]
            fmap questionDissents (lookupQuestion "q" after) `shouldBe` Just []

        it "a renounce by the question's proposer validates (V-5)" $
            validateVoteEvent
                legacyThreshold
                oneAdminView
                votePointState
                "a"
                (Renounce "q")
                `shouldBe` Right ()

    describe "R57-04 a stranger's question events are rejected and inert" $
        it "all three constructors refuse and leave the payload as it was" $
            mapM_
                ( \ev -> do
                    validateVoteEvent
                        legacyThreshold
                        oneAdminView
                        votePointState
                        "stranger"
                        ev
                        `shouldBe` Left NotResponsabile
                    applyVoteEvent
                        legacyThreshold
                        oneAdminView
                        votePointState
                        "stranger"
                        ev
                        `shouldBe` votePointState
                )
                [OpenQuestion "r" Collective, Cast "q" Assent, Renounce "q"]

    describe "R57-05 the retained R-45 oracle" $
        it "a stranger's cast leaves the whole payload unchanged" $ do
            let before =
                    foldVote
                        legacyThreshold
                        threeAdminView
                        [vOpen "a" "q", vCast "a" "q" Assent]
                after =
                    applyVoteEvent
                        legacyThreshold
                        threeAdminView
                        before
                        "stranger"
                        (Cast "q" Assent)
            franchiseSize threeAdminView `shouldBe` 3
            isResponsabile "stranger" threeAdminView `shouldBe` False
            validateVoteEvent
                legacyThreshold
                threeAdminView
                before
                "stranger"
                (Cast "q" Assent)
                `shouldBe` Left NotResponsabile
            after `shouldBe` before

    describe "R57-07 the semantic no-expiry premise" $ do
        let before =
                foldVote
                    legacyThreshold
                    threeAdminView
                    [vOpen "a" "q", vCast "a" "q" Assent]
        it "an event on another question preserves the target" $
            preservesQuestion before "a" (OpenQuestion "other" Collective) "q"
                `shouldBe` True
        it
            "V-5: the proposer's renounce closes the target, so it does not preserve it"
            $ preservesQuestion before "a" (Renounce "q") "q" `shouldBe` False
        it "a ballot on the target does not preserve it" $
            preservesQuestion before "b" (Cast "q" Assent) "q" `shouldBe` False
        it "a stranger's ballot is inert, so it preserves the target" $
            preservesQuestion before "stranger" (Cast "q" Dissent) "q"
                `shouldBe` True
        it "the premise holds for an id that is not open" $
            preservesQuestion before "b" (Cast "q" Assent) "missing"
                `shouldBe` True

    describe "S-12 refusals are typed, in the Lean order" $ do
        let view = viewOf ["a", "b", "c"]
            withPerm =
                foldVote
                    (const 99)
                    view
                    [("a", OpenQuestion "p" (Permission "b")), vOpen "a" "q"]
            v = validateVoteEvent (const 99) view withPerm
        it
            "a stranger on an unknown id is not a responsabile, not 'not found'"
            $ do
                v "stranger" (Cast "nope" Assent) `shouldBe` Left NotResponsabile
                v "stranger" (Renounce "nope") `shouldBe` Left NotResponsabile
        it "a responsabile on an unknown id gets 'question not found'" $ do
            v "a" (Cast "nope" Assent) `shouldBe` Left QuestionNotFound
            v "a" (Renounce "nope") `shouldBe` Left QuestionNotFound
        it "a non-designee ballot on a permission question is refused" $ do
            v "c" (Cast "p" Assent) `shouldBe` Left NotDesignee
            v "a" (Cast "p" Dissent) `shouldBe` Left NotDesignee
        it "the designee's ballot is admitted" $
            v "b" (Cast "p" Assent) `shouldBe` Right ()
        it "any responsabile may ballot a collective question" $
            map (\k -> v k (Cast "q" Assent)) ["a", "b", "c"]
                `shouldBe` [Right (), Right (), Right ()]
        it "a non-proposer renounce is refused" $ do
            v "b" (Renounce "q") `shouldBe` Left NotProposer
            v "c" (Renounce "p") `shouldBe` Left NotProposer
        it "the proposer's renounce is admitted, on either kind" $ do
            v "a" (Renounce "q") `shouldBe` Right ()
            v "a" (Renounce "p") `shouldBe` Right ()
        it
            "a refused event changes no state and the checked step names the error"
            $ mapM_
                ( \(s, ev, e) -> do
                    applyVoteEvent (const 99) view withPerm s ev `shouldBe` withPerm
                    applyVoteEventChecked (const 99) view withPerm s ev
                        `shouldBe` Left e
                )
                [ ("stranger", Cast "q" Assent, NotResponsabile)
                , ("a", Cast "nope" Assent, QuestionNotFound)
                , ("c", Cast "p" Assent, NotDesignee)
                , ("b", Renounce "q", NotProposer)
                ]

    describe "a permission question" $ do
        let view = viewOf ["a", "b", "c"]
            opened =
                foldVote
                    legacyThreshold
                    view
                    [("a", OpenQuestion "p" (Permission "b"))]
        it "opens with empty tallies and stays open" $
            lookupQuestion "p" opened
                `shouldBe` Just (Question (Permission "b") "a" [] [])
        it "the designee's assent closes it positive, by tally" $ do
            let gs = applyVoteEvent legacyThreshold view opened "b" (Cast "p" Assent)
            lookupQuestion "p" gs `shouldBe` Nothing
            fmap closureVerdict (soleClosure gs "p") `shouldBe` Just Positive
            fmap closureCause (soleClosure gs "p") `shouldBe` Just Tally
        it "the designee's dissent closes it negative" $ do
            let gs = applyVoteEvent legacyThreshold view opened "b" (Cast "p" Dissent)
            fmap closureVerdict (soleClosure gs "p") `shouldBe` Just Negative
        it "the verdict never consults the threshold (R-64)" $ do
            let q = Question (Permission "b") "a" ["x"] ["y"]
                boom = const (error "the threshold was consulted")
            verdictOf boom threeAdminView q `shouldBe` Open
            verdictOf boom threeAdminView q{questionAssents = ["b"]}
                `shouldBe` Positive
            verdictOf boom threeAdminView q{questionDissents = ["b"]}
                `shouldBe` Negative
            verdictOf
                boom
                threeAdminView
                q{questionAssents = ["b"], questionDissents = ["b"]}
                `shouldBe` Positive

    describe "the single verdict site" $ do
        let q as ds = Question Collective "a" as ds
        it "assents are compared first, then dissents, then open (R-50)" $ do
            verdictOf legacyThreshold fourAdminView (q ["a", "b"] [])
                `shouldBe` Positive
            verdictOf legacyThreshold fourAdminView (q [] ["a", "b"])
                `shouldBe` Negative
            verdictOf legacyThreshold fourAdminView (q ["a"] ["b"])
                `shouldBe` Open
            verdictOf
                legacyThreshold
                fourAdminView
                (q ["a", "b"] ["c", "d"])
                `shouldBe` Positive
        it "the threshold is read at the franchise size, on both sides" $ do
            verdictOf (const 3) fourAdminView (q ["a", "b"] []) `shouldBe` Open
            verdictOf (const 3) fourAdminView (q ["a", "b", "c"] [])
                `shouldBe` Positive
            verdictOf (const 3) fourAdminView (q [] ["a", "b", "c"])
                `shouldBe` Negative
        it
            "the threshold is an explicit argument: the same question differs by policy"
            $ do
                verdictOf legacyThreshold fourAdminView (q [] []) `shouldBe` Open
                verdictOf zeroThreshold fourAdminView (q [] []) `shouldBe` Positive
        it "the threshold sees the franchise size of the view it is given" $ do
            verdictOf legacyThreshold fiveAdminView (q ["a", "b"] [])
                `shouldBe` Open
            verdictOf legacyThreshold fourAdminView (q ["a", "b"] [])
                `shouldBe` Positive

    describe "the closure cause (R-55)" $ do
        let q = Question Collective "a"
        it "a deciding side inside the franchise is a tally closure" $ do
            closureCauseOf threeAdminView (q ["a", "b"] []) Positive
                `shouldBe` Tally
            closureCauseOf threeAdminView (q [] ["a", "b"]) Negative
                `shouldBe` Tally
        it
            "a deciding side with a key the franchise no longer counts is a franchise change"
            $ do
                closureCauseOf fourAdminAfterALeftView (q ["a", "b"] []) Positive
                    `shouldBe` FranchiseChange
                closureCauseOf fourAdminAfterALeftView (q [] ["a", "b"]) Negative
                    `shouldBe` FranchiseChange
        it "only the deciding side is inspected" $ do
            closureCauseOf fourAdminAfterALeftView (q ["b", "c"] ["a"]) Positive
                `shouldBe` Tally
            closureCauseOf fourAdminAfterALeftView (q ["a"] ["b", "c"]) Negative
                `shouldBe` Tally
        it "an open verdict is a tally" $
            closureCauseOf fourAdminAfterALeftView (q ["a"] ["a"]) Open
                `shouldBe` Tally

    describe "#68 proposer is not an assent" $ do
        it
            "a question opens with both tallies empty and the signer as proposer"
            $ do
                let gs = foldVote (const 99) threeAdminView [vOpen "b" "q"]
                lookupQuestion "q" gs `shouldBe` Just (Question Collective "b" [] [])
        it "the opening effect alone records no ballot either" $
            effectedState emptyVoteState "b" (OpenQuestion "q" Collective)
                `shouldBe` VoteState [("q", Question Collective "b" [] [])] []

    describe "V-4 one position per responsabile" $ do
        let q = Question Collective "a" ["x", "y"] ["z"]
        it "assent inserts in front and erases from the dissents" $ do
            placeBallot "z" Assent q
                `shouldBe` Question Collective "a" ["z", "x", "y"] []
            placeBallot "x" Assent q
                `shouldBe` Question Collective "a" ["x", "y"] ["z"]
        it "dissent inserts in front and erases from the assents" $ do
            placeBallot "x" Dissent q
                `shouldBe` Question Collective "a" ["y"] ["x", "z"]
            placeBallot "z" Dissent q
                `shouldBe` Question Collective "a" ["x", "y"] ["z"]

    describe "V-5 closure on the proposer's way out" $ do
        it
            "a proposer's renounce closes the question negatively, cause renounced"
            $ do
                let evs = [vOpen "a" "q", vCast "a" "q" Assent]
                    st = foldVote legacyThreshold threeAdminView evs
                    after = applyVoteEvent legacyThreshold threeAdminView st "a" (Renounce "q")
                lookupQuestion "q" after `shouldBe` Nothing
                closed after
                    `shouldBe` [ ClosureRecord
                                    "q"
                                    (Question Collective "a" ["a"] [])
                                    Negative
                                    Renounced
                               ]
        it "a non-proposer's renounce closes nothing" $ do
            let st = foldVote legacyThreshold threeAdminView [vOpen "a" "q"]
            applyVoteEvent legacyThreshold threeAdminView st "b" (Renounce "q")
                `shouldBe` st
        it
            "a departing proposer's questions close negatively in open-set order"
            $ do
                let st =
                        foldVote
                            (const 99)
                            threeAdminView
                            [vOpen "a" "q", vOpen "b" "r", vOpen "a" "t"]
                    after = closeProposerQuestions "a" st
                map fst (openQuestions st) `shouldBe` ["t", "r", "q"]
                map fst (openQuestions after) `shouldBe` ["r"]
                map closureQuestionId (closed after) `shouldBe` ["t", "q"]
                map closureVerdict (closed after) `shouldBe` [Negative, Negative]
                map closureCause (closed after)
                    `shouldBe` [ProposerDeparted, ProposerDeparted]
        it "departure appends after the existing log and reads no view" $ do
            let st = foldVote zeroThreshold oneAdminView [vOpen "a" "z"]
                st' = st{openQuestions = [("q", Question Collective "a" [] [])]}
                after = closeProposerQuestions "a" st'
            map closureQuestionId (closed after) `shouldBe` ["z", "q"]

    describe "list order of the Lean helpers" $ do
        it "an open question is prepended to the open set" $ do
            let st = foldVote (const 99) threeAdminView [vOpen "a" "q", vOpen "a" "r"]
            map fst (openQuestions st) `shouldBe` ["r", "q"]
        it "a ballot moves its question to the front of the open set" $ do
            let st =
                    foldVote
                        (const 99)
                        threeAdminView
                        [vOpen "a" "q", vOpen "a" "r", vCast "b" "q" Assent]
            map fst (openQuestions st) `shouldBe` ["q", "r"]
        it "closure records are appended in open-set order" $ do
            let st = foldVote (const 99) threeAdminView [vOpen "a" "q", vOpen "a" "r"]
                swept = sweepClosures zeroThreshold threeAdminView st
            map closureQuestionId (closed swept) `shouldBe` ["r", "q"]
            openQuestions swept `shouldBe` []
        it "lookup finds the first of two entries under one id" $
            lookupQuestion
                "q"
                ( VoteState
                    [ ("q", Question Collective "a" [] [])
                    , ("q", Question Collective "b" [] [])
                    ]
                    []
                )
                `shouldBe` Just (Question Collective "a" [] [])
        it "a projected roster view is the franchise the fold reads" $ do
            let view = groupView (Roster ["a", "b", "o"] ["a", "b"])
                gs = foldVote legacyThreshold view [vOpen "a" "q", vCast "o" "q" Assent]
            lookupQuestion "q" gs `shouldBe` Just (Question Collective "a" [] [])
