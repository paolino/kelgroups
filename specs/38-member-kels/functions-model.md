# Functions — 38 (new/changed signatures only)

- F1 `host :: SignedEvent -> Either KelRefusal MemberKel` — inception for an unhosted prefix.
- F2 `rotate :: MemberKel -> SignedEvent -> Either KelRefusal MemberKel` — rotation on a hosted KEL.
- F3 `appendInteraction :: MemberKel -> SignedEvent -> Either KelRefusal MemberKel` — R3 for an interaction (caller: #39).
- F4 `tip :: MemberKel -> Text` — digest of the last event.
- F5 `currentKeys :: MemberKel -> ([Text], Int)` — controlling keys and threshold.
- F6 `encodeSignedEvent :: SignedEvent -> Value`; `decodeSignedEvent :: Value -> Either String SignedEvent`.
- F7 `openMemberKels :: Connection -> IO MemberKels` — create table if absent, load, R6 re-check (fail on violation).
- F8 `submitMemberEvent :: MemberKels -> SignedEvent -> IO (Either KelRefusal MemberKel)` — dispatch icp→F1 (refuse hosted), rot→F2 (refuse unhosted), else refuse; persist atomically.
- F9 `lookupMemberKel :: MemberKels -> Text -> IO (Maybe MemberKel)`.
- F10 changed: `openKEL :: GroupConfig a -> FilePath -> IO (KELStore a)` (or its current shape) no longer creates or loads a server identity; `openKELWithIdentity` deleted; `KELStore` loses `serverKeyPair`, `serverCesrKey`.

Names are binding where they are Lean words (`host`, `rotate`, `tip`); others may be renamed by
the commit owner if recorded in the review receipt. Argument/result types may be refined
(e.g. a newtype for prefix) without changing meaning.
