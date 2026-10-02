-- | INV-41-KEL/unit: the client re-checks every fetched KEL with the KERI
-- | rule of the server and refuses a tampered one `KelInvalid` at the
-- | tampered event's prefix and `s`, with the server's refusal class as
-- | the reason. Every tampering is legitimately signed: one field is
-- | changed, the SAID recomputed and the event signed again, so exactly
-- | one clause of the rule breaks. Each clause is exercised on every
-- | event kind it applies to: inception, rotation, interaction. An
-- | interaction that is no group action refuses its KEL too
-- | (`notAGroupAction`, checked through the replay).
module Test.KelSpec (checks) where

import Prelude

import Data.Argonaut.Core (Json, fromObject, fromString, jsonEmptyObject, stringify)
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..), snd)
import Effect.Aff (Aff)
import FFI.TweetNaCl (KeyPair)
import Foreign.Object as Object
import KelGroups.Client.Group (replayGroup)
import KelGroups.Client.Kel
  ( SyncRefusal(..)
  , ValidatedKel
  , decodeSignedEvent
  , encodeSignedEvent
  , kelPrefix
  , kelSn
  , kelTip
  , validateKel
  )
import Keri.Event
  ( Event(..)
  , InceptionData
  , InteractionData
  , RotationData
  , eventPrefix
  )
import Keri.Event.Inception (mkInception)
import Keri.Event.Interaction (mkInteraction)
import Keri.Event.Rotation (mkRotation)
import Keri.Kel (SignedEvent)
import Test.Check (Part, check, property)
import Test.Fixtures
  ( Ident
  , Keys
  , appP
  , commit
  , digestOf
  , genKeysN
  , genesisAnchor
  , incept
  , interact
  , pubKey
  , resaid
  , rotate
  , signIdx
  , signWith
  , snOf
  )
import Test.QuickCheck (Result(..), (===))
import Test.QuickCheck.Gen (Gen, chooseInt, vectorOf)

-- | A legitimate KEL: an inception and up to four rotations and
-- | interactions; current and next keys `n` with threshold `t`.
genIdentN :: Int -> Int -> Gen Ident
genIdentN n t = do
  cur <- genKeysN n t
  nxt <- genKeysN n t
  k <- chooseInt 0 4
  steps <- vectorOf k (chooseInt 0 1)
  grow (incept cur nxt) steps

-- | Rotations (0) and interactions (1), keeping the key shape.
grow :: Ident -> Array Int -> Gen Ident
grow id steps = case Array.uncons steps of
  Nothing -> pure id
  Just { head, tail } -> do
    id' <-
      if head == 0 then do
        ks <- genKeysN (Array.length id.next.pairs) id.next.threshold
        pure (snd (rotate ks id))
      else pure (snd (interact [ appP (fromString "x") ] id))
    grow id' tail

data Kind = Icp | Rot | Ixn

kindName :: Kind -> String
kindName = case _ of
  Icp -> "inception"
  Rot -> "rotation"
  Ixn -> "interaction"

-- | The event under test, legitimately built, the events before it and
-- | the pairs that legitimately sign it (index = position).
type Target =
  { before :: Array SignedEvent
  , prefix :: String
  , event :: Event
  , pairs :: Array KeyPair
  , tip :: String
  , sn :: Int
  }

-- | A target of a kind whose signing keys are `n` with threshold `t`.
genTarget :: Kind -> Int -> Int -> Gen Target
genTarget kind n t = case kind of
  Icp -> do
    cur <- genKeysN n t
    nxt <- genKeysN n t
    let
      e = mkInception
        { keys: map pubKey cur.pairs
        , signingThreshold: cur.threshold
        , nextKeys: map commit nxt.pairs
        , nextThreshold: nxt.threshold
        , config: []
        , anchors: []
        }
    pure { before: [], prefix: eventPrefix e, event: e, pairs: cur.pairs, tip: "", sn: -1 }
  Rot -> do
    id <- genIdentN n t
    nxt <- genKeysN n t
    pure
      { before: id.events
      , prefix: id.prefix
      , event: nextRot id (map pubKey id.next.pairs) id.next.threshold nxt
      , pairs: id.next.pairs
      , tip: id.tip
      , sn: id.sn
      }
  Ixn -> do
    id <- genIdentN n t
    pure
      { before: id.events
      , prefix: id.prefix
      , event: nextIxn id
      , pairs: id.current.pairs
      , tip: id.tip
      , sn: id.sn
      }

nextIxn :: Ident -> Event
nextIxn id = mkInteraction
  { prefix: id.prefix
  , sequenceNumber: id.sn + 1
  , priorDigest: id.tip
  , anchors: [ appP (fromString "y") ]
  }

nextRot :: Ident -> Array String -> Int -> Keys -> Event
nextRot id keys kt nxt = mkRotation
  { prefix: id.prefix
  , sequenceNumber: id.sn + 1
  , priorDigest: id.tip
  , keys
  , signingThreshold: kt
  , nextKeys: map commit nxt.pairs
  , nextThreshold: nxt.threshold
  , config: []
  , anchors: []
  }

-- | The KEL with the tampered event is refused at that event: the KEL
-- | prefix, or the inception's own `i` when it is the first event.
refused :: Target -> SignedEvent -> String -> Result
refused tg se reason =
  map (const unit) (validateKel (Array.snoc tg.before se))
    === Left
      ( KelInvalid
          { prefix: if Array.null tg.before then eventPrefix se.event else tg.prefix
          , s: snOf se
          , reason
          }
      )

-- | Change fields of the event, recompute its SAID, sign legitimately.
edited :: Target -> (Event -> Event) -> SignedEvent
edited tg f = signWith tg.pairs (resaid (f tg.event))

clause :: String -> Array Kind -> (Kind -> Gen Result) -> Array Part
clause name kinds run =
  map (\k -> property (name <> " (" <> kindName k <> ")") 5 (run k)) kinds

all3 :: Array Kind
all3 = [ Icp, Rot, Ixn ]

establishing :: Array Kind
establishing = [ Icp, Rot ]

extending :: Array Kind
extending = [ Rot, Ixn ]

type Edits =
  { icp :: InceptionEdit
  , rot :: RotationEdit
  , ixn :: InteractionEdit
  }

type InceptionEdit = InceptionData -> InceptionData
type RotationEdit = RotationData -> RotationData
type InteractionEdit = InteractionData -> InteractionData

-- | Field edits per kind.
onKind :: Edits -> Event -> Event
onKind f = case _ of
  Inception d -> Inception (f.icp d)
  Rotation d -> Rotation (f.rot d)
  Interaction d -> Interaction (f.ixn d)
  other -> other

summary
  :: Either SyncRefusal ValidatedKel
  -> Either SyncRefusal { prefix :: String, tip :: String, sn :: Int }
summary = map \k -> { prefix: kelPrefix k, tip: kelTip k, sn: kelSn k }

roundTrip :: Array SignedEvent -> Either String (Array SignedEvent)
roundTrip = traverse \se ->
  jsonParser (stringify (encodeSignedEvent se)) >>= decodeSignedEvent

-- | A founder's KEL holding its genesis and then an interaction with
-- | these anchors: replaying the group refuses the KEL at that event.
notAGroupAction :: Array Json -> Gen Result
notAGroupAction anchors = do
  cur <- genKeysN 1 1
  nxt <- genKeysN 1 1
  let
    Tuple genesis a1 = interact [ genesisAnchor ] (incept cur nxt)
    Tuple bad a2 = interact anchors a1
    g = digestOf genesis
  pure case validateKel a2.events of
    Left r -> Failed ("KEL refused before replay: " <> show r)
    Right kel ->
      map (const unit) (replayGroup g g (Map.singleton a2.prefix kel))
        === Left (KelInvalid { prefix: a2.prefix, s: snOf bad, reason: "notAGroupAction" })

obj :: Array (Tuple String Json) -> Json
obj = fromObject <<< Object.fromFoldable

checks :: Array (Aff Boolean)
checks =
  [ check "INV-41-KEL/unit"
      "a valid KEL is accepted and every tampering is refused KelInvalid at its prefix and s"
      $ Array.concat
        [ [ property "valid KEL accepted, also after the wire round trip" 10 do
            n <- chooseInt 1 3
            t <- chooseInt 1 n
            id <- genIdentN n t
            let expected = Right { prefix: id.prefix, tip: id.tip, sn: id.sn }
            pure $
              Tuple (summary (validateKel id.events))
                (map (summary <<< validateKel) (roundTrip id.events))
                === Tuple expected (Right expected)
          ]
        , clause "SAID mismatch" all3 \k -> do
            tg <- genTarget k 1 1
            other <- genTarget Ixn 1 1
            let
              wrong = case other.event of
                Interaction d -> d.digest
                _ -> ""
              e = onKind
                { icp: _ { digest = wrong }, rot: _ { digest = wrong }, ixn: _ { digest = wrong } }
                tg.event
            pure $ refused tg (signWith tg.pairs e) "saidMismatch"
        , clause "signed by a key that is not the controlling one" all3 \k -> do
            tg <- genTarget k 1 1
            other <- genKeysN 1 1
            pure $ refused tg (signWith other.pairs tg.event) "invalidSignatures"
        , clause "under the signing threshold" all3 \k -> do
            tg <- genTarget k 2 2
            pure $ withPair tg \kp -> refused tg (signIdx [ Tuple 0 kp ] tg.event) "invalidSignatures"
        , clause "duplicate signature index" all3 \k -> do
            tg <- genTarget k 2 2
            pure $ withPair tg \kp ->
              refused tg (signIdx [ Tuple 0 kp, Tuple 0 kp ] tg.event) "invalidSignatures"
        , clause "signature index out of range" all3 \k -> do
            tg <- genTarget k 1 1
            pure $ withPair tg \kp -> refused tg (signIdx [ Tuple 1 kp ] tg.event) "invalidSignatures"
        , clause "non-canonical signature" all3 \k -> do
            tg <- genTarget k 1 1
            let
              se = signWith tg.pairs tg.event
              bent = se { signatures = map (\s -> s { signature = s.signature <> "A" }) se.signatures }
            pure $ refused tg bent "invalidSignatures"
        , clause "no next-key commitment" establishing \k -> do
            tg <- genTarget k 1 1
            pure $ refused tg
              ( edited tg $ onKind
                  { icp: _ { nextKeys = [], nextThreshold = 0 }
                  , rot: _ { nextKeys = [], nextThreshold = 0 }
                  , ixn: identity
                  }
              )
              "missingNextCommitment"
        , clause "signing threshold above the keys" establishing \k -> do
            tg <- genTarget k 1 1
            pure $ refused tg
              ( edited tg $ onKind
                  { icp: _ { signingThreshold = 2 }, rot: _ { signingThreshold = 2 }, ixn: identity }
              )
              "thresholdOutOfRange"
        , clause "next threshold above the commitments" establishing \k -> do
            tg <- genTarget k 1 1
            pure $ refused tg
              ( edited tg $ onKind
                  { icp: _ { nextThreshold = 2 }, rot: _ { nextThreshold = 2 }, ixn: identity }
              )
              "thresholdOutOfRange"
        , clause "witnesses" establishing \k -> do
            tg <- genTarget k 1 1
            let key = map pubKey tg.pairs
            pure $ refused tg
              ( edited tg $ onKind
                  { icp: _ { witnessThreshold = 1, witnesses = key }
                  , rot: _ { witnessThreshold = 1, witnessesAdded = key }
                  , ixn: identity
                  }
              )
              "witnessesPresent"
        , clause "foreign prefix" extending \k -> do
            tg <- genTarget k 1 1
            other <- genTarget Icp 1 1
            pure $ refused tg
              ( edited tg $ onKind
                  { icp: identity, rot: _ { prefix = other.prefix }, ixn: _ { prefix = other.prefix } }
              )
              "foreignPrefix"
        , clause "wrong p at the next s" extending \k -> do
            tg <- genTarget k 1 1
            other <- genTarget Ixn 1 1
            pure $ refused tg
              ( edited tg $ onKind
                  { icp: identity, rot: _ { priorDigest = other.tip }, ixn: _ { priorDigest = other.tip } }
              )
              "notTipSuccessor"
        , clause "wrong s with p the tip" extending \k -> do
            tg <- genTarget k 1 1
            jump <- chooseInt 2 3
            let s = tg.sn + jump
            pure $ refused tg
              ( edited tg $ onKind
                  { icp: identity, rot: _ { sequenceNumber = s }, ixn: _ { sequenceNumber = s } }
              )
              "notTipSuccessor"
        , clause "s not past the tip" extending \k -> do
            tg <- genTarget k 1 1
            let s = tg.sn
            pure $ refused tg
              ( edited tg $ onKind
                  { icp: identity, rot: _ { sequenceNumber = s }, ixn: _ { sequenceNumber = s } }
              )
              "notTipSuccessor"
        ,
            [ property "inception prefix is not its SAID" 5 do
                tg <- genTarget Icp 1 1
                other <- genTarget Icp 1 1
                let
                  e = case tg.event of
                    Inception d -> Inception d { prefix = other.prefix }
                    x -> x
                pure $ refused tg (signWith tg.pairs (resaid e)) "prefixNotSaid"
            , property "inception not at s 0" 5 do
                tg <- genTarget Icp 1 1
                pure $ refused tg
                  (edited tg (onKind { icp: _ { sequenceNumber = 1 }, rot: identity, ixn: identity }))
                  "inceptionNotFirst"
            , property "rotation not revealing the commitment" 5 do
                tg <- genTarget Rot 1 1
                fresh <- genKeysN 1 1
                let
                  e = resaid $ onKind
                    { icp: identity, rot: _ { keys = map pubKey fresh.pairs }, ixn: identity }
                    tg.event
                pure $ refused tg (signWith fresh.pairs e) "commitmentNotRevealed"
            , property "rotation meeting its own threshold but not the prior next threshold" 5 do
                cur <- genKeysN 1 1
                nxt <- genKeysN 2 2
                after <- genKeysN 1 1
                let
                  id = incept cur nxt
                  e = nextRot id (map pubKey nxt.pairs) 1 after
                  tg = { before: id.events, prefix: id.prefix, event: e, pairs: nxt.pairs, tip: id.tip, sn: id.sn }
                pure $ withPair tg \kp -> refused tg (signIdx [ Tuple 0 kp ] e) "invalidSignatures"
            , property "rotation meeting the prior next threshold but not its own threshold" 5 do
                cur <- genKeysN 1 1
                nxt <- genKeysN 2 1
                after <- genKeysN 1 1
                let
                  id = incept cur nxt
                  e = nextRot id (map pubKey nxt.pairs) 2 after
                  tg = { before: id.events, prefix: id.prefix, event: e, pairs: nxt.pairs, tip: id.tip, sn: id.sn }
                pure $ withPair tg \kp -> refused tg (signIdx [ Tuple 0 kp ] e) "invalidSignatures"
            , property "rotation meeting both thresholds with one of two keys is accepted" 5 do
                cur <- genKeysN 1 1
                nxt <- genKeysN 2 1
                after <- genKeysN 1 1
                let
                  id = incept cur nxt
                  e = nextRot id (map pubKey nxt.pairs) 1 after
                  tg = { before: id.events, prefix: id.prefix, event: e, pairs: nxt.pairs, tip: id.tip, sn: id.sn }
                pure $ withPair tg \kp ->
                  map kelSn (validateKel (Array.snoc tg.before (signIdx [ Tuple 0 kp ] e))) === Right 1
            , property "a second inception" 5 do
                tg <- genTarget Ixn 1 1
                other <- genTarget Icp 1 1
                pure $ refused tg (signWith other.pairs other.event) "unexpectedEventKind"
            , property "a first event that is no inception at s 0" 5 do
                tg <- genTarget Ixn 1 1
                let
                  e = resaid $ onKind
                    { icp: identity, rot: identity, ixn: _ { sequenceNumber = 0, prefix = tg.prefix } }
                    tg.event
                  se = signWith tg.pairs e
                pure $
                  map (const unit) (validateKel [ se ])
                    === Left (KelInvalid { prefix: tg.prefix, s: 0, reason: "unexpectedEventKind" })
            , property "interaction without an anchor (notAGroupAction)" 5 $ notAGroupAction []
            , property "interaction with two anchors (notAGroupAction)" 5 $
                notAGroupAction [ genesisAnchor, genesisAnchor ]
            , property "interaction with a foreign anchor (notAGroupAction)" 5 $
                notAGroupAction [ obj [ Tuple "x" (fromString "y") ] ]
            , property "group anchor with an extra key (notAGroupAction)" 5 $
                notAGroupAction
                  [ obj
                      [ Tuple "group" (fromString "g")
                      , Tuple "payload" (appP (fromString "z"))
                      , Tuple "prev" (fromString "h")
                      , Tuple "extra" jsonEmptyObject
                      ]
                  ]
            , property "unknown payload (notAGroupAction)" 5 $
                notAGroupAction
                  [ obj
                      [ Tuple "group" (fromString "g")
                      , Tuple "payload" (obj [ Tuple "t" (fromString "bogus") ])
                      , Tuple "prev" (fromString "h")
                      ]
                  ]
            ]
        ]
  ]

withPair :: Target -> (KeyPair -> Result) -> Result
withPair tg f = case Array.head tg.pairs of
  Just kp -> f kp
  Nothing -> Failed "fixture without keys"
