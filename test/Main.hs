{- |
Module      : Main
Description : Test suite entry point
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0
-}
module Main (main) where

import GroupIndexServerSpec qualified
import GroupMembershipServerSpec qualified
import GroupMembershipSpec qualified
import GroupMembershipStoreSpec qualified
import GroupServerSpec qualified
import GroupSpec qualified
import GroupStoreSpec qualified
import MemberKelServerSpec qualified
import MemberKelSpec qualified
import MemberKelStoreSpec qualified
import ServerIdentitySpec qualified
import Test.Hspec (hspec)
import VoteGroupViewSpec qualified
import VotePropertySpec qualified
import VoteWitnessSpec qualified

main :: IO ()
main = hspec $ do
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
    GroupIndexServerSpec.spec
    VoteGroupViewSpec.spec
    VoteWitnessSpec.spec
    VotePropertySpec.spec
