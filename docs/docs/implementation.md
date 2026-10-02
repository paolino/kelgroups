# kelgroups — Implementation

## Nix Setup

- **haskell.nix** with GHC 9.8.4
- [keri-hs](https://github.com/paolino/keri-hs) as flake input (KERI events, CESR encoding, Ed25519 crypto, KEL primitives)
- [keri-purs](https://github.com/paolino/keri-purs) as spago git dependency (PureScript KERI events, CESR, Ed25519, KEL replay)
- [keri-lean](https://github.com/paolino/keri-lean) as lake git dependency (generic KERI types for Lean proofs)
- Dev shell includes: cabal, fourmolu, hlint, hoogle, cabal-fmt, just, lean4, mkdocs, purescript, spago

## Cabal Package

**`kelgroups.cabal`** — library + test suite + executable:

- Library depends on `base`, `containers`, `text`, `bytestring`, `sqlite-simple`, `stm`, `aeson`, `http-types`, `wai`, `keri-hs`
- Executable depends on `kelgroups`, `warp`, `wai-app-static`
- Test suite uses `hspec` + `QuickCheck` + `temporary` + `directory` + `warp` + `wai` + `http-client` + `http-types` + `aeson` + `async` + `sqlite-simple` + `process` + `network` + `memory`; it runs the built `kelgroups-server` (`build-tool-depends`)

## Library Modules

| Module | Role |
|---|---|
| `KelGroups.Kel` | Member KELs and the KERI rule on append (`host`, `rotate`, `tip`) |
| `KelGroups.Kel.Codec` | JSON wire form of signed member KEL events |
| `KelGroups.Kel.Store` | The database file: member KELs, re-checked on open; group action admission |
| `KelGroups.Group` | Group actions, chains, membership and their admission (`admit`, `head`, `roster`, `membershipOk`) |
| `KelGroups.Server` | WAI application: `POST /kel`, `GET /kel/<prefix>[?after=<sn>]`, `POST /actions`, `GET /groups/<gid>` |
| `KelGroups.Vote.Types`, `KelGroups.Vote.State` | Held app-scoped proposal substrate; used by nothing in the server |

### Server

`kelApp` routes `POST /kel`, `GET /kel/<prefix>`, `POST /actions` and `GET /groups/<gid>`
(below). An unmatched GET or
HEAD goes to an optional fallback application; any other unmatched request answers 404. The
removed group path (`POST /events`, `GET /events`, `GET /condition`, `GET /stream`, `GET /info`,
the `?key=` guard) answers 404.

**Executable:** `kelgroups-server <port> <db>` — opens the member KEL store on the database
file and runs warp serving `kelApp`, with the static client files
(`client/kelgroups-trivial/dist`) as the fallback. Any other command line prints the usage and
exits.

### Member KELs

Each member's own KEL is hosted by the server. A member submits its inception and its
rotations; anyone can fetch the KEL. The server checks the KERI rule on every append, requires
a next-key commitment, and admits a rotation on KERI validity alone: no group condition is
consulted and no group state changes.

```haskell
host :: SignedEvent -> Either KelRefusal MemberKel
rotate :: MemberKel -> SignedEvent -> Either KelRefusal MemberKel
appendInteraction :: MemberKel -> SignedEvent -> Either KelRefusal MemberKel
tip :: MemberKel -> Text
currentKeys :: MemberKel -> ([Text], Int)

openMemberKels :: FilePath -> IO MemberKels
closeMemberKels :: MemberKels -> IO ()
submitMemberEvent :: MemberKels -> SignedEvent -> IO (Either KelRefusal MemberKel)
lookupMemberKel :: MemberKels -> Text -> IO (Maybe MemberKel)
```

The rule (`KelGroups.Kel`, pure, over keri-hs events) accepts an event only if:

- its `d` is its SAID; an inception's `i` equals its `d` and its `s` is 0;
- a rotation or interaction extends the tip: `i` is the KEL prefix, `p` the digest of the last
  event, `s` the last `s` + 1;
- inception and rotation commit to next keys (`n` non-empty, 1 <= `nt` <= |`n`|) and have
  1 <= `kt` <= |`k`|; a rotation's `k` is exactly the previous establishment event's
  commitment, key by key;
- its indexed signatures, over the keri-hs canonical serialization, are valid, at distinct
  indices, and meet the threshold of the controlling keys: an inception and a rotation its own
  `k`/`kt` (a rotation also the prior `nt` over the same revealed keys), an interaction the
  current keys;
- it has no witnesses.

`Keri.Kel.Append` is not used: it checks a rotation against the prior keys and does not require
a next-key commitment.

`KelGroups.Kel.Store` opens the database file itself and keeps one row per event in its
`member_kel_events` table (prefix, sequence number, canonical event bytes, signatures, digest;
unique on prefix and sequence number); it creates no other table and neither reads nor drops
any other table the file holds. A submission is decided under an append lock: a refusal writes
nothing; an acceptance is one INSERT, and memory is updated after it commits. Opening the
database replays every stored KEL through the rule and refuses to open on a violation.
Interactions are group actions, admitted only through `POST /actions` (below).

| Endpoint | Method | Description |
|---|---|---|
| `/kel` | POST | Submit an inception or a rotation; 200 `{"prefix", "sn", "digest"}` |
| `/kel/<prefix>` | GET | The hosted KEL, oldest first, each event with its signatures; 404 if unhosted |
| `/kel/<prefix>?after=<sn>` | GET | The hosted events with `s` > `sn`, oldest first (`[]` past the tip); 400 `badQuery` unless `sn` is a canonical non-negative decimal (checked before the lookup); 404 if unhosted |

Wire form of a signed event, the POST body and each element of the GET array:

```json
{"event": {"v": "...", "t": "icp", "d": "...", "i": "...", "s": "0", "kt": "1", "k": ["..."],
           "nt": "1", "n": ["..."], "bt": "0", "b": [], "c": [], "a": []},
 "signatures": [{"index": 0, "signature": "0B..."}]}
```

The event carries exactly the labels keri-hs serializes for its kind, `s` in hexadecimal and the
thresholds in decimal; the GET array returns each event in that canonical byte form.

| Refusal | Status | `error` |
|---|---|---|
| body or event not decodable | 400 | `notDecodable` |
| interaction or receipt at `POST /kel` | 422 | `unexpectedEventKind` |
| SAID mismatch, `i` != `d`, inception `s` not 0 | 422 | `saidMismatch`, `prefixNotSaid`, `inceptionNotFirst` |
| no next-key commitment, threshold out of range, witnesses | 422 | `missingNextCommitment`, `thresholdOutOfRange`, `witnessesPresent` |
| rotation not revealing the committed keys | 422 | `commitmentNotRevealed` |
| signatures invalid or under threshold | 422 | `invalidSignatures` |
| rotation for an unhosted prefix | 404 | `unhosted` |
| inception of a hosted prefix; `p`/`s` not the tip's successor | 409 | `alreadyHosted`, `notTipSuccessor` |

Refusal bodies are `{"error": <class>, "detail": <text>}`.

Other query keys of `GET /kel/<prefix>` are ignored. A client that already holds a validated KEL
up to `sn` fetches only `?after=<sn>` and checks that the answer extends its tip.
### Group actions

A group action is an interaction event (`ixn`) in the signer's hosted KEL whose `a` holds
exactly one group anchor. The signer is the event's `i`, its KEL link the event's `p`; the
anchor names the group, the payload and `prev`, the digest of the group head the action
extends. The group chain is nothing but those `prev` links; the server's per-group head is an
index derived from the admitted interactions, never stored apart.

```json
{"payload": {"t": "genesis"}}
{"group": "<group id>", "prev": "<head digest>", "payload": <payload>}
```

A genesis names no group and no `prev`: its group id is the genesis event's own `d`, and its
signer becomes the sole member and admin. The non-genesis payloads (add, remove, grant,
revoke, leave, app) are those of the membership section below; `app` data is opaque. Any other
shape — no anchor, two anchors, an extra key, an unknown payload tag, a genesis with
`group` or `prev`, a non-genesis without either — is not a group action.

```haskell
decodeAction :: SignedEvent -> Either GroupRefusal Action
admit :: Hosted -> SignedEvent -> Either GroupRefusal (Hosted, Admission)
retried :: Hosted -> SignedEvent -> Maybe Admission
head :: Chain -> Text
roster :: Chain -> Roster
applyCore :: Roster -> Action -> Roster
membershipOk :: (Text -> Bool) -> Roster -> Action -> Either GroupRefusal ()
rebuildChains :: Map Text MemberKel -> Either String (Map Text Chain)

admitAction :: MemberKels -> SignedEvent -> IO (Either GroupRefusal Admission)
lookupChain :: MemberKels -> Text -> IO (Maybe Chain)
```

`KelGroups.Group` is pure and uses the Lean model's words (`Action`, `Payload`, `head`,
`roster`, `applyCore`, `guardOk`, `membershipOk`, `admit`; `Hosted` is the model's `State`). `admit` applies the KEL rule
for an interaction to the signer's hosted KEL, then the group conditions: a genesis needs an
unused group id; any other action needs an existing group, a signer who is a current member,
`prev` equal to the head, and the membership rule (below). An admitted action is appended to
the signer's KEL and to its group's chain in one step.

`KelGroups.Kel.Store` admits under the same lock as `POST /kel`, so a rotation and an action
of one member never interleave. The KELs and chains are one in-memory value: an admission is
one INSERT of the interaction row, then that value is replaced, both under
`uninterruptibleMask_`, so a write failure or an asynchronous exception leaves the KEL tip and
the group head both advanced or both unchanged. A submission whose event and signatures are
already in the signer's KEL is a retry: it answers the original success body and stores
nothing. Opening the database rebuilds every chain from the hosted KELs and refuses to open if
an interaction is not a group action, or a group is not one `prev`-linked line from its genesis
whose every action meets the group conditions, membership rule included, at its position.

| Endpoint | Method | Description |
|---|---|---|
| `/actions` | POST | Admit a signed group action (wire form of `POST /kel`); 200 `{"group", "head", "prefix", "sn"}`, the same body for an identical retry |

Checks run in this order and the first failure decides the answer: decode, retry, signer
hosted, the KEL rule (SAID, `i`/`p`/`s` against the tip, signatures), then the group
conditions, then the membership rule. A refusal stores nothing.

| Refusal | Status | `error` |
|---|---|---|
| body or event not decodable | 400 | `notDecodable` |
| not exactly one well-formed group anchor | 400 | `notAGroupAction` |
| not an interaction | 422 | `unexpectedEventKind` |
| SAID mismatch; signatures invalid or under threshold | 422 | `saidMismatch`, `invalidSignatures` |
| signer not hosted; group id with no chain | 404 | `unhosted`, `noSuchGroup` |
| signer not a current member | 403 | `notAMember` |
| `p`/`s` not the tip's successor; `prev` not the head; genesis of an existing id | 409 | `notTipSuccessor`, `prevNotHead`, `groupExists` |

A refused action is void: the member re-reads its tip and the head and signs again. A write
failure answers 500 and stores nothing.

### Membership

Membership is the replay of a group's chain in admission order (`roster`, `applyCore`, as in
the Lean model `KelGroups.Sovereign.Membership`):

| Payload | Effect on the roster |
|---|---|
| `{"t": "genesis"}` | the signer is the sole member and admin |
| `{"t": "add", "member": x}` | `x` is a member |
| `{"t": "remove", "member": x}` | `x` is neither member nor admin |
| `{"t": "grant", "member": x}` | `x` is an admin |
| `{"t": "revoke", "member": x}` | `x` is not an admin |
| `{"t": "leave"}` | the signer is neither member nor admin |
| `{"t": "app", "data": d}` | unchanged |

`x` is a member KEL prefix, a JSON string; a membership payload with a missing or extra key or
a non-string member is not a group action. Every non-genesis payload travels in the
non-genesis anchor (`group`, `prev`, `payload`).

```haskell
guardOk :: Roster -> Bool
membershipOk :: (Text -> Bool) -> Roster -> Action -> Either GroupRefusal ()
```

`membershipOk` (Lean `membershipOk`) is the last admission condition, checked against the
roster before the action, after the signer is found a current member and `prev` the head:

- add, remove, grant and revoke are signed by an admin;
- an added identity has a hosted KEL and is not a member;
- a removed or granted identity is a member, a granted one not yet an admin;
- a revoked identity is an admin;
- leave and app need nothing more;
- for every payload, the last-admin guard (Lean `guardOk`): after the action the roster has
  no members, or has an admin.

So the last admin cannot leave, revoke itself or remove itself while other members remain; as
the sole member it may leave (or remove itself), which empties the group, but never revoke
itself. A removed or departed member's earlier actions stay in the chain; its later actions are
refused as from a non-member, and it may be added again. Every admitted chain therefore has
no members or an admin, and every admin is a member (Lean `admin_guard`).

Opening the database applies the same conditions to every rebuilt action at its position, a
KEL counting as hosted when it is stored; a stored interaction that breaks them refuses the
open.

The checks after the group conditions of `POST /actions` run in this order, the first failure
deciding: signer an admin, added identity hosted, target state, last-admin guard.

| Refusal | Status | `error` |
|---|---|---|
| add, remove, grant or revoke by a member who is no admin | 403 | `notAnAdmin` |
| add of an identity whose KEL is not hosted | 404 | `memberNotHosted` |
| add of a member; remove or grant of a non-member | 409 | `alreadyMember`, `targetNotMember` |
| grant of an admin; revoke of a non-admin | 409 | `alreadyAdmin`, `targetNotAdmin` |
| the action would leave members and no admin | 409 | `lastAdmin` |

### Group index

`GET /groups/<gid>` tells a reader where a group's history lies: the head and, sorted by prefix
without duplicates, every identity that signed an action of the group or was the target of an
`add`, former members included, each with the tip of its KEL. It is derived in memory from the
chain and the KELs of one committed state (`groupIndex`, `lookupGroup`); nothing is stored for
it. It is not evidence: a reader fetches the KELs it names and re-checks everything.

```haskell
groupIndex :: Map Text MemberKel -> Chain -> GroupIndex
lookupGroup :: MemberKels -> Text -> IO (Maybe GroupIndex)
```

```json
{"head": "<digest>", "kels": [{"prefix": "<prefix>", "tip": "<digest>"}]}
```

| Refusal | Status | `error` |
|---|---|---|
| no group has this id | 404 | `noSuchGroup` |

The read endpoints (`GET /kel/<prefix>`, `?after=`, `GET /groups/<gid>`) are open to anyone;
reads for current members only are not implemented yet.

## Lean 4 Model

Digests, SAIDs and signatures (`KERI.Crypto`) are imported from
[keri-lean](https://github.com/paolino/keri-lean). The model of the server is
`lean/KelGroups/Sovereign`: member KEL events and group actions (`Types`), roster replay and the
membership rule (`Membership`), the server state, hosting, rotation and admission (`Admission`),
and the theorems over every reachable state (`Theorems`, `Invariants`). `KelGroups.Group` uses
its words; among the theorems the implementation is checked against:

| Theorem | Statement |
|---|---|
| `admit_iff` | an action is admitted exactly when its signature is valid, `p` is the signer's tip, `prev` the head, its signer a member (or it is a genesis) and `membershipOk` holds; the state is then the action appended |
| `chain_is_line` | a reachable group chain is one line of `prev` links from its genesis |
| `admitted_admin_signer` | an admitted add, remove, grant or revoke is signed by an admin |
| `removed_not_member` | after an admitted remove the target is neither member nor admin |
| `leave_only_signer` | an admitted leave removes its signer and changes nobody else |
| `nonmember_refused` | an action of a non-member in an existing group is refused |
| `member_gained_only_by_add` | membership is gained only by an add (or the genesis) |
| `inv_reachable` | every reachable state satisfies `Inv`: KELs and chains are lines, every action is in its signer's KEL, a group with members has an admin, every admin is a member |

## Tests

The `invariants` suite (Hspec + QuickCheck) names every check by its invariant ID and layer
(`/rule` pure, `/store` SQLite file, `/http` warp and http-client, `/cli` the executable).
Events are built by legitimate signing with real Ed25519 keys and next-key commitments.

| Test module | Scope |
|---|---|
| `MemberKelSpec`, `MemberKelStoreSpec`, `MemberKelServerSpec` | The KERI rule, the store and `POST /kel`, `GET /kel`; the executable |
| `GroupSpec`, `GroupStoreSpec`, `GroupServerSpec` | Group action admission: rule, store (concurrency, retry, atomicity, reopen), `POST /actions` |
| `GroupMembershipSpec`, `GroupMembershipStoreSpec`, `GroupMembershipServerSpec` | Membership and admin rules: generated sequences against an oracle of the rules, store, `POST /actions` |
| `ServerIdentitySpec` | The server holds no key |
| `GroupIndexServerSpec` | `GET /groups/<gid>` and `GET /kel/<prefix>?after=<sn>` over generated membership runs |

## CI

- **Build + Test**: `nix develop -c just ci` (format, cabal-fmt, lint, build, test, lean, client)
- **Docs**: MkDocs deployed to GitHub Pages on push to main

## Justfile Recipes

| Recipe | Description |
|---|---|
| `build` | `cabal build all -O0` |
| `test` | `cabal test all -O0 --test-show-details=direct` |
| `format` | `fourmolu -i lib/**/*.hs test/*.hs app/*.hs` |
| `lint` | `hlint lib/` |
| `cabal-fmt` | `cabal-fmt -i kelgroups.cabal` |
| `lean` | `cd lean && lake build` |
| `build-client` | `cd client && npm install && spago build` |
| `bundle-client` | build + bundle PureScript client |
| `test-client` | `cd client && spago -x test.dhall test` |
| `ci` | format + cabal-fmt + lint + build + test + lean + client |
| `docs` | `mkdocs build` |
| `serve` | `cabal run kelgroups-server -O0 -- <port> <db>` |
| `clean` | cabal clean + lake clean |
