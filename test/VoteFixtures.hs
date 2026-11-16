{- |
Module      : VoteFixtures
Description : Fixtures and generators of the vote machine suite
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

The named views and thresholds of the Lean executed witnesses
(@lean/KelGroups/Vote/Tests.lean@ on reactivegas master), and the
generators the vote properties draw rosters, thresholds, payloads and
signed traces from. The library ships no threshold; the two named
instances below are test exhibits, as in the Lean.
-}
module VoteFixtures
    ( -- * Thresholds
      legacyThreshold
    , zeroThreshold
    , Policy (..)
    , policyThreshold

      -- * Views
    , viewOf
    , viewOfMixed
    , oneAdminView
    , threeAdminView
    , fourAdminView
    , fiveAdminView
    , fourAdminAfterALeftView
    , aLostAdminView

      -- * Traces
    , vOpen
    , vCast
    , soleClosure
    , witnessTraceValid

      -- * Generators
    , keyPool
    , genKey
    , genQid
    , genKind
    , genEvent
    , genSigned
    , genRawTrace
    , genTraceFor
    , genRoster
    , genView
    , genPolicy
    , genQuestion
    , genRawQuestion
    , genRawState
    ) where

import Data.Text (Text)
import KelGroups.Group (Roster (Roster))
import KelGroups.GroupView (GroupView, groupView, isAdmin)
import KelGroups.Vote.Event (VoteEvent (..))
import KelGroups.Vote.Fold (applyVoteEvent)
import KelGroups.Vote.State
    ( ClosureRecord (..)
    , Question (..)
    , VoteState (..)
    , emptyVoteState
    )
import KelGroups.Vote.Types
    ( Ballot (..)
    , ClosureCause (..)
    , QuestionId
    , QuestionKind (..)
    , Threshold
    , Verdict (..)
    )
import KelGroups.Vote.Validate (validateVoteEvent)
import Numeric.Natural (Natural)
import Test.QuickCheck
    ( Gen
    , chooseInt
    , elements
    , frequency
    , listOf
    , oneof
    , sublistOf
    , vectorOf
    )
import VoteReference (refStep)

-- | Lean @legacyThreshold@: @(n + 1) div 2@. A test exhibit, not a default.
legacyThreshold :: Threshold
legacyThreshold n = (n + 1) `div` 2

-- | Lean @zeroThreshold@: the constant zero. A test exhibit, not a default.
zeroThreshold :: Threshold
zeroThreshold = const 0

{- | A generated threshold policy: a constant, or @(n + shift) div by@
(@by >= 1@).
-}
data Policy
    = Const Natural
    | Shift Natural Natural
    deriving stock (Eq, Show)

policyThreshold :: Policy -> Threshold
policyThreshold = \case
    Const c -> const c
    Shift k d -> \n -> (n + k) `div` max 1 d

-- --------------------------------------------------------
-- Views
-- --------------------------------------------------------

-- | The listed keys as admin members, in this order.
viewOf :: [Text] -> GroupView
viewOf ks = groupView (Roster ks ks)

-- | Admins first, then members without an admin role.
viewOfMixed :: [Text] -> [Text] -> GroupView
viewOfMixed as os = groupView (Roster (as <> os) as)

oneAdminView
    , threeAdminView
    , fourAdminView
    , fiveAdminView
        :: GroupView
oneAdminView = viewOf ["a"]
threeAdminView = viewOf ["a", "b", "c"]
fourAdminView = viewOf ["a", "b", "c", "d"]
fiveAdminView = viewOf ["a", "b", "c", "d", "e"]

-- | R-53 post view: @a@ is gone, four admins remain.
fourAdminAfterALeftView :: GroupView
fourAdminAfterALeftView = viewOf ["b", "c", "d", "e"]

-- | INV-54-FRANCHISE post view: @a@ is a member without an admin role.
aLostAdminView :: GroupView
aLostAdminView = viewOfMixed ["b", "c", "d"] ["a"]

-- --------------------------------------------------------
-- Traces
-- --------------------------------------------------------

-- | A collective @openQuestion@ issued by @who@.
vOpen :: Text -> QuestionId -> (Text, VoteEvent)
vOpen who q = (who, OpenQuestion q Collective)

-- | A @cast@ issued by @who@.
vCast :: Text -> QuestionId -> Ballot -> (Text, VoteEvent)
vCast who q b = (who, Cast q b)

-- | The one closure record of a state whose only closure is @q@.
soleClosure :: VoteState -> QuestionId -> Maybe ClosureRecord
soleClosure gs q = case closed gs of
    [r] | closureQuestionId r == q -> Just r
    _ -> Nothing

-- | Every step of the trace is admissible, from the empty payload.
witnessTraceValid
    :: Threshold -> GroupView -> [(Text, VoteEvent)] -> Bool
witnessTraceValid th view = go emptyVoteState
  where
    go _ [] = True
    go gs ((s, e) : rest) =
        validateVoteEvent th view gs s e == Right ()
            && go (applyVoteEvent th view gs s e) rest

-- --------------------------------------------------------
-- Generators
-- --------------------------------------------------------

{- | Five candidate admins, one observer member and one stranger. A
small pool, so that traces collide on keys and question ids.
-}
keyPool :: [Text]
keyPool = ["a", "b", "c", "d", "e", "o", "s"]

genKey :: Gen Text
genKey = elements keyPool

genQid :: Gen QuestionId
genQid = elements ["q", "r", "t"]

genKind :: Gen QuestionKind
genKind =
    frequency [(3, pure Collective), (1, Permission <$> genKey)]

genEvent :: Gen VoteEvent
genEvent =
    frequency
        [ (2, OpenQuestion <$> genQid <*> genKind)
        , (5, Cast <$> genQid <*> elements [Assent, Dissent])
        , (1, Renounce <$> genQid)
        ]

genSigned :: Gen (Text, VoteEvent)
genSigned = (,) <$> genKey <*> genEvent

-- | A trace of unrelated signed events, mostly refused.
genRawTrace :: Gen [(Text, VoteEvent)]
genRawTrace = do
    n <- chooseInt (0, 14)
    vectorOf n genSigned

{- | A trace that follows the payload it builds: responsabili mostly sign,
ballots and renounces mostly name open questions, permission ballots
mostly come from the designee, renounces mostly from the proposer. The
payload is tracked with the reference model, not with the subject.
-}
genTraceFor :: Threshold -> GroupView -> Gen [(Text, VoteEvent)]
genTraceFor th view = do
    n <- chooseInt (0, 16)
    go n (VoteState [] [])
  where
    voters = filter (`isAdmin` view) keyPool
    voter
        | null voters = genKey
        | otherwise = frequency [(9, elements voters), (1, genKey)]
    go :: Int -> VoteState -> Gen [(Text, VoteEvent)]
    go 0 _ = pure []
    go k gs = do
        step <- stepFor gs
        rest <- go (k - 1) (refStep th view gs (fst step) (snd step))
        pure (step : rest)
    stepFor gs =
        frequency $
            [(3, openStep), (1, genSigned)]
                <> [(8, castStep opens) | not (null opens)]
                <> [(2, renounceStep opens) | not (null opens)]
      where
        opens = openQuestions gs
    openStep = do
        s <- voter
        qid <- genQid
        kind <-
            frequency
                [ (3, pure Collective)
                , (1, Permission <$> voter)
                ]
        pure (s, OpenQuestion qid kind)
    castStep opens = do
        (qid, q) <- elements opens
        s <- case questionKind q of
            Permission d -> frequency [(7, pure d), (3, voter)]
            Collective -> voter
        b <- elements [Assent, Dissent]
        pure (s, Cast qid b)
    renounceStep opens = do
        (qid, q) <- elements opens
        s <- frequency [(7, pure (questionProposer q)), (3, voter)]
        pure (s, Renounce qid)

{- | A roster of the shape admission produces: admins are members. The
observer @o@ and the stranger @s@ are never admins; @s@ may be absent.
-}
genRoster :: Gen Roster
genRoster = do
    as <- sublistOf ["a", "b", "c", "d", "e"]
    os <- sublistOf ["o"]
    pure (Roster (as <> os) as)

genView :: Gen GroupView
genView = groupView <$> genRoster

genPolicy :: Gen Policy
genPolicy =
    oneof
        [ Const . fromIntegral <$> chooseInt (0, 6)
        , Shift
            <$> (fromIntegral <$> chooseInt (0, 4))
            <*> (fromIntegral <$> chooseInt (1, 3))
        ]

-- | A question whose tallies are duplicate-free and disjoint.
genQuestion :: Gen Question
genQuestion = do
    kind <- genKind
    p <- genKey
    ks <- sublistOf keyPool
    n <- chooseInt (0, length ks)
    pure
        Question
            { questionKind = kind
            , questionProposer = p
            , questionAssents = take n ks
            , questionDissents = drop n ks
            }

-- | A question with arbitrary tallies, duplicates and overlap included.
genRawQuestion :: Gen Question
genRawQuestion =
    Question <$> genKind <*> genKey <*> listOf genKey <*> listOf genKey

-- | An arbitrary payload, not necessarily reachable.
genRawState :: Gen VoteState
genRawState = do
    os <- listOf ((,) <$> genQid <*> genRawQuestion)
    cs <- listOf genRawRecord
    pure (VoteState os cs)
  where
    genRawRecord =
        ClosureRecord
            <$> genQid
            <*> genRawQuestion
            <*> elements [Positive, Negative, Open]
            <*> elements [Tally, FranchiseChange, ProposerDeparted, Renounced]
