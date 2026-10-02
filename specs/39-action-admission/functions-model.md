# Functions — 39 (new/changed signatures only)

- F1 `decodeAction :: SignedEvent -> Either GroupRefusal Action` — D1/D2; group id = `d` at genesis.
- F2 `admit :: Hosted -> SignedEvent -> Either GroupRefusal (Hosted, Admission)` — Lean `admit`
  (R3): `Hosted` = KELs by prefix + chains by group id; `Admission` = D3 200 body.
- F3 `retried :: Hosted -> SignedEvent -> Maybe Admission` — R5: identical event and signatures already in the signer's KEL.
- F4 `head :: Chain -> Text`; `roster :: Chain -> Roster`; `applyCore :: Roster -> Action -> Roster`.
- F5 `rebuildChains :: Map Text MemberKel -> Either String (Map Text Chain)` — R6.
- F6 `admitAction :: MemberKels -> SignedEvent -> IO (Either GroupRefusal Admission)` — retry, else
  F2, INSERT, publish; serialized with `submitMemberEvent`.
- F7 `lookupChain :: MemberKels -> Text -> IO (Maybe Chain)`.
- F8 changed: `openMemberKels :: Connection -> IO MemberKels` also rebuilds chains (F5), failing on violation.

Names are binding where they are Lean words (`admit`, `head`, `roster`, `applyCore`, `Action`,
`Payload`, `Roster`). Others may be renamed by the commit owner if recorded in the review
record; argument/result types may be refined (newtypes, a `Hosted` record shape) without
changing meaning.
