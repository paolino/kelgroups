# kelgroups — Implementation Plan

## Nix Setup

- **haskell.nix** with GHC 9.8.4
- `keri-hs` as flake input (crypto, CESR, KEL primitives)
- Dev shell includes: cabal, fourmolu, hlint, hoogle, cabal-fmt, just, lean4, mkdocs

## Cabal Package

**`kelgroups.cabal`** — library + test suite:

- Library depends on `base`, `containers`, `text`, `bytestring`, `serialise`, `sqlite-simple`, `stm`
- Test suite uses `hspec` + `QuickCheck` + `temporary` + `directory`
- `keri-hs` dependency wired in nix, activated when needed

## Library Modules

| Module | Role |
|---|---|
| `KelGroups.Types` | Core types: `Role`, `Member`, `RoleDef`, `GroupConfig` |
| `KelGroups.Event` | `GroupEvent a`, `BaseEvent`, `Proposal` |
| `KelGroups.State` | `GroupState a`, `adminCount`, `majority`, `isAdmin` |
| `KelGroups.Fold` | KEL fold: `foldGroup`, `applyEvent`, `AppFold` |
| `KelGroups.Validate` | Event validation with `ValidationError` ADT |
| `KelGroups.Bootstrap` | `AuthMode` detection (bootstrap vs normal) |
| `KelGroups.Trivial` | Trivial instance: `a = ()`, no app roles |
| `KelGroups.Store` | SQLite-backed KEL store with incremental TVar state |
| `KelGroups.Store.Serialise` | Orphan CBOR `Serialise` instances for all event/state types |

### Type Sketch

```haskell
data Role = Admin | AppRole RoleName

data Member = Member
  { memberKey :: Text
  , memberRoles :: Set Role
  }

data RoleDef a = RoleDef
  { canAdd :: a -> Bool
  , canRemove :: a -> Bool
  }

newtype GroupConfig a = GroupConfig
  { roleDefs :: Map RoleName (RoleDef a)
  }
```

### Events

```haskell
data GroupEvent a = Base BaseEvent | App a

data BaseEvent
  = Propose Proposal
  | Approve ProposalId

data Proposal
  = IntroduceMember Text (Set Role)
  | RemoveMember Text
  | ChangeRoles Text (Set Role)
```

### State

```haskell
data GroupState a = GroupState
  { members :: Map Text Member
  , pendingProposals :: Map ProposalId PendingProposal
  , appFold :: a
  }

data AuthMode = Bootstrap | Normal

authMode :: GroupState a -> AuthMode
authMode gs
  | adminCount gs == 0 = Bootstrap
  | otherwise = Normal
```

### Fold

```haskell
foldGroup
  :: AppFold a -> a -> [(Text, GroupEvent a)] -> GroupState a

type AppFold a = a -> a -> a
```

### Validation

```haskell
validateEvent
  :: GroupConfig a -> GroupState a -> Text -> GroupEvent a
  -> Either ValidationError ()
```

### Store

```haskell
data KELStore a = KELStore
  { storeConn :: Connection
  , stateVar :: TVar (GroupState a)
  }

openKEL :: Serialise a => AppFold a -> a -> FilePath -> IO (KELStore a)
appendEvent :: Serialise a => KELStore a -> AppFold a -> (Text, GroupEvent a) -> IO ()
readState :: KELStore a -> IO (GroupState a)
readEventsFrom :: Serialise a => KELStore a -> Int -> IO [(Text, GroupEvent a)]
kelLength :: KELStore a -> IO Int
```

Events are CBOR-encoded (`serialise`) and stored as blobs in a SQLite table. The in-memory `TVar` state is updated incrementally on each append and rebuilt from the DB on `openKEL`.

## Lean 4 Proofs

Invariants proven in `lean/KelGroups/Invariants.lean`:

| Theorem | Statement |
|---|---|
| `bootstrap_iff_zero_admins` | `authMode gs = bootstrap ↔ adminCount gs = 0` |
| `normal_iff_positive_admins` | `authMode gs = normal ↔ adminCount gs ≠ 0` |
| `empty_is_bootstrap` | `authMode emptyState = bootstrap` |
| `majority_zero` .. `majority_three` | Concrete majority values |
| `majority_le` | `majority n ≤ n` |
| `majority_pos` | `n > 0 → majority n > 0` |
| `remove_all_triggers_bootstrap` | Empty members → bootstrap |
| `admin_member_means_normal` | Admin in members → normal mode |

Transition invariants proven in `lean/KelGroups/TransitionInvariants.lean`:

| Theorem | Statement |
|---|---|
| `enact_introduce_admin_exits_bootstrap` | Introducing admin → adminCount > 0 |
| `enact_introduce_admin_count` | Fresh admin key → adminCount increments by 1 |
| `enact_introduce_nonadmin_count` | Non-admin introduce → adminCount unchanged |
| `enact_preserves_pendingProposals` | enact only touches members |
| `enact_remove_preserves_normal` | adminCount ≥ 2 and remove → adminCount ≥ 1 |

## QuickCheck Properties

Three tiers of properties mirror the Lean theorems:

| Test module | Scope | Count |
|---|---|---|
| `InvariantsSpec` | Pure state invariants | 11 |
| `TransitionInvariantsSpec` | Pure transition invariants | 8 |
| `StoreSpec` | Store mechanics (roundtrip, fold consistency, readEventsFrom, kelLength) | 6 |
| `StoreInvariantsSpec` | Lean invariants through CBOR + SQLite roundtrip | 13 |

**Total: 38 tests.**

### Store-through DSL

`StoreTestDSL` provides combinators that mirror Lean quantifier patterns:

```haskell
-- Lean: theorem foo (gs : GroupState) : P gs
onReachable :: (GroupState () -> Bool) -> Property

-- Lean: theorem foo (gs : GroupState) (h : Pre gs) : P gs
onReachableWhere :: (GroupState () -> Bool) -> (GroupState () -> Bool) -> Property

-- Lean: theorem foo (gs) (mid) (roles) : P (f gs mid roles)
onReachableWith :: Gen [SignedEvent] -> (GroupState () -> Gen Bool) -> Property
```

The `arbitraryHistory` generator produces valid event histories by tracking state: bootstrap first, then random proposals from live admins. States are reached through the full store pipeline (CBOR encode → SQLite write → reopen → decode → fold).

## CI

- **Build + Test**: `nix develop -c just ci` (format, cabal-fmt, lint, build, test, lean)
- **Docs**: MkDocs deployed to GitHub Pages on push to main

## Justfile Recipes

| Recipe | Description |
|---|---|
| `build` | `cabal build all -O0` |
| `test` | `cabal test all -O0 --test-show-details=direct` |
| `format` | `fourmolu -i lib/**/*.hs test/*.hs` |
| `lint` | `hlint lib/` |
| `cabal-fmt` | `cabal-fmt -i kelgroups.cabal` |
| `lean` | `cd lean && lake build` |
| `ci` | format + cabal-fmt + lint + build + test + lean |
| `docs` | `mkdocs build` |
| `clean` | cabal clean + lake clean |
