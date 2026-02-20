# kelgroups — Design Document

## 1. KEL Basics

A **Key Event Log (KEL)** is an append-only, hash-chained, signed event log. Each event carries:

- A **sequence number** (monotonically increasing)
- A **digest** of the prior event (hash chain)
- A **signature** from the event author

The KEL is a pure data structure. Folding it produces the **current condition** of the system — there is no mutable state outside the log. Validation of a new event always runs against the fold of the existing KEL.

## 2. Project Overview

`kelgroups` is a **polymorphic Haskell library** for managing groups via a KEL. The library is generic over application event types — the base system provides group infrastructure while applications supply domain-specific semantics.

### Packages

| Package | Language | Role |
|---|---|---|
| `kelgroups` | Haskell | Polymorphic base system library |
| `kelgroups-server` | Haskell | Server parameterized by application plugin |
| `kelgroups-ps` | PureScript | Client-side KEL handling and identity |
| `kelgroups-app` | PureScript | UI client, parameterized by plugins |

The first instance is **trivial**: no application semantics, just the base system operating alone.

## 3. Invariants

- **One server = one group.** No multi-tenancy.
- **One KEL per group.** The server's KEL is the single source of truth.
- **Server condition = KEL fold.** Pure event-sourced — no side state.
- **No KEL reconciliation.** Single authoritative KEL, no forking or merging.
- **Validate before append.** Every new event is validated against the current KEL fold before being accepted.

## 4. Two Layers of Semantics

The KEL carries two kinds of events:

- **Base events** — infrastructure-level operations needed for the system to function (member management, role changes, voting).
- **Application events** — domain-specific, opaque to the base system.

The KEL type is `KEL a` where `a` is the application event type. The base system never inspects `a` — it only folds base events to maintain group state.

```haskell
data Event a
    = BaseEvent BaseEvent
    | AppEvent a
```

## 5. Roles

Two categories of roles exist:

- **Admin** — a distinguished base-system role. Admins vote on member and role changes.
- **Application roles** — opaque labels from the base system's perspective.

All role changes (including granting/revoking admin) require **admin majority vote**.

Application roles are defined at server startup via **role definitions** that include two predicates:

```haskell
data RoleDef a = RoleDef
    { canAdd :: KEL a -> Bool
    , canRemove :: KEL a -> Bool
    }
```

These predicates gate role assignment and removal based on the current KEL state. The server is parameterized by a map of role definitions:

```haskell
type RoleDefs a = Map RoleName (RoleDef a)
```

## 6. Base Events

| Event | Description | Requirement |
|---|---|---|
| **Introduce member** | Add a public key with a set of roles (including admin flag) | Admin majority vote |
| **Remove member** | Remove a member entirely | Admin majority vote |
| **Change roles** | Modify a member's role set | Admin majority vote |

Each of these operations follows a **proposal + approval** pattern: one admin proposes, then a majority of admins must approve before the event is appended to the KEL.

```haskell
data BaseEvent
    = Propose Proposal
    | Approve ProposalDigest

data Proposal
    = IntroduceMember PublicKey (Set Role)
    | RemoveMember PublicKey
    | ChangeRoles PublicKey (Set Role)
```

## 7. Bootstrap Mode

```mermaid
stateDiagram-v2
    [*] --> Bootstrap : empty KEL
    Bootstrap --> Normal : first member introduced with admin role
    Normal --> Normal : events signed by known members
    Normal --> Bootstrap : zero admins remaining
    Bootstrap --> Normal : admin introduced via passphrase auth
```

- **Empty KEL** or **zero admins** triggers bootstrap mode.
- The server receives a **passphrase via CLI arguments** at startup.
- In bootstrap mode, clients authenticate via **passphrase challenge** instead of signatures.
- The first event **must** introduce a member with the admin role — otherwise it is rejected.
- After the first admin is introduced, the system transitions to **normal mode** (signature-based auth).
- If all admins are removed, bootstrap mode **reactivates** — the passphrase is the permanent fallback. The system is never dead.

```mermaid
flowchart TD
    A[Client connects] --> B{KEL has admins?}
    B -->|No: bootstrap mode| C[Passphrase challenge]
    B -->|Yes: normal mode| D[Signature verification]
    C --> E{Event = Introduce member with admin?}
    E -->|Yes| F[Append to KEL, transition to normal]
    E -->|No| G[Reject]
    D --> H{Valid signature from known member?}
    H -->|Yes| I[Validate event against KEL fold]
    H -->|No| J[Reject]
    I -->|Valid| K[Append to KEL]
    I -->|Invalid| L[Reject]
```

## 8. Authentication

| Mode | Mechanism | When |
|---|---|---|
| Bootstrap | Passphrase challenge | KEL has zero admins |
| Normal | Event signed by known member | KEL has at least one admin |

**Majority calculation** for admin votes: `ceil(numAdmins / 2)`. With a single admin, that admin decides alone.

## 9. Architecture

```mermaid
flowchart TB
    subgraph Haskell
        LIB["kelgroups (library)<br/>KEL a, Event a<br/>fold, validate<br/>base event logic<br/>role predicates"]

        SRV["kelgroups-server<br/>HTTP API<br/>bootstrap auth<br/>parameterized by<br/>RoleDefs a, app event type a"]
    end

    subgraph PureScript
        PSLIB["kelgroups-ps (library)<br/>KEL types<br/>identity / key mgmt<br/>server communication"]

        APP["kelgroups-app (client)<br/>UI<br/>parameterized by<br/>app plugins"]
    end

    SRV --> LIB
    APP --> PSLIB
    APP <-->|HTTP| SRV
```

The server is assembled by supplying an **application plugin**:

```haskell
data AppPlugin a = AppPlugin
    { roleDefs :: RoleDefs a
    , decodeAppEvent :: ByteString -> Either String a
    , encodeAppEvent :: a -> ByteString
    }

runServer :: AppPlugin a -> Passphrase -> IO ()
```

For the trivial first instance, `a = Void` (no application events, no application roles).

## 10. Edge Cases

| Scenario | Behavior |
|---|---|
| Last admin removed | Zero admins — bootstrap mode reactivates, passphrase auth required |
| Bootstrap: introduce member without admin | Rejected — first event must grant admin |
| App role removal blocked by precondition | `canRemove` returns `False` — role change rejected |
| Proposal with no approvals | Stays pending until majority reached or superseded |
| Member signs event after removal | Signature valid but member unknown in current fold — rejected |
| Concurrent proposals for same member | Each proposal is independent, both need majority, applied in KEL order |
