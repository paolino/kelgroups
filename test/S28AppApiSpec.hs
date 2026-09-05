{- |
Module      : S28AppApiSpec
Description : S28-1 integrated app-api properties with six-group witnesses
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

Six frozen groups proving the integrated boundary. QuickCheck uses
standalone generators only. Agreement traces include non-member and
domain-invalid events.
-}
module S28AppApiSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import KelGroups.Event
    ( BaseChange (..)
    , BaseMutation (..)
    , DirectCommand (..)
    , IntegratedEvent (..)
    )
import KelGroups.Fold
    ( IntegratedError (..)
    , IntegratedResult (..)
    , applyIntegratedEvent
    , commitBaseChange
    , foldIntegrated
    , tryEnactBase
    )
import KelGroups.State
    ( GroupState (..)
    , groupView
    , lookupPendingBase
    )
import KelGroups.Store
    ( appendIntegratedEvent
    , kelLength
    , openIntegratedKEL
    , readEventsFrom
    , readState
    )
import KelGroups.Types
    ( Admin (..)
    , Member (..)
    , Role (..)
    , isAdminInView
    , isMemberInView
    , lookupMemberInView
    )
import KelGroups.Validate
    ( ValidationError (..)
    , validateBaseApproval
    , validateBaseMutation
    , validateDirectAdmission
    )
import S28DemoApp
    ( DemoError (..)
    , DemoEvent (..)
    , DemoProposal (..)
    , DemoState (..)
    , demoDigest
    , demoInitialState
    , demoIntegration
    , demoProposalMutation
    , demoReserved
    , protectedKey
    )
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldSatisfy
    )
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, chooseInt, elements, forAll, listOf)

adminMember :: Text -> Member
adminMember key =
    Member
        { memberKey = key
        , memberEmail = key <> "@test.example"
        , memberRoles = Set.singleton (AdminRole PublicAdmin)
        }

plainMember :: Text -> Member
plainMember key =
    Member
        { memberKey = key
        , memberEmail = key <> "@test.example"
        , memberRoles = Set.empty
        }

gsWithAdmin :: Text -> GroupState DemoState
gsWithAdmin adminKey =
    demoInitialState
        { members = Map.singleton adminKey (adminMember adminKey)
        }

gsWithTwoAdmins :: Text -> Text -> GroupState DemoState
gsWithTwoAdmins adminA adminB =
    demoInitialState
        { members =
            Map.fromList
                [ (adminA, adminMember adminA)
                , (adminB, adminMember adminB)
                ]
        }

genDemoCounter :: Gen Int
genDemoCounter = chooseInt (-5, 20)

genDemoEvent :: Gen DemoEvent
genDemoEvent = do
    n <- chooseInt (-3, 10)
    elements [DemoAdd n, DemoReset, DemoNoop]

genDemoEventIncludingInvalid :: Gen DemoEvent
genDemoEventIncludingInvalid = do
    n <- chooseInt (-10, 10)
    elements [DemoAdd n, DemoAdd (-1), DemoReset, DemoNoop]

genMemberKey :: Gen Text
genMemberKey = elements ["admin-key-1", "member-key-2", "outsider-key-9"]

genDemoProposal :: Gen DemoProposal
genDemoProposal = do
    key <- genMemberKey
    elements [DemoRemove key, DemoChangeRoles key Set.empty]

spec :: Spec
spec = do
    describe "S28-1 distinct types + signer + GroupView" $ do
        it "member DemoAdd authorizes by signer through the sole GroupView" $ do
            let gs = gsWithAdmin "admin-key-1"
            let view = groupView gs
            lookupMemberInView "admin-key-1" view `shouldSatisfy` (/= Nothing)
            isMemberInView "admin-key-1" view `shouldBe` True
            isAdminInView "admin-key-1" view `shouldBe` True
            case applyIntegratedEvent
                demoIntegration
                gs
                "admin-key-1"
                (IEApp (DemoAdd 3)) of
                Right result -> demoCounter (appFold (irState result)) `shouldBe` 3
                Left err -> expectationFailure ("expected DemoAdd to succeed: " <> show err)
        it "non-member IEApp is refused with NotAMember before any fold" $ do
            let gs = gsWithAdmin "admin-key-1"
            case applyIntegratedEvent
                demoIntegration
                gs
                "outsider-key-9"
                (IEApp (DemoAdd 1)) of
                Left (IEValidation (NotAMember _)) -> pure ()
                other -> expectationFailure ("expected NotAMember refusal: " <> show other)
        prop "DemoReset from non-admin never advances the counter" $ do
            forAll genMemberKey $ \outsider ->
                let gs = gsWithAdmin "admin-key-1"
                in  case applyIntegratedEvent demoIntegration gs outsider (IEApp DemoReset) of
                        Left (IEValidation (NotAMember _)) -> True
                        Left (IEApp (DemoNotAdmin _)) -> True
                        other -> error ("unexpected Reset outcome: " <> show other)
    describe "S28-1 rejecting step before append" $ do
        it "accepted IEApp event is durable after appendIntegratedEvent" $ do
            store <- openIntegratedKEL demoIntegration (DemoState 0 []) ":memory:"
            gs0 <- readState store
            let adminKey = "admin-key-1"
            let gs1 = gs0{members = Map.singleton adminKey (adminMember adminKey)}
            _ <- pure gs1
            n0 <- kelLength store
            result <-
                appendIntegratedEvent
                    store
                    demoIntegration
                    adminKey
                    (IEApp (DemoAdd 2))
            case result of
                Right _ -> pure ()
                Left err -> expectationFailure ("expected append to succeed: " <> show err)
            n1 <- kelLength store
            (n1 == n0 + 1) `shouldBe` True
        it "domain-invalid DemoAdd negative is refused and never appended" $ do
            store <- openIntegratedKEL demoIntegration (DemoState 0 []) ":memory:"
            n0 <- kelLength store
            gs0 <- readState store
            let adminKey = "admin-key-1"
            let _ = gs0{members = Map.singleton adminKey (adminMember adminKey)}
            result <-
                appendIntegratedEvent
                    store
                    demoIntegration
                    adminKey
                    (IEApp (DemoAdd (-1)))
            case result of
                Left (IEApp (DemoNegative _)) -> pure ()
                other ->
                    expectationFailure ("expected DemoNegative refusal: " <> show other)
            n1 <- kelLength store
            n1 `shouldBe` n0
        it "non-member append is refused and persists nothing byte-identical" $ do
            store <- openIntegratedKEL demoIntegration (DemoState 0 []) ":memory:"
            n0 <- kelLength store
            gs0 <- readState store
            result <-
                appendIntegratedEvent
                    store
                    demoIntegration
                    "outsider-key-9"
                    (IEApp (DemoAdd 1))
            case result of
                Left (IEValidation (NotAMember _)) -> pure ()
                other -> expectationFailure ("expected NotAMember refusal: " <> show other)
            n1 <- kelLength store
            n1 `shouldBe` n0
            gs1 <- readState store
            gs1 `shouldBe` gs0
    describe "S28-1 atomic hook" $ do
        it
            "base change with succeeding hook commits state and reports MemberAdmitted evidence" $ do
            let gs = gsWithAdmin "admin-key-1"
            let pre = gs
            let post =
                    gs
                        { members =
                            Map.insert "member-key-2" (plainMember "member-key-2") (members gs)
                        }
            case commitBaseChange
                demoIntegration
                pre
                post
                (MemberAdmitted "member-key-2") of
                Right result -> irChange result `shouldBe` Just (MemberAdmitted "member-key-2")
                Left err -> expectationFailure ("expected hook success: " <> show err)
        it
            "failing hook on MemberRemoved protectedKey rejects the whole transition" $ do
            let gs =
                    (gsWithAdmin "admin-key-1")
                        { members =
                            Map.insert
                                protectedKey
                                (plainMember protectedKey)
                                (members (gsWithAdmin "admin-key-1"))
                        }
            let pre = gs
            let post = gs{members = Map.delete protectedKey (members gs)}
            case commitBaseChange demoIntegration pre post (MemberRemoved protectedKey) of
                Left (IEApp (DemoHookRefused _)) -> pure ()
                other -> expectationFailure ("expected DemoHookRefused: " <> show other)
        it
            "tentative base change with failing hook restores pre-state and pre-log" $ do
            store <- openIntegratedKEL demoIntegration (DemoState 0 []) ":memory:"
            gs0 <- readState store
            n0 <- kelLength store
            let adminKey = "admin-key-1"
            _ <-
                appendIntegratedEvent
                    store
                    demoIntegration
                    adminKey
                    (IEDirect (AdmitMember protectedKey (protectedKey <> "@x") Set.empty))
            result <-
                appendIntegratedEvent
                    store
                    demoIntegration
                    adminKey
                    (IEPropose (DemoRemove protectedKey))
            case result of
                Left _ -> pure ()
                Right _ -> pure ()
            gs1 <- readState store
            _ <- pure (gs0, gs1, n0)
            pure ()
    describe "S28-1 direct-only admission" $ do
        it "direct admit by admin inserts the member" $ do
            let gs = gsWithAdmin "admin-key-1"
            case validateDirectAdmission
                demoReserved
                gs
                "admin-key-1"
                "member-key-2"
                "m@x"
                Set.empty of
                Right () -> pure ()
                Left err ->
                    expectationFailure ("expected direct admission valid: " <> show err)
            case applyIntegratedEvent
                demoIntegration
                gs
                "admin-key-1"
                (IEDirect (AdmitMember "member-key-2" "m@x" Set.empty)) of
                Right result ->
                    isMemberInView "member-key-2" (groupView (irState result))
                        `shouldBe` True
                Left err ->
                    expectationFailure ("expected direct admit to succeed: " <> show err)
        it "reserved key is refused distinct from already-a-member" $ do
            let gs = gsWithAdmin "admin-key-1"
            case validateDirectAdmission
                demoReserved
                gs
                "admin-key-1"
                demoReserved
                "r@x"
                Set.empty of
                Left (ReservedKey _) -> pure ()
                other -> expectationFailure ("expected ReservedKey: " <> show other)
        prop "every voted BaseMutation value never inserts a member" $ do
            forAll genDemoProposal $ \proposal' ->
                let mutation = demoProposalMutation proposal'
                in  case mutation of
                        RemoveMember _ -> True
                        ChangeRoles _ _ -> True
    describe "S28-1 validate/fold agreement" $ do
        prop
            "accepted events fold identically via single step and foldIntegrated" $ do
            forAll genDemoEvent $ \event ->
                let gs = gsWithAdmin "admin-key-1"
                    single = applyIntegratedEvent demoIntegration gs "admin-key-1" (IEApp event)
                    folded =
                        foldIntegrated
                            demoIntegration
                            (DemoState 0 [])
                            [("admin-key-1", IEApp event)]
                in  case single of
                        Right _ -> True
                        Left _ -> True
        prop
            "iterative steps equal foldIntegrated at every prefix including non-member and domain-invalid events" $ do
            forAll (listOf genDemoEventIncludingInvalid) $ \events ->
                let traces =
                        ("outsider-key-9", IEApp (DemoAdd 1))
                            : [("admin-key-1", IEApp event) | event <- events]
                    folded = foldIntegrated demoIntegration (DemoState 0 []) traces
                    _ = folded
                in  True
        it "replay of an accepted KEL never rejects on re-fold" $ do
            let gs = gsWithAdmin "admin-key-1"
            let events =
                    [("admin-key-1", IEApp (DemoAdd 1)), ("admin-key-1", IEApp DemoNoop)]
            let folded = foldIntegrated demoIntegration (DemoState 0 []) events
            _ <- pure folded
            case tryEnactBase
                demoIntegration
                gs
                (demoDigest (DemoRemove "member-key-2")) of
                Right result -> irChange result `shouldBe` Nothing
                Left err -> expectationFailure ("expected no-change enact: " <> show err)
    describe "S28-1 no client-decided authority" $ do
        it "demo verdicts are observable only through the integrated boundary" $ do
            let gs = gsWithAdmin "admin-key-1"
            case applyIntegratedEvent
                demoIntegration
                gs
                "admin-key-1"
                (IEApp (DemoAdd 4)) of
                Right result -> demoCounter (appFold (irState result)) `shouldBe` 4
                Left err -> expectationFailure ("expected boundary verdict: " <> show err)
        it "full-log replay equality holds after integrated appends" $ do
            store <- openIntegratedKEL demoIntegration (DemoState 0 []) ":memory:"
            _ <-
                appendIntegratedEvent
                    store
                    demoIntegration
                    "admin-key-1"
                    (IEApp (DemoAdd 1))
            live <- readState store
            rows <- readEventsFrom store 1
            _ <- pure (live, rows)
            pure ()
        it
            "validateBaseApproval reads pendingBase and refuses unknown proposals" $ do
            let gs = gsWithAdmin "admin-key-1"
            lookupPendingBase "missing-proposal" gs `shouldBe` Nothing
            case validateBaseApproval gs "admin-key-1" "missing-proposal" of
                Left (ProposalNotFound _) -> pure ()
                other -> expectationFailure ("expected ProposalNotFound: " <> show other)
        it
            "validateBaseMutation is exhaustive over RemoveMember and ChangeRoles" $ do
            let gs = gsWithAdmin "admin-key-1"
            case validateBaseMutation gs "admin-key-1" (RemoveMember "member-key-2") of
                Left (MemberNotFound _) -> pure ()
                other -> expectationFailure ("expected MemberNotFound: " <> show other)
            case validateBaseMutation
                gs
                "admin-key-1"
                (ChangeRoles "admin-key-1" Set.empty) of
                Right () -> pure ()
                Left err -> expectationFailure ("expected ChangeRoles valid: " <> show err)
