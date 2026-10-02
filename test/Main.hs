{- |
Module      : Main
Description : Test suite entry point
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0
-}
module Main (main) where

import E2ESpec qualified
import FoldSpec qualified
import GroupMembershipServerSpec qualified
import GroupMembershipSpec qualified
import GroupMembershipStoreSpec qualified
import GroupServerSpec qualified
import GroupSpec qualified
import GroupStoreSpec qualified
import InvariantsSpec qualified
import MemberKelServerSpec qualified
import MemberKelSpec qualified
import MemberKelStoreSpec qualified
import MultiClientSpec qualified
import S28AppApiSpec qualified
import ServerIdentitySpec qualified
import ServerSpec qualified
import StoreInvariantsSpec qualified
import StoreSpec qualified
import Test.Hspec (describe, hspec)
import TransitionInvariantsSpec qualified
import ValidateSpec qualified

main :: IO ()
main = hspec $ do
    InvariantsSpec.spec
    TransitionInvariantsSpec.spec
    FoldSpec.spec
    ValidateSpec.spec
    MemberKelSpec.spec
    MemberKelStoreSpec.spec
    MemberKelServerSpec.spec
    GroupSpec.spec
    GroupStoreSpec.spec
    GroupServerSpec.spec
    GroupMembershipSpec.spec
    GroupMembershipStoreSpec.spec
    GroupMembershipServerSpec.spec
    ServerIdentitySpec.spec
    describe "INV-38-OLD-PATH: the old group path without a server key" $ do
        StoreSpec.spec
        StoreInvariantsSpec.spec
        ServerSpec.spec
        E2ESpec.spec
        MultiClientSpec.spec
        S28AppApiSpec.spec
