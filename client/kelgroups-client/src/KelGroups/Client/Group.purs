-- | The group as a client replays it from validated member KELs, in the
-- | words of the Lean model (`KelGroups.Sovereign`): `Payload`, `Action`,
-- | `Roster`, `applyCore`, `roster`, `guardOk`, `membershipOk`.
-- |
-- | A group action is an interaction in its signer's KEL whose `a` holds
-- | exactly one group anchor, in the wire form of `KelGroups.Group`:
-- |
-- |     {"payload": {"t": "genesis"}}
-- |     {"group": <group id>, "payload": <payload>, "prev": <head digest>}
-- |
-- | with a non-genesis payload one of `{"member": <prefix>, "t": "add"}`
-- | (likewise `remove`, `grant`, `revoke`), `{"t": "leave"}` and
-- | `{"data": <any>, "t": "app"}`. A genesis names no group: its group id
-- | is the event's own `d`.
-- |
-- | `replayGroup` walks `prev` from a head back to the genesis by local
-- | lookup (Lean `ChainLine`), follows the actions that extend that head
-- | to the end of the line, and folds the roster checking at each
-- | position the group conditions of Lean `Admissible`: the signer a
-- | current member and `membershipOk`, an added identity counting as
-- | hosted when its KEL is among the validated ones. `signAction` signs a
-- | payload against a view: `p` is the signer's validated tip, `prev` the
-- | view head.
module KelGroups.Client.Group
  ( GroupId
  , Payload(..)
  , Action
  , Roster(..)
  , GroupView
  , viewRecord
  , Signer
  , decodeAction
  , encodeAnchor
  , applyCore
  , roster
  , guardOk
  , membershipOk
  , replayGroup
  , signAction
  ) where

import Prelude

import Control.Monad.Rec.Class (Step(..), tailRec)
import Data.Argonaut.Core
  ( Json
  , caseJson
  , fromArray
  , fromBoolean
  , fromNumber
  , fromObject
  , fromString
  , jsonNull
  , toObject
  , toString
  )
import Data.Array as Array
import Data.ArrayBuffer.Types (Uint8Array)
import Data.Either (Either(..), note)
import Data.Foldable (foldl, minimum)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Set as Set
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import FFI.TextEncoder (encodeUtf8)
import FFI.TweetNaCl as NaCl
import FFI.Uint8Array as U8
import Foreign.Object (Object)
import Foreign.Object as Object
import KelGroups.Client.Kel
  ( Digest
  , Prefix
  , SyncRefusal(..)
  , ValidatedKel
  , kelEvents
  , kelKeys
  , kelSn
  , kelTip
  )
import Keri.Cesr.DerivationCode (DerivationCode(..))
import Keri.Cesr.Encode as Cesr
import Keri.Event (Event(..))
import Keri.Event.Interaction (mkInteraction)
import Keri.Event.Serialize (serializeEvent)
import Keri.Kel (SignedEvent)

-- | A group identifier: the SAID of the group's genesis action.
type GroupId = String

-- | Lean `Payload`: the core payloads and the membership vocabulary.
data Payload
  = Genesis
  | Add Prefix
  | Remove Prefix
  | Grant Prefix
  | Revoke Prefix
  | Leave
  | App Json

derive instance eqPayload :: Eq Payload

instance showPayload :: Show Payload where
  show = case _ of
    Genesis -> "Genesis"
    Add x -> "Add " <> x
    Remove x -> "Remove " <> x
    Grant x -> "Grant " <> x
    Revoke x -> "Revoke " <> x
    Leave -> "Leave"
    App _ -> "App"

-- | Lean `Action`: a group action and the event it was decoded from.
type Action =
  { signer :: Prefix
  , gid :: GroupId
  , p :: Digest
  , payload :: Payload
  , prev :: Maybe Digest
  , digest :: Digest
  , sn :: Int
  }

-- | Lean `Roster`: members and admins, in `applyCore` order.
newtype Roster = Roster { members :: Array Prefix, admins :: Array Prefix }

derive instance eqRoster :: Eq Roster

instance showRoster :: Show Roster where
  show (Roster r) = "Roster " <> show r

-- | A group as replayed from a refusal-free sync: its head, its chain
-- | (genesis first), its roster, and the validated KELs it came from.
newtype GroupView = GroupView
  { group :: GroupId
  , head :: Digest
  , chain :: Array Action
  , roster :: Roster
  , kels :: Map Prefix ValidatedKel
  }

derive instance eqGroupView :: Eq GroupView

instance showGroupView :: Show GroupView where
  show (GroupView v) =
    "GroupView " <> v.group <> " head=" <> v.head <> " " <> show v.roster

-- | What a view holds, read-only: a `GroupView` is built only by
-- | `replayGroup`.
viewRecord
  :: GroupView
  -> { group :: GroupId, head :: Digest, chain :: Array Action, roster :: Roster, kels :: Map Prefix ValidatedKel }
viewRecord (GroupView v) = v

-- | Who signs: an identifier and its Ed25519 secret key (tweetnacl form).
type Signer = { prefix :: Prefix, secretKey :: Uint8Array }

-- | The group action an interaction carries.
decodeAction :: SignedEvent -> Either String Action
decodeAction se = case se.event of
  Interaction d -> case d.anchors of
    [ anchor ] -> do
      { gid, payload, prev } <- parseAnchor d.digest anchor
      pure
        { signer: d.prefix
        , gid
        , p: d.priorDigest
        , payload
        , prev
        , digest: d.digest
        , sn: d.sequenceNumber
        }
    _ -> Left "a must hold exactly one anchor"
  _ -> Left "not an interaction"

parseAnchor
  :: Digest -> Json -> Either String { gid :: GroupId, payload :: Payload, prev :: Maybe Digest }
parseAnchor d json = do
  o <- object "group anchor" json
  payload <- field o "payload" >>= parsePayload
  case payload of
    Genesis -> do
      exactKeys "genesis anchor" [ "payload" ] o
      pure { gid: d, payload, prev: Nothing }
    _ -> do
      exactKeys "group anchor" [ "group", "prev", "payload" ] o
      gid <- field o "group" >>= string "group"
      prev <- field o "prev" >>= string "prev"
      pure { gid, payload, prev: Just prev }

parsePayload :: Json -> Either String Payload
parsePayload json = do
  o <- object "payload" json
  t <- field o "t" >>= string "t"
  let
    member = do
      exactKeys "membership payload" [ "t", "member" ] o
      field o "member" >>= string "member"
  case t of
    "genesis" -> Genesis <$ exactKeys "genesis payload" [ "t" ] o
    "add" -> Add <$> member
    "remove" -> Remove <$> member
    "grant" -> Grant <$> member
    "revoke" -> Revoke <$> member
    "leave" -> Leave <$ exactKeys "leave payload" [ "t" ] o
    "app" -> do
      exactKeys "app payload" [ "t", "data" ] o
      App <$> field o "data"
    other -> Left ("unknown payload " <> show other)

-- | The anchor of an action of group `g` extending head `h`, its keys in
-- | the order the server re-serializes them (sorted), application data
-- | included.
encodeAnchor :: GroupId -> Digest -> Payload -> Json
encodeAnchor g h = case _ of
  Genesis -> obj [ Tuple "payload" (obj [ Tuple "t" (fromString "genesis") ]) ]
  pl -> obj
    [ Tuple "group" (fromString g)
    , Tuple "payload" (payloadJson pl)
    , Tuple "prev" (fromString h)
    ]
  where
  member t x = obj [ Tuple "member" (fromString x), Tuple "t" (fromString t) ]
  payloadJson = case _ of
    Genesis -> obj [ Tuple "t" (fromString "genesis") ]
    Add x -> member "add" x
    Remove x -> member "remove" x
    Grant x -> member "grant" x
    Revoke x -> member "revoke" x
    Leave -> obj [ Tuple "t" (fromString "leave") ]
    App d -> obj [ Tuple "data" (sortKeys d), Tuple "t" (fromString "app") ]

obj :: Array (Tuple String Json) -> Json
obj = fromObject <<< Object.fromFoldable

-- | Every object's keys in sorted order, as aeson writes them.
sortKeys :: Json -> Json
sortKeys json = caseJson
  (const jsonNull)
  fromBoolean
  fromNumber
  fromString
  (fromArray <<< map sortKeys)
  ( \o -> obj
      ( map (\k -> Tuple k (maybe' (Object.lookup k o)))
          (Array.sort (Object.keys o))
      )
  )
  json
  where
  maybe' = case _ of
    Just v -> sortKeys v
    Nothing -> jsonNull

-- | Lean `applyCore`: the effect of one admitted action.
applyCore :: Roster -> Action -> Roster
applyCore (Roster r) a = case a.payload of
  Genesis -> Roster { members: [ a.signer ], admins: [ a.signer ] }
  Add x -> Roster r { members = Array.cons x r.members }
  Remove x -> Roster { members: without x r.members, admins: without x r.admins }
  Grant x -> Roster r { admins = Array.cons x r.admins }
  Revoke x -> Roster r { admins = without x r.admins }
  Leave -> Roster { members: without a.signer r.members, admins: without a.signer r.admins }
  App _ -> Roster r
  where
  without x = Array.filter (_ /= x)

-- | Lean `roster`: membership replayed from a chain.
roster :: Array Action -> Roster
roster = foldl applyCore (Roster { members: [], admins: [] })

-- | Lean `guardOk`: no members, or an admin.
guardOk :: Roster -> Boolean
guardOk (Roster r) = Array.null r.members || not (Array.null r.admins)

-- | Lean `membershipOk` against the roster before the action, `hosted`
-- | telling whether a KEL is among the validated ones: the refusal
-- | class of the first failing condition, in the server's order (signer
-- | an admin, added identity hosted, target state, last-admin guard).
membershipOk :: (Prefix -> Boolean) -> Roster -> Action -> Either String Unit
membershipOk hosted (Roster r) a = do
  case a.payload of
    Add x -> do
      byAdmin
      unless (hosted x) $ Left "memberNotHosted"
      when (isMember x) $ Left "alreadyMember"
    Remove x -> do
      byAdmin
      unless (isMember x) $ Left "targetNotMember"
    Grant x -> do
      byAdmin
      unless (isMember x) $ Left "targetNotMember"
      when (isAdmin x) $ Left "alreadyAdmin"
    Revoke x -> do
      byAdmin
      unless (isAdmin x) $ Left "targetNotAdmin"
    _ -> pure unit
  unless (guardOk (applyCore (Roster r) a)) $ Left "lastAdmin"
  where
  isMember x = Array.elem x r.members
  isAdmin x = Array.elem x r.admins
  byAdmin = unless (isAdmin a.signer) $ Left "notAnAdmin"

-- | Walk from `head` back to the genesis of group `g` by local lookup
-- | among the group actions of the validated KELs: a digest found nowhere
-- | is a `Gap`; one found in another group makes the action holding it,
-- | or the head itself, `NotOnLine`; the walk ends only at the genesis
-- | whose `d` is `g`. Then follow the actions extending the line past `head` to
-- | its end, require every action of the group to be on that one line
-- | (else `NotOnLine`, naming the smallest such digest), and fold the
-- | roster checking the group conditions at each position (else
-- | `RuleViolation`). An interaction that is no group action refuses the
-- | KEL that holds it.
replayGroup
  :: GroupId -> Digest -> Map Prefix ValidatedKel -> Either SyncRefusal GroupView
replayGroup g h kels = do
  everyAction <- Array.concat <$> traverse groupActions (Map.toUnfoldable kels)
  let
    actions = Array.filter (\a -> a.gid == g) everyAction
    byDigest = Map.fromFoldable (map (\a -> Tuple a.digest a) everyAction)
    children = Map.fromFoldableWith (flip (<>))
      (Array.mapMaybe (\a -> map (\pr -> Tuple pr [ a ]) a.prev) actions)
    fuel = Array.length actions
  back <- walkBack byDigest fuel
  line <- forward children fuel back
  let
    onLine = Set.fromFoldable (map _.digest line)
    off = Array.filter (\a -> not (Set.member a.digest onLine)) actions
  case minimum (map _.digest off) of
    Just d -> Left (NotOnLine { digest: d })
    Nothing -> pure unit
  r <- fold line
  pure $ GroupView
    { group: g
    , head: maybe' h (map _.digest (Array.last line))
    , chain: line
    , roster: r
    , kels
    }
  where
  maybe' d = case _ of
    Just x -> x
    Nothing -> d

  groupActions (Tuple pfx kel) =
    traverse
      ( \se -> case decodeAction se of
          Right a -> Right a
          Left _ -> Left (KelInvalid { prefix: pfx, s: snOf se, reason: "notAGroupAction" })
      )
      (Array.filter isInteraction (kelEvents kel))

  walkBack byDigest fuel = case Map.lookup h byDigest of
    Nothing -> Left (Gap { missing: h })
    Just a0
      | a0.gid /= g -> Left (NotOnLine { digest: h })
      | otherwise -> tailRec go { a: a0, acc: [ a0 ], n: fuel }
    where
    go { a, acc, n }
      | n < 0 = Done (Left (NotOnLine { digest: a.digest }))
      | otherwise = case a.prev of
          -- only a genesis has no prev, and a genesis of g is the one whose d is g
          Nothing -> Done (Right acc)
          Just pr -> case Map.lookup pr byDigest of
            Nothing -> Done (Left (Gap { missing: pr }))
            Just b
              | b.gid /= g -> Done (Left (NotOnLine { digest: a.digest }))
              | otherwise -> Loop { a: b, acc: Array.cons b acc, n: n - 1 }

  forward children fuel back = tailRec go { line: back, n: fuel }
    where
    go { line, n } = case Array.last line of
      Nothing -> Done (Right line)
      Just end -> case Map.lookup end.digest children of
        Nothing -> Done (Right line)
        Just [ a ]
          | n < 0 -> Done (Left (NotOnLine { digest: a.digest }))
          | otherwise -> Loop { line: Array.snoc line a, n: n - 1 }
        Just as -> case minimum (map _.digest as) of
          Just d -> Done (Left (NotOnLine { digest: d }))
          Nothing -> Done (Right line)

  hosted x = Map.member x kels

  fold line = case Array.uncons line of
    Nothing -> Left (Gap { missing: h })
    Just { head: genesis, tail } ->
      tailRec go { r: applyCore (Roster { members: [], admins: [] }) genesis, i: 0 }
      where
      go { r: r@(Roster ro), i } = case Array.index tail i of
        Nothing -> Done (Right r)
        Just a
          | not (Array.elem a.signer ro.members) ->
              Done (Left (RuleViolation { digest: a.digest, class: "notAMember" }))
          | otherwise -> case membershipOk hosted r a of
              Left cls -> Done (Left (RuleViolation { digest: a.digest, class: cls }))
              Right _ -> Loop { r: applyCore r a, i: i + 1 }

isInteraction :: SignedEvent -> Boolean
isInteraction se = case se.event of
  Interaction _ -> true
  _ -> false

snOf :: SignedEvent -> Int
snOf se = case se.event of
  Inception d -> d.sequenceNumber
  Rotation d -> d.sequenceNumber
  Interaction d -> d.sequenceNumber
  Receipt d -> d.sequenceNumber

-- | Sign a payload against a view: an interaction on the signer's
-- | validated tip (`p`) whose anchor extends the view head (`prev`),
-- | signed with the signer's key at its index among the current keys.
-- | A signer whose KEL is not in the view, or whose key is not a
-- | current key, signs nothing (`NotSigner`).
signAction :: Signer -> GroupView -> Payload -> Either SyncRefusal SignedEvent
signAction s (GroupView v) payload = do
  let notSigner = NotSigner { prefix: s.prefix }
  kel <- note notSigner (Map.lookup s.prefix v.kels)
  let key = Cesr.encode { code: Ed25519PubKey, raw: U8.slice 32 64 s.secretKey }
  index <- note notSigner (Array.elemIndex key (kelKeys kel))
  let
    event = mkInteraction
      { prefix: s.prefix
      , sequenceNumber: kelSn kel + 1
      , priorDigest: kelTip kel
      , anchors: [ encodeAnchor v.group v.head payload ]
      }
    signature = Cesr.encode
      { code: Ed25519Sig
      , raw: NaCl.sign (encodeUtf8 (serializeEvent event)) s.secretKey
      }
  pure { event, signatures: [ { index, signature } ] }

object :: String -> Json -> Either String (Object Json)
object what = note (what <> ": not an object") <<< toObject

string :: String -> Json -> Either String String
string what = note (what <> ": not a string") <<< toString

field :: Object Json -> String -> Either String Json
field o k = note ("missing " <> k) (Object.lookup k o)

exactKeys :: String -> Array String -> Object Json -> Either String Unit
exactKeys what labels o =
  unless (Array.sort (Object.keys o) == Array.sort labels)
    $ Left (what <> ": fields must be exactly " <> show labels)
