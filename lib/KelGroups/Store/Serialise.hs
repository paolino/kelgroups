{-# OPTIONS_GHC -Wno-orphans #-}

{- |
Module      : KelGroups.Store.Serialise
Description : CBOR serialisation instances for KEL types
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

Orphan 'Serialise' instances for all event and state
types. Kept separate to avoid a @serialise@ dependency
in the core modules.
-}
module KelGroups.Store.Serialise () where

import Codec.Serialise (Serialise (..))
import Codec.Serialise.Decoding
    ( decodeListLen
    , decodeWord
    )
import Codec.Serialise.Encoding
    ( encodeListLen
    , encodeWord
    )
import Data.Set qualified as Set
import KelGroups.Event
    ( BaseEvent (..)
    , GroupEvent (..)
    , Proposal (..)
    )
import KelGroups.State (PendingProposal (..))
import KelGroups.Types (Member (..), Role (..))

-- --------------------------------------------------------
-- Role
-- --------------------------------------------------------

instance Serialise Role where
    encode Admin = encodeListLen 1 <> encodeWord 0
    encode (AppRole name) =
        encodeListLen 2 <> encodeWord 1 <> encode name
    decode = do
        len <- decodeListLen
        tag <- decodeWord
        case (len, tag) of
            (1, 0) -> pure Admin
            (2, 1) -> AppRole <$> decode
            _ -> fail "invalid Role encoding"

-- --------------------------------------------------------
-- Proposal
-- --------------------------------------------------------

instance Serialise Proposal where
    encode (IntroduceMember key roles) =
        encodeListLen 3
            <> encodeWord 0
            <> encode key
            <> encode (Set.toList roles)
    encode (RemoveMember key) =
        encodeListLen 2
            <> encodeWord 1
            <> encode key
    encode (ChangeRoles key roles) =
        encodeListLen 3
            <> encodeWord 2
            <> encode key
            <> encode (Set.toList roles)
    decode = do
        len <- decodeListLen
        tag <- decodeWord
        case (len, tag) of
            (3, 0) ->
                IntroduceMember
                    <$> decode
                    <*> (Set.fromList <$> decode)
            (2, 1) -> RemoveMember <$> decode
            (3, 2) ->
                ChangeRoles
                    <$> decode
                    <*> (Set.fromList <$> decode)
            _ -> fail "invalid Proposal encoding"

-- --------------------------------------------------------
-- BaseEvent
-- --------------------------------------------------------

instance Serialise BaseEvent where
    encode (Propose p) =
        encodeListLen 2
            <> encodeWord 0
            <> encode p
    encode (Approve pid) =
        encodeListLen 2
            <> encodeWord 1
            <> encode pid
    decode = do
        len <- decodeListLen
        tag <- decodeWord
        case (len, tag) of
            (2, 0) -> Propose <$> decode
            (2, 1) -> Approve <$> decode
            _ -> fail "invalid BaseEvent encoding"

-- --------------------------------------------------------
-- GroupEvent a
-- --------------------------------------------------------

instance (Serialise a) => Serialise (GroupEvent a) where
    encode (Base be) =
        encodeListLen 2
            <> encodeWord 0
            <> encode be
    encode (App a) =
        encodeListLen 2
            <> encodeWord 1
            <> encode a
    decode = do
        len <- decodeListLen
        tag <- decodeWord
        case (len, tag) of
            (2, 0) -> Base <$> decode
            (2, 1) -> App <$> decode
            _ -> fail "invalid GroupEvent encoding"

-- --------------------------------------------------------
-- Member
-- --------------------------------------------------------

instance Serialise Member where
    encode m =
        encodeListLen 2
            <> encode (memberKey m)
            <> encode (Set.toList (memberRoles m))
    decode = do
        _ <- decodeListLen
        Member
            <$> decode
            <*> (Set.fromList <$> decode)

-- --------------------------------------------------------
-- PendingProposal
-- --------------------------------------------------------

instance Serialise PendingProposal where
    encode pp =
        encodeListLen 3
            <> encode (proposal pp)
            <> encode (proposer pp)
            <> encode (Set.toList (approvals pp))
    decode = do
        _ <- decodeListLen
        PendingProposal
            <$> decode
            <*> decode
            <*> (Set.fromList <$> decode)
