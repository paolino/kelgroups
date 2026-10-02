-- | The client's sync rules against an in-memory stand-in for the server
-- | (`Test.FakeServer`): INV-41-OWN/unit (an own action is history only
-- | once a sync sees it; the next signature's `p` is the validated tip;
-- | no usable signer key signs and sends nothing) and
-- | INV-41-REWRITE/unit (a refreshed suffix that does not chain onto the
-- | local tip or fails the rule is `HistoryRewritten`, and the local view
-- | still refreshes against the honest history afterwards).
module Test.SyncSpec (checks) where

import Prelude

import Data.Argonaut.Core (fromArray, fromObject, fromString, stringify)
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Traversable (sequence, traverse)
import Data.Tuple (Tuple(..))
import Effect.Aff (Aff, throwError)
import Effect.Class (liftEffect)
import Effect.Exception (error)
import KelGroups.Client.Group (GroupView, Payload(..), Roster(..), signAction, viewRecord)
import KelGroups.Client.Kel (SyncRefusal(..), decodeSignedEvent, encodeSignedEvent, kelSn, kelTip)
import KelGroups.Client.Sync (Response, Submission(..), Transport, act, sync)
import Keri.Event (Event(..), eventDigest)
import Keri.Kel (SignedEvent)
import Test.Check (check, effectful)
import Test.FakeServer (fakeCalls, fakeTransport, loseAnswers, newFake, setState)
import Test.Fixtures (actionAnchor, appP, digestOf, genKeys, incept, interact, signWith, snOf)
import Test.QuickCheck (Result(..), (===))
import Test.QuickCheck.Gen (randomSampleOne)
import Test.Transports (indexCalls, newCalls, omitPrefix, posts, recording, reverseIndex)
import Foreign.Object as Object
import Test.World as W

tipOf :: String -> GroupView -> String
tipOf p gv = case Map.lookup p (viewRecord gv).kels of
  Just k -> kelTip k
  Nothing -> ""

snIn :: String -> GroupView -> Int
snIn p gv = case Map.lookup p (viewRecord gv).kels of
  Just k -> kelSn k
  Nothing -> -1

chainHas :: String -> GroupView -> Boolean
chainHas d gv = Array.any (\a -> a.digest == d) (viewRecord gv).chain

lastOf :: GroupView -> String
lastOf gv = case Array.last (viewRecord gv).chain of
  Just a -> a.digest
  Nothing -> ""

priorOf :: SignedEvent -> String
priorOf se = case se.event of
  Interaction d -> d.priorDigest
  _ -> ""

postedDigest :: String -> String
postedDigest body = case jsonParser body >>= decodeSignedEvent of
  Right se -> eventDigest se.event
  Left _ -> ""

-- | What a sync came to, in short.
shape :: Either SyncRefusal GroupView -> String
shape = case _ of
  Right _ -> "a view"
  Left (Transport r) -> "Transport " <> show r.status
  Left (KelInvalid r) -> "KelInvalid " <> r.prefix <> " " <> show r.s
  Left (HistoryRewritten r) -> "HistoryRewritten " <> r.prefix <> " " <> show r.s
  Left r -> show r

hasMember :: String -> GroupView -> Boolean
hasMember p gv = case (viewRecord gv).roster of
  Roster r -> Array.elem p r.members

noAnswer :: forall a. Aff a
noAnswer = throwError (error "no answer")

withIndex :: Aff Response -> Transport -> Transport
withIndex r t = t { getIndex = \_ -> r }

withKel :: String -> Aff Response -> Transport -> Transport
withKel p r t = t { getKel = \q after -> if q == p then r else t.getKel q after }

withPost :: Response -> Transport -> Transport
withPost r t = t { postAction = \_ -> pure r }

failed :: String -> Array (Tuple String Result)
failed m = [ Tuple "setup" (Failed m) ]

checks :: Array (Aff Boolean)
checks =
  [ check "INV-41-OWN/unit"
      "an own action counts only once a sync sees it; the next p is the validated tip; no signer key sends nothing"
      [ effectful "after a 200 without a sync" do
          t <- liftEffect (randomSampleOne W.genTeam)
          let w = t.world
          f <- liftEffect (newFake w.group w.head (W.kels w))
          let tr = fakeTransport f
          v0 <- sync tr w.group Nothing
          case v0, W.signerOf t.a w of
            Right view, Just sa -> do
              r <- act tr sa view (App (fromString "own"))
              case r of
                Right (Admitted adm) -> do
                  let
                    before = tipOf t.a view
                    next = signAction sa view (App (fromString "next"))
                  v1 <- sync tr w.group (Just view)
                  pure
                    [ Tuple "admitted against the view" (adm.prefix === t.a)
                    , Tuple "the next signature's p is the validated tip" (map priorOf next === Right before)
                    , Tuple "the view does not count the answered action"
                        (Tuple (tipOf t.a view) (chainHas adm.head view) === Tuple before false)
                    , Tuple "a sync that sees it makes it history"
                        (map (\v -> Tuple (tipOf t.a v) (lastOf v)) v1 === Right (Tuple adm.head adm.head))
                    ]
                other -> pure (failed ("act: " <> show other))
            other, _ -> pure (failed ("sync: " <> show (map (const unit) other)))
      , effectful "after lost answers" do
          t <- liftEffect (randomSampleOne W.genTeam)
          let w = t.world
          f <- liftEffect (newFake w.group w.head (W.kels w))
          let tr = fakeTransport f
          v0 <- sync tr w.group Nothing
          case v0, W.signerOf t.a w of
            Right view, Just sa -> do
              liftEffect (loseAnswers f 3)
              r <- act tr sa view (App (fromString "lost"))
              calls <- liftEffect (fakeCalls f)
              let
                lost = case Array.head calls.posts of
                  Just b -> postedDigest b
                  Nothing -> ""
                next = signAction sa view (App (fromString "next"))
              v1 <- sync tr w.group (Just view)
              pure
                [ Tuple "unanswered after three identical attempts"
                    (Tuple r (Tuple (Array.length calls.posts) (Array.length (Array.nub calls.posts))) === Tuple (Right Unanswered) (Tuple 3 1))
                , Tuple "the next signature's p is the validated tip"
                    (map priorOf next === Right (tipOf t.a view))
                , Tuple "a sync that sees it makes it history"
                    (map (\v -> Tuple (tipOf t.a v) (lastOf v)) v1 === Right (Tuple lost lost))
                ]
            other, _ -> pure (failed ("sync: " <> show (map (const unit) other)))
      , effectful "no usable signer key: nothing signed, nothing sent" do
          t <- liftEffect (randomSampleOne W.genTeam)
          stranger <- liftEffect (randomSampleOne (incept <$> genKeys <*> genKeys))
          let w = t.world
          f <- liftEffect (newFake w.group w.head (W.kels w))
          let tr = fakeTransport f
          v0 <- sync tr w.group Nothing
          case v0, W.signerOf t.a w, W.signerOf t.c w, Array.head stranger.current.pairs of
            Right view, Just sa, Just sc, Just kp -> do
              outside <- act tr { prefix: stranger.prefix, secretKey: kp.secretKey } view (App (fromString "x"))
              wrongKey <- act tr { prefix: t.a, secretKey: sc.secretKey } view (App (fromString "y"))
              calls <- liftEffect (fakeCalls f)
              pure
                [ Tuple "a signer outside the view" (outside === Left (NotSigner { prefix: stranger.prefix }))
                , Tuple "a key that is not a current key" (wrongKey === Left (NotSigner { prefix: t.a }))
                , Tuple "no request sent" (Array.length calls.posts === 0)
                , Tuple "the signer itself still signs" (map (const unit) (signAction sa view (App (fromString "z"))) === Right unit)
                ]
            _, _, _, _ -> pure (failed "setup")
      , effectful "a refusal other than a stale head or tip is reported once, not retried or re-signed" do
          t <- liftEffect (randomSampleOne W.genTeam)
          let w = t.world
          f <- liftEffect (newFake w.group w.head (W.kels w))
          v0 <- sync (fakeTransport f) w.group Nothing
          case v0, W.signerOf t.a w of
            Right view, Just sa ->
              let
                refusing (Tuple status err) = do
                  calls <- newCalls
                  let
                    body = "{\"error\":\"" <> err <> "\",\"detail\":\"refused\"}"
                    tr = recording calls (withPost { status, body } (fakeTransport f))
                  r <- act tr sa view (App (fromString err))
                  ps <- posts calls
                  ix <- indexCalls calls
                  pure $ Tuple (show status <> " " <> err)
                    ( Tuple r (Tuple (Array.length ps) ix)
                        === Tuple (Right (Refused { status, error: err })) (Tuple 1 0)
                    )
              in
                traverse refusing
                  [ Tuple 403 "notAMember"
                  , Tuple 422 "invalidSignatures"
                  , Tuple 409 "alreadyMember"
                  , Tuple 404 "noSuchGroup"
                  , Tuple 400 "notDecodable"
                  ]
            _, _ -> pure (failed "setup")
      ]
  , check "INV-41-REWRITE/unit"
      "sync refuses what it cannot read or validate and never rewrites validated history: a suffix not extending the local tip is HistoryRewritten"
      [ effectful "a suffix that does not chain onto the local tip" do
          t <- liftEffect (randomSampleOne W.genTeam)
          let
            local = W.act t.a (W.IApp (fromString "x")) t.world
            alt = W.act t.a (W.IApp (fromString "y")) t.world
            alt2 = W.act t.a (W.IApp (fromString "z")) alt
            honest = W.act t.a (W.IApp (fromString "w")) local
            zEvent = case Array.last alt2.log of
              Just l -> l.event
              Nothing -> signWith [] (Receipt { version: "", digest: "", prefix: "", sequenceNumber: 0 })
          f <- liftEffect (newFake local.group local.head (W.kels local))
          let tr = fakeTransport f
          v0 <- sync tr local.group Nothing
          case v0 of
            Right view -> do
              liftEffect (setState f alt2.head (W.kels alt2))
              r <- sync tr local.group (Just view)
              calls <- liftEffect (fakeCalls f)
              liftEffect (setState f honest.head (W.kels honest))
              again <- sync tr local.group (Just view)
              pure
                [ Tuple "refused at the first event that does not extend"
                    (map (const unit) r === Left (HistoryRewritten { prefix: t.a, s: snOf zEvent }))
                , Tuple "only the suffix after the local tip was asked"
                    (Array.elem (Tuple t.a (Just (snIn t.a view))) calls.kelCalls === true)
                , Tuple "the local view refreshes against the honest history"
                    (map lastOf again === Right honest.head)
                ]
            Left e -> pure (failed ("sync: " <> show e))
      , effectful "a suffix that breaks the rule or misses events" do
          t <- liftEffect (randomSampleOne W.genTeam)
          other <- liftEffect (randomSampleOne genKeys)
          let w = t.world
          f <- liftEffect (newFake w.group w.head (W.kels w))
          let tr = fakeTransport f
          v0 <- sync tr w.group Nothing
          case v0, W.ident t.a w of
            Right view, Just idA -> do
              let
                Tuple good idA' = interact [ actionAnchor w.group w.head (appP (fromString "q")) ] idA
                bad = good { signatures = (signWith other.pairs good.event).signatures }
                Tuple later _ = interact [ actionAnchor w.group (digestOf good) (appP (fromString "r")) ] idA'
                withA es = map (\(Tuple p xs) -> if p == t.a then Tuple p es else Tuple p xs) (W.kels w)
              liftEffect (setState f (digestOf bad) (withA (Array.snoc idA.events bad)))
              forged <- sync tr w.group (Just view)
              liftEffect (setState f (digestOf later) (withA (Array.snoc idA.events later)))
              missing <- sync tr w.group (Just view)
              pure
                [ Tuple "a suffix event with a foreign signature"
                    (map (const unit) forged === Left (HistoryRewritten { prefix: t.a, s: snOf bad }))
                , Tuple "a suffix missing its first event"
                    (map (const unit) missing === Left (HistoryRewritten { prefix: t.a, s: snOf later }))
                ]
            _, _ -> pure (failed "setup")
      , effectful "a read that fails or cannot be decoded is a refusal, never a view" do
          t <- liftEffect (randomSampleOne W.genTeam)
          let w = t.world
          f <- liftEffect (newFake w.group w.head (W.kels w))
          let
            tr = fakeTransport f
            fresh label tr' expect = do
              r <- sync tr' w.group Nothing
              pure (Tuple label (shape r === expect))
          freshCases <- sequence
            [ fresh "index: no answer" (withIndex noAnswer tr) "Transport 0"
            , fresh "index: 500" (withIndex (pure { status: 500, body: "down" }) tr) "Transport 500"
            , fresh "index: not JSON" (withIndex (pure { status: 200, body: "not json" }) tr) "Transport 200"
            , fresh "KEL: no answer" (withKel t.a noAnswer tr) "Transport 0"
            , fresh "KEL: 503" (withKel t.a (pure { status: 503, body: "busy" }) tr) "Transport 503"
            , fresh "KEL: not JSON" (withKel t.a (pure { status: 200, body: "garbage" }) tr) ("KelInvalid " <> t.a <> " 0")
            , fresh "KEL: not signed events" (withKel t.a (pure { status: 200, body: "[{\"event\":1}]" }) tr)
                ("KelInvalid " <> t.a <> " 0")
            ]
          v0 <- sync tr w.group Nothing
          case v0 of
            Right view -> do
              let moved = W.act t.a (W.IApp (fromString "moved")) w
              liftEffect (setState f moved.head (W.kels moved))
              let
                refresh label tr' expect = do
                  r <- sync tr' w.group (Just view)
                  pure (Tuple label (shape r === expect))
              refreshCases <- sequence
                [ refresh "suffix: no answer" (withKel t.a noAnswer tr) "Transport 0"
                , refresh "suffix: 500" (withKel t.a (pure { status: 500, body: "down" }) tr) "Transport 500"
                , refresh "suffix: not JSON" (withKel t.a (pure { status: 200, body: "garbage" }) tr)
                    ("HistoryRewritten " <> t.a <> " " <> show (snIn t.a view + 1))
                ]
              pure (freshCases <> refreshCases)
            Left e -> pure (failed ("sync: " <> show e))
      , effectful "the index is not evidence: [] is absent, KELs are keyed by their own prefix, a dropped prefix keeps its KEL" do
          t <- liftEffect (randomSampleOne W.genTeam)
          let
            w = t.world
            addB = case Array.index w.log 1 of
              Just l -> l.digest
              Nothing -> ""
          f <- liftEffect (newFake w.group w.head (W.kels w))
          let tr = fakeTransport f
          emptyB <- sync (withKel t.b (pure { status: 200, body: "[]" }) tr) w.group Nothing
          emptyA <- sync (withKel t.a (pure { status: 200, body: "[]" }) tr) w.group Nothing
          swapped <- sync (withKel t.b (tr.getKel t.c Nothing) tr) w.group Nothing
          v0 <- sync tr w.group Nothing
          case v0 of
            Right view -> do
              let moved = W.act t.a (W.IApp (fromString "moved")) w
              liftEffect (setState f moved.head (W.kels moved))
              dropped <- sync (omitPrefix t.b tr) w.group (Just view)
              honest <- sync tr w.group (Just view)
              pure
                [ Tuple "[] for an added identity: not hosted"
                    (map (const unit) emptyB === Left (RuleViolation { digest: addB, class: "memberNotHosted" }))
                , Tuple "[] for the signer of the head: a gap"
                    (map (const unit) emptyA === Left (Gap { missing: w.head }))
                , Tuple "another identity's KEL answered for b: refused at b"
                    (map (const unit) swapped === Left (KelInvalid { prefix: t.b, s: 0, reason: "prefixMismatch" }))
                , Tuple "a prefix dropped from the new index keeps its local KEL"
                    (Tuple (map (hasMember t.b) dropped) (dropped == honest) === Tuple (Right true) true)
                ]
            Left e -> pure (failed ("sync: " <> show e))
      , effectful "a KEL that is not the one asked for never stands in for another, in either index order" do
          t <- liftEffect (randomSampleOne W.genTeam)
          let
            w = t.world
            real = W.act t.a (W.IApp (fromString "real")) w
            forged = W.act t.a (W.IApp (fromString "forged")) w
            forgedA = case W.ident t.a forged of
              Just id -> kelBody id.events
              Nothing -> "[]"
            mismatch p = Left (KelInvalid { prefix: p, s: 0, reason: "prefixMismatch" })
          f <- liftEffect (newFake w.group w.head (W.kelsWithout [ t.c ] w))
          let tr = fakeTransport f
          v0 <- sync tr w.group Nothing
          liftEffect (setState f real.head (W.kels real))
          let forging p = withKel p (pure { status: 200, body: forgedA }) tr
          freshOne <- sync (forging t.b) w.group Nothing
          freshTwo <- sync (reverseIndex (forging t.b)) w.group Nothing
          let added = W.act t.a (W.IAdd t.c) w
          liftEffect (setState f added.head (W.kels added))
          refreshed <- case v0 of
            Right view -> do
              one <- sync (forging t.c) w.group (Just view)
              two <- sync (reverseIndex (forging t.c)) w.group (Just view)
              pure (Tuple (map (const unit) one) (map (const unit) two))
            Left e -> pure (Tuple (Left e) (Left e))
          twice <- sync (withIndex (pure { status: 200, body: indexBody w.head [ t.a, t.b, t.b ] (W.kels w) }) tr) w.group Nothing
          pure
            [ Tuple "fresh: a forked KEL of a answered for b, index order"
                (map (const unit) freshOne === mismatch t.b)
            , Tuple "fresh: the same, reversed index order"
                (map (const unit) freshTwo === mismatch t.b)
            , Tuple "refresh: a forked KEL of a held prefix answered for a new prefix, both orders"
                (refreshed === Tuple (mismatch t.c) (mismatch t.c))
            , Tuple "an index naming a prefix twice" (shape twice === "Transport 200")
            ]
      ]
  ]

-- | A KEL answer: the wire form of these events.
kelBody :: Array SignedEvent -> String
kelBody es = stringify (fromArray (map encodeSignedEvent es))

-- | An index answer naming these prefixes (tips from the KELs).
indexBody :: String -> Array String -> Array (Tuple String (Array SignedEvent)) -> String
indexBody head ps ks = stringify $ fromObject $ Object.fromFoldable
  [ Tuple "head" (fromString head)
  , Tuple "kels" $ fromArray $ map
      ( \p -> fromObject $ Object.fromFoldable
          [ Tuple "prefix" (fromString p)
          , Tuple "tip" (fromString (tipIn p))
          ]
      )
      ps
  ]
  where
  tipIn p = case Array.find (\(Tuple q _) -> q == p) ks >>= \(Tuple _ es) -> Array.last es of
    Just se -> eventDigest se.event
    Nothing -> ""
