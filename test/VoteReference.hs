{- |
Module      : VoteReference
Description : A second, independent transcription of the Lean vote machine
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

Written from @lean/KelGroups/Vote/{State,Validate,Fold}.lean@ on
reactivegas master, with explicit recursion and none of the library's
list helpers, so that a reordering or a first-versus-all slip in the
library shows up as a difference. The view is read only through
'KelGroups.GroupView'.
-}
module VoteReference
    ( refValidate
    , refVerdict
    , refCause
    , refPlace
    , refSweep
    , refEffect
    , refDepart
    , refStep
    , refChecked
    , refFold
    , refFoldFrom
    ) where

import Data.Text (Text)
import KelGroups.GroupView (GroupView)
import KelGroups.GroupView qualified as GV
import KelGroups.Vote.Event (VoteEvent (..))
import KelGroups.Vote.State
    ( ClosureRecord (..)
    , Question (..)
    , VoteState (..)
    )
import KelGroups.Vote.Types
    ( Ballot (..)
    , ClosureCause (..)
    , QuestionId
    , QuestionKind (..)
    , Threshold
    , Verdict (..)
    )
import KelGroups.Vote.Validate (VoteError (..))

look :: QuestionId -> [(QuestionId, Question)] -> Maybe Question
look _ [] = Nothing
look k ((c, v) : rest)
    | c == k = Just v
    | otherwise = look k rest

erase
    :: QuestionId -> [(QuestionId, Question)] -> [(QuestionId, Question)]
erase _ [] = []
erase k ((c, v) : rest)
    | c == k = rest
    | otherwise = (c, v) : erase k rest

insert
    :: QuestionId
    -> Question
    -> [(QuestionId, Question)]
    -> [(QuestionId, Question)]
insert k v es = (k, v) : erase k es

has :: Text -> [Text] -> Bool
has _ [] = False
has x (y : ys) = x == y || has x ys

setInsert :: Text -> [Text] -> [Text]
setInsert x xs = if has x xs then xs else x : xs

dropFirst :: Text -> [Text] -> [Text]
dropFirst _ [] = []
dropFirst x (y : ys)
    | x == y = ys
    | otherwise = y : dropFirst x ys

len :: [a] -> Integer
len [] = 0
len (_ : xs) = 1 + len xs

refVerdict :: Threshold -> GroupView -> Question -> Verdict
refVerdict th view q = case questionKind q of
    Collective ->
        let required = toInteger (th (GV.adminCount view))
        in  if len (questionAssents q) >= required
                then Positive
                else
                    if len (questionDissents q) >= required
                        then Negative
                        else Open
    Permission d
        | has d (questionAssents q) -> Positive
        | has d (questionDissents q) -> Negative
        | otherwise -> Open

refCause :: GroupView -> Question -> Verdict -> ClosureCause
refCause view q = \case
    Positive -> if allIn (questionAssents q) then Tally else FranchiseChange
    Negative -> if allIn (questionDissents q) then Tally else FranchiseChange
    Open -> Tally
  where
    allIn [] = True
    allIn (k : ks) = GV.isAdmin k view && allIn ks

refValidate
    :: GroupView
    -> VoteState
    -> Text
    -> VoteEvent
    -> Either VoteError ()
refValidate view gs signer = \case
    OpenQuestion _ _
        | GV.isAdmin signer view -> Right ()
        | otherwise -> Left NotResponsabile
    Cast qid _
        | not (GV.isAdmin signer view) -> Left NotResponsabile
        | otherwise -> case look qid (openQuestions gs) of
            Nothing -> Left QuestionNotFound
            Just q -> case questionKind q of
                Collective -> Right ()
                Permission d
                    | signer == d -> Right ()
                    | otherwise -> Left NotDesignee
    Renounce qid
        | not (GV.isAdmin signer view) -> Left NotResponsabile
        | otherwise -> case look qid (openQuestions gs) of
            Nothing -> Left QuestionNotFound
            Just q
                | signer == questionProposer q -> Right ()
                | otherwise -> Left NotProposer

refPlace :: Text -> Ballot -> Question -> Question
refPlace v b q = case b of
    Assent ->
        q
            { questionAssents = setInsert v (questionAssents q)
            , questionDissents = dropFirst v (questionDissents q)
            }
    Dissent ->
        q
            { questionDissents = setInsert v (questionDissents q)
            , questionAssents = dropFirst v (questionAssents q)
            }

refSweep :: Threshold -> GroupView -> VoteState -> VoteState
refSweep th view gs = VoteState stay (closed gs <> new)
  where
    (stay, new) = go (openQuestions gs)
    go [] = ([], [])
    go (e@(qid, q) : rest) =
        let (s, n) = go rest
        in  case refVerdict th view q of
                Open -> (e : s, n)
                v -> (s, ClosureRecord qid q v (refCause view q v) : n)

refEffect :: VoteState -> Text -> VoteEvent -> VoteState
refEffect gs signer = \case
    OpenQuestion qid kind ->
        let fresh = Question kind signer [] []
            seen = any ((== qid) . closureQuestionId) (closed gs)
        in  case look qid (openQuestions gs) of
                Nothing
                    | not seen ->
                        gs{openQuestions = insert qid fresh (openQuestions gs)}
                _ -> gs
    Cast qid b -> case look qid (openQuestions gs) of
        Just q ->
            gs
                { openQuestions = insert qid (refPlace signer b q) (openQuestions gs)
                }
        Nothing -> gs
    Renounce qid -> case look qid (openQuestions gs) of
        Just q ->
            VoteState
                (erase qid (openQuestions gs))
                (closed gs <> [ClosureRecord qid q Negative Renounced])
        Nothing -> gs

refDepart :: Text -> VoteState -> VoteState
refDepart p gs = VoteState stay (closed gs <> gone)
  where
    (stay, gone) = go (openQuestions gs)
    go [] = ([], [])
    go (e@(qid, q) : rest) =
        let (s, n) = go rest
        in  if questionProposer q == p
                then (s, ClosureRecord qid q Negative ProposerDeparted : n)
                else (e : s, n)

refChecked
    :: Threshold
    -> GroupView
    -> VoteState
    -> Text
    -> VoteEvent
    -> Either VoteError VoteState
refChecked th view gs signer ev = case refValidate view gs signer ev of
    Left e -> Left e
    Right () -> Right (refSweep th view (refEffect gs signer ev))

refStep
    :: Threshold -> GroupView -> VoteState -> Text -> VoteEvent -> VoteState
refStep th view gs signer ev = either (const gs) id (refChecked th view gs signer ev)

refFoldFrom
    :: Threshold
    -> GroupView
    -> VoteState
    -> [(Text, VoteEvent)]
    -> VoteState
refFoldFrom _ _ gs [] = gs
refFoldFrom th view gs ((s, e) : rest) =
    refFoldFrom th view (refStep th view gs s e) rest

refFold :: Threshold -> GroupView -> [(Text, VoteEvent)] -> VoteState
refFold th view = refFoldFrom th view (VoteState [] [])
