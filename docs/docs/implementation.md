# kelgroups — Implementation Plan

## Nix Setup

- **haskell.nix** with GHC 9.8.4
- `keri-hs` as flake input (crypto, CESR, KEL primitives)
- Dev shell includes: cabal, fourmolu, hlint, hoogle, cabal-fmt, just, lean4, mkdocs

## Cabal Package

**`kelgroups.cabal`** — library + test suite:

- Library depends on `base`, `containers`, `text`
- Test suite uses `hspec` + `QuickCheck`
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

## QuickCheck Properties

Each Lean theorem has a corresponding QuickCheck property in `test/InvariantsSpec.hs` (11 tests).

## CI

- **Build**: `nix develop -c just ci` (format, lint, build, lean)
- **Test**: `nix develop -c just test`
- **Docs**: MkDocs deployed to GitHub Pages on push to main

## Justfile Recipes

| Recipe | Description |
|---|---|
| `build` | `cabal build all -O0` |
| `test` | `cabal test all -O0` |
| `format` | `fourmolu -i lib/**/*.hs` |
| `lint` | `hlint lib/` |
| `cabal-fmt` | `cabal-fmt -i kelgroups.cabal` |
| `lean` | `cd lean && lake build` |
| `ci` | format + cabal-fmt + lint + build + lean |
| `docs` | `mkdocs build` |
| `clean` | cabal clean + lake clean |
