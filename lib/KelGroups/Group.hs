{-# LANGUAGE NamedFieldPuns #-}

{- |
Module      : KelGroups.Group
Description : Group actions and their admission
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

A group action is an interaction event in the signer's hosted
member KEL whose @a@ holds exactly one group anchor naming the
group, the payload and @prev@, the digest of the group head it
extends. The group chain is nothing but those @prev@ links. This
module is pure and speaks the words of the Lean model
(@KelGroups.Sovereign@): 'Action', 'Payload', 'head', 'roster',
'applyCore', 'guardOk', 'membershipOk', 'admit'.

The anchor is a JSON object with exactly these keys:

> {"payload": {"t": "genesis"}}
> {"group": <group id>, "prev": <head digest>, "payload": <payload>}

and a non-genesis payload is one of

> {"t": "add", "member": <prefix>}      {"t": "remove", "member": <prefix>}
> {"t": "grant", "member": <prefix>}    {"t": "revoke", "member": <prefix>}
> {"t": "leave"}                        {"t": "app", "data": <any>}

A genesis names no group and no @prev@: its group id is the
event's own @d@, and its signer is the sole member and admin.
Admission ('admit') is the KEL rule for an interaction on the
signer's hosted KEL followed by the group conditions, checked in
this order: genesis of an unused id; or an existing group, a
signer who is a current member, a @prev@ that is the head, and
the membership rule ('membershipOk'): only admins add, remove,
grant and revoke; an added identity is hosted and not a member;
a removed or granted one is a member, a granted one not yet an
admin; a revoked one is an admin; and the group never ends with
members and no admin.
-}
module KelGroups.Group
    ( -- * Actions
      Payload (..)
    , Action (..)
    , decodeAction

      -- * Chains and membership
    , Chain
    , chainActions
    , head
    , Roster (..)
    , roster
    , applyCore
    , guardOk
    , membershipOk

      -- * Group index
    , GroupIndex (..)
    , groupIndex

      -- * Admission
    , Hosted (..)
    , Admission (..)
    , GroupRefusal (..)
    , admit
    , retried
    , rebuildChains
    ) where

import Control.Monad (guard, unless, when)
import Data.Aeson (Value, withObject, (.:))
import Data.Aeson.Types (Parser, parseEither)
import Data.Bifunctor (first)
import Data.Foldable (foldl', toList)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Sequence (Seq, ViewR (..), viewr, (|>))
import Data.Sequence qualified as Seq
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import KelGroups.Kel
    ( KelRefusal (..)
    , MemberKel
    , appendInteraction
    , kelEvents
    )
import KelGroups.Kel qualified as Kel
import KelGroups.Kel.Codec (exactKeys)
import Keri.Event
    ( Event (..)
    , InteractionData (..)
    , eventDigest
    , eventSequenceNumber
    , eventType
    )
import Keri.Event.Serialize (serializeEvent)
import Keri.Kel (SignedEvent (..))
import Prelude hiding (head)

-- | Lean @Payload@: the core payloads and the membership vocabulary.
data Payload
    = Genesis
    | -- | Make an identity a member
      Add Text
    | -- | Make an identity neither member nor admin
      Remove Text
    | -- | Make a member an admin
      Grant Text
    | -- | Make an admin a plain member
      Revoke Text
    | -- | The signer leaves the group
      Leave
    | -- | Application data, opaque to the core
      App Value
    deriving stock (Show, Eq)

-- | Lean @Action@, with the signed event it was decoded from.
data Action = Action
    { signer :: Text
    -- ^ The event's @i@
    , gid :: Text
    -- ^ The anchor's group, or the event's @d@ at genesis
    , p :: Text
    -- ^ The event's @p@: the signer's KEL tip it extends
    , payload :: Payload
    , prev :: Maybe Text
    -- ^ The group head it extends; none at genesis
    , signed :: SignedEvent
    }
    deriving stock (Show, Eq)

-- | The admitted actions of one group: its genesis, then the rest.
data Chain = Chain Action (Seq Action)
    deriving stock (Show, Eq)

-- | Members and admins of a group.
data Roster = Roster
    { members :: [Text]
    , admins :: [Text]
    }
    deriving stock (Show, Eq)

{- | Lean @State@: hosted member KELs by prefix and group chains
by group id.
-}
data Hosted = Hosted
    { hostedKels :: Map Text MemberKel
    , hostedChains :: Map Text Chain
    }
    deriving stock (Show, Eq)

-- | What an admission answers: the group, its new head, the signer and @s@.
data Admission = Admission
    { admittedGroup :: Text
    , admittedHead :: Text
    , admittedPrefix :: Text
    , admittedSn :: Int
    }
    deriving stock (Show, Eq)

-- | Why an action is refused. A refused action changes nothing.
data GroupRefusal
    = -- | The interaction's @a@ is not exactly one group anchor
      NotAGroupAction Text
    | -- | The KEL rule refuses the event, or its signer is not hosted
      KelRefused KelRefusal
    | -- | No chain has the action's group id
      NoSuchGroup
    | -- | The signer is not a current member of the group
      NotAMember
    | -- | @prev@ is not the group head
      PrevNotHead
    | -- | A genesis whose group id already has a chain
      GroupExists
    | -- | An add, remove, grant or revoke by a member who is no admin
      NotAnAdmin
    | -- | An add of an identity whose KEL is not hosted
      MemberNotHosted
    | -- | An add of a current member
      AlreadyMember
    | -- | A remove or grant of an identity that is no member
      TargetNotMember
    | -- | A grant of a current admin
      AlreadyAdmin
    | -- | A revoke of an identity that is no admin
      TargetNotAdmin
    | -- | The action would leave members and no admin
      LastAdmin
    deriving stock (Show, Eq)

-- --------------------------------------------------------
-- Actions
-- --------------------------------------------------------

-- | The group action an interaction carries.
decodeAction :: SignedEvent -> Either GroupRefusal Action
decodeAction se@SignedEvent{event} = case event of
    Interaction InteractionData{digest, prefix, priorDigest, anchors} ->
        case anchors of
            [anchor] -> do
                (g, pl, h) <-
                    first (NotAGroupAction . T.pack) $
                        parseEither (parseAnchor digest) anchor
                pure
                    Action
                        { signer = prefix
                        , gid = g
                        , p = priorDigest
                        , payload = pl
                        , prev = h
                        , signed = se
                        }
            _ -> Left (NotAGroupAction "a must hold exactly one anchor")
    other -> Left (KelRefused (UnexpectedEventKind (eventType other)))

-- | Group id, payload and @prev@ of an anchor; @d@ is the event's.
parseAnchor :: Text -> Value -> Parser (Text, Payload, Maybe Text)
parseAnchor d = withObject "group anchor" $ \o -> do
    pl <- o .: "payload" >>= parsePayload
    case pl of
        Genesis -> do
            exactKeys "genesis anchor" ["payload"] o
            pure (d, Genesis, Nothing)
        _ -> do
            exactKeys "group anchor" ["group", "prev", "payload"] o
            g <- o .: "group"
            h <- o .: "prev"
            pure (g, pl, Just h)

parsePayload :: Value -> Parser Payload
parsePayload = withObject "payload" $ \o -> do
    t <- o .: "t"
    case t :: Text of
        "genesis" -> Genesis <$ exactKeys "genesis payload" ["t"] o
        "add" -> Add <$> member o
        "remove" -> Remove <$> member o
        "grant" -> Grant <$> member o
        "revoke" -> Revoke <$> member o
        "leave" -> Leave <$ exactKeys "leave payload" ["t"] o
        "app" -> do
            exactKeys "app payload" ["t", "data"] o
            App <$> o .: "data"
        other -> fail ("unknown payload " <> show other)
  where
    member o = do
        exactKeys "membership payload" ["t", "member"] o
        o .: "member"

-- | The @d@ of the action's event.
actionDigest :: Action -> Text
actionDigest = eventDigest . event . signed

-- --------------------------------------------------------
-- Chains and membership
-- --------------------------------------------------------

-- | The actions of a chain, genesis first.
chainActions :: Chain -> [Action]
chainActions (Chain g rest) = g : toList rest

-- | Lean @head@: the digest of the latest admitted action.
head :: Chain -> Text
head (Chain g rest) = case viewr rest of
    EmptyR -> actionDigest g
    _ :> a -> actionDigest a

-- | Lean @roster@: membership replayed from the chain.
roster :: Chain -> Roster
roster = foldl' applyCore (Roster [] []) . chainActions

-- | Lean @applyCore@: the effect of one admitted action.
applyCore :: Roster -> Action -> Roster
applyCore r a = case payload a of
    Genesis -> Roster [signer a] [signer a]
    Add x -> Roster (x : members r) (admins r)
    Remove x -> Roster (without x (members r)) (without x (admins r))
    Grant x -> Roster (members r) (x : admins r)
    Revoke x -> Roster (members r) (without x (admins r))
    Leave ->
        Roster
            (without (signer a) (members r))
            (without (signer a) (admins r))
    App _ -> r
  where
    without x = filter (/= x)

-- | Lean @guardOk@: the roster has no members, or has an admin.
guardOk :: Roster -> Bool
guardOk r = null (members r) || not (null (admins r))

{- | Lean @membershipOk@: the core membership rule for an action
against the roster @ before it, @ telling whether a KEL is
hosted. Checked in the order of the refusals: the signer is an admin
(add, remove, grant, revoke), an added identity is hosted, the target
is in the state the payload requires, and the roster after the action
has no members or an admin (the last-admin guard).
-}
membershipOk
    :: (Text -> Bool) -> Roster -> Action -> Either GroupRefusal ()
membershipOk hosted r a = do
    case payload a of
        Add x -> do
            byAdmin
            unless (hosted x) $ Left MemberNotHosted
            when (isMember x) $ Left AlreadyMember
        Remove x -> do
            byAdmin
            unless (isMember x) $ Left TargetNotMember
        Grant x -> do
            byAdmin
            unless (isMember x) $ Left TargetNotMember
            when (isAdmin x) $ Left AlreadyAdmin
        Revoke x -> do
            byAdmin
            unless (isAdmin x) $ Left TargetNotAdmin
        Genesis -> pure ()
        Leave -> pure ()
        App _ -> pure ()
    unless (guardOk (applyCore r a)) $ Left LastAdmin
  where
    isMember x = x `elem` members r
    isAdmin x = x `elem` admins r
    byAdmin = unless (isAdmin (signer a)) $ Left NotAnAdmin

-- --------------------------------------------------------
-- Group index
-- --------------------------------------------------------

{- | Where a group's history lies: its head and, for every identity
that signed an action of the group or was the target of an @add@,
former members included, the tip of its KEL, by prefix. Not
evidence: a reader re-checks everything it fetches from it.
-}
data GroupIndex = GroupIndex
    { indexHead :: Text
    , indexKels :: [(Text, Text)]
    -- ^ prefix and KEL tip, sorted by prefix, no duplicates
    }
    deriving stock (Show, Eq)

-- | The index of a chain over the hosted KELs.
groupIndex :: Map Text MemberKel -> Chain -> GroupIndex
groupIndex kels chain =
    GroupIndex
        { indexHead = head chain
        , indexKels =
            [ (pfx, Kel.tip kel)
            | pfx <- Set.toAscList prefixes
            , Just kel <- [Map.lookup pfx kels]
            ]
        }
  where
    prefixes = Set.fromList (concatMap involved (chainActions chain))
    involved a = case payload a of
        Add x -> [signer a, x]
        _ -> [signer a]

-- --------------------------------------------------------
-- Admission
-- --------------------------------------------------------

{- | Lean @admit@: the state with the action appended to its
signer's KEL and its group's chain, or the first refusal.
-}
admit
    :: Hosted -> SignedEvent -> Either GroupRefusal (Hosted, Admission)
admit Hosted{hostedKels, hostedChains} se = do
    a <- decodeAction se
    kel <-
        maybe (Left (KelRefused Unhosted)) Right $
            Map.lookup (signer a) hostedKels
    kel' <- first KelRefused $ appendInteraction kel se
    chain <-
        extend (`Map.member` hostedKels) (Map.lookup (gid a) hostedChains) a
    pure
        ( Hosted
            { hostedKels = Map.insert (signer a) kel' hostedKels
            , hostedChains = Map.insert (gid a) chain hostedChains
            }
        , admission a
        )

{- | The group conditions of Lean @Admissible@: a genesis of an
unused id; or an existing group, a signer who is a current member, a
@prev@ that is the head, and 'membershipOk' against the roster.
@hosted@ tells whether a KEL is hosted.
-}
extend
    :: (Text -> Bool) -> Maybe Chain -> Action -> Either GroupRefusal Chain
extend hosted mchain a = case (payload a, mchain) of
    (Genesis, Nothing) -> Right (Chain a Seq.empty)
    (Genesis, Just _) -> Left GroupExists
    (_, Nothing) -> Left NoSuchGroup
    (_, Just chain@(Chain g rest)) -> do
        let r = roster chain
        unless (signer a `elem` members r) $ Left NotAMember
        unless (prev a == Just (head chain)) $ Left PrevNotHead
        membershipOk hosted r a
        pure (Chain g (rest |> a))

admission :: Action -> Admission
admission a =
    Admission
        { admittedGroup = gid a
        , admittedHead = actionDigest a
        , admittedPrefix = signer a
        , admittedSn = eventSequenceNumber (event (signed a))
        }

{- | The admission of an action whose signed bytes and signatures
are those of an event already in its signer's KEL: a retried
submission, answered as its admission was. Identity is the
canonical serialization, not 'Event' equality: JSON numbers in
the anchor compare by value, so @1@ and @1.0@ are equal events
with different bytes, and the second is no retry.
-}
retried :: Hosted -> SignedEvent -> Maybe Admission
retried Hosted{hostedKels} se = do
    a <- either (const Nothing) Just (decodeAction se)
    kel <- Map.lookup (signer a) hostedKels
    stored <-
        listToMaybe $
            drop (eventSequenceNumber (event se)) (kelEvents kel)
    guard $
        serializeEvent (event stored) == serializeEvent (event se)
            && signatures stored == signatures se
    pure (admission a)

{- | Rebuild every chain from the interactions of the hosted KELs.
Each must be a group action, and each group must be one line of
@prev@ links from its genesis (Lean @ChainLine@) whose every
action meets the group conditions of admission at its position,
membership rule included, a KEL counting as hosted when it is
among the given ones.
-}
rebuildChains :: Map Text MemberKel -> Either String (Map Text Chain)
rebuildChains kels = do
    actions <- traverse toAction interactions
    let geneses = [a | a <- actions, payload a == Genesis]
        links =
            Map.fromListWith
                (flip (<>))
                [((gid a, h), [a]) | a <- actions, Just h <- [prev a]]
    chains <- traverse (line (length actions) links) geneses
    unless (sum (map (length . chainActions) chains) == length actions) $
        Left "an action's prev does not resolve in its group's chain"
    pure $ Map.fromList [(gid g, c) | c@(Chain g _) <- chains]
  where
    interactions =
        [ se
        | kel <- Map.elems kels
        , se@SignedEvent{event = Interaction{}} <- kelEvents kel
        ]
    toAction se =
        first (\r -> at se <> ": not a group action, " <> show r) $
            decodeAction se
    line fuel links g = go fuel (Chain g Seq.empty)
      where
        go n chain
            | n < 0 = Left ("group " <> T.unpack (gid g) <> ": prev links loop")
            | otherwise =
                case Map.findWithDefault [] (gid g, head chain) links of
                    [] -> Right chain
                    [a] -> case extend (`Map.member` kels) (Just chain) a of
                        Right chain' -> go (n - 1) chain'
                        Left r -> Left (at (signed a) <> ": " <> show r)
                    _ ->
                        Left ("group " <> T.unpack (gid g) <> ": two actions with one prev")
    at SignedEvent{event} =
        T.unpack (eventDigest event)
