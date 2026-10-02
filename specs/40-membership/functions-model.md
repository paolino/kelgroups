# Functions — 40 (new/changed signatures only)

- F1 changed `Payload`: adds `Add Text | Remove Text | Grant Text | Revoke Text | Leave`
  (D1); `GroupRefusal` adds `NotAnAdmin | MemberNotHosted | AlreadyMember | TargetNotMember |
  AlreadyAdmin | TargetNotAdmin | LastAdmin` (D4).
- F2 `applyCore :: Roster -> Action -> Roster` (changed: all payloads, R2);
  `guardOk :: Roster -> Bool` (new, Lean `guardOk`).
- F3 `membershipOk :: (Text -> Bool) -> Roster -> Action -> Either GroupRefusal ()` (new;
  arguments `hosted`, `r` the roster before the action, `a`): R3 in D4 order; called by
  `admit` for every non-genesis action after the #39 conditions.
- F4 `rebuildChains :: Map Text MemberKel -> Either String (Map Text Chain)` (meaning
  changed: R5).
- F5 `openMemberKels :: FilePath -> IO MemberKels` (changed: opens the database file itself);
  `closeMemberKels :: MemberKels -> IO ()` (new).
- Deleted: `mkApp`, `ServerEnv` and every old-path handler in `KelGroups.Server`.

Names are binding where they are Lean words (`applyCore`, `guardOk`, `membershipOk`,
`roster`, `Roster`, `Payload`). Others may be renamed if recorded in the review record;
types may be refined without changing meaning.
