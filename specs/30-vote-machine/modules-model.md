# Modules — 30 vote machine

Dependency direction: `KelGroups.Group` ← `KelGroups.GroupView` ← `KelGroups.Vote.*`.
Nothing in `KelGroups.Group`, `KelGroups.Server`, `KelGroups.Kel*` or `app/` imports a Vote
module or `KelGroups.GroupView`.

| id | module | responsibility | Lean source |
|---|---|---|---|
| module-group-view | `KelGroups.GroupView` (new) | read-only projection of a `Roster`; membership and admin queries | `Types.lean` `GroupView` |
| module-vote-types | `KelGroups.Vote.Types` (exists) | vocabulary; unchanged except where data-model says | `Vote/Types.lean` |
| module-vote-state | `KelGroups.Vote.State` (exists) | payload, franchise, the single verdict site, closure cause | `Vote/State.lean` |
| module-vote-event | `KelGroups.Vote.Event` (new) | event sum | `Vote/Event.lean` |
| module-vote-validate | `KelGroups.Vote.Validate` (new) | refusals and the one validation entry | `Vote/Validate.lean` |
| module-vote-fold | `KelGroups.Vote.Fold` (new) | ballot placement, sweep, effects, departure, checked step, folds | `Vote/Fold.lean` |

All new modules are listed in `exposed-modules`. The library exports no threshold value.
