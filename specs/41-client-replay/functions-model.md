# Functions — 41 (new or changed signatures only)

Server (Haskell):
- F1 `groupIndex :: Map Text MemberKel -> Chain -> GroupIndex` (pure; D2).
- F2 `kelAfter :: Int -> MemberKel -> [SignedEvent]` (pure; D3).

Client (PureScript):
- F3 `validateKel :: Array SignedEvent -> Either SyncRefusal ValidatedKel`
- F4 `extendKel :: ValidatedKel -> Array SignedEvent -> Either SyncRefusal ValidatedKel`
- F5 `replayGroup :: GroupId -> Digest -> Map Prefix ValidatedKel -> Either SyncRefusal GroupView`
  (walk from the given head + fold)
- F6 `signAction :: Signer -> GroupView -> Payload -> Either SyncRefusal SignedEvent`
  (`Signer` = prefix + Ed25519 secret key; `p` and `prev` from the view only)
- F7 `type Transport = { getIndex, getKel, postAction }` with `getKel :: Prefix -> Maybe Int -> Aff …`
- F8 `sync :: Transport -> GroupId -> Maybe GroupView -> Aff (Either SyncRefusal GroupView)`
  (`Just` = refresh by suffixes)
- F9 `submit :: Transport -> SignedEvent -> Aff Submission`
- F10 `act :: Transport -> Signer -> GroupView -> Payload -> Aff (Either SyncRefusal Submission)`
  (sign, submit, on 409 refresh and re-sign)
- F11 `httpTransport :: String -> Transport`
