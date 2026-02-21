# KERI Bridge: Gap Analysis

This document maps kelgroups concepts to [KERI](https://keri.one) concepts,
identifies the exact gaps between the current implementation and KERI
compliance, and outlines an incremental path to close them.

The reference KERI implementation is
[keri-hs](https://github.com/paolino/keri-hs), already available in the
project's nix flake.

## 1. KERI Primer

Five core concepts that kelgroups needs to understand, each with the keri-hs
type that implements it.

| Concept | What it is | keri-hs module | Type / function |
|---------|-----------|----------------|-----------------|
| **Self-certifying identifier** | The identifier IS the hash of the inception event — no external registry needed | `Keri.Event`, `Keri.Crypto.Digest` | `eventDigest`, `eventPrefix`, `computeSaid` |
| **Signed events** | Every KEL entry carries Ed25519 signatures; the key state determines which keys are valid | `Keri.Kel`, `Keri.KeyState.Verify` | `SignedEvent { event, signatures }`, `verifySignatures` |
| **Digest chain** | Each event includes the hash of its predecessor, forming a tamper-evident chain | `Keri.Event` | `priorDigest` field on `RotationData` / `InteractionData` |
| **SAID** | Self-Addressing Identifier — the event's own digest field is computed over a serialization that contains a placeholder, then replaced with the real hash | `Keri.Crypto.Digest` | `computeSaid`, `saidPlaceholder` (44 `#` characters) |
| **Key rotation** | Current signing keys can be rotated by revealing pre-committed next keys; the commitment is a hash of the future key | `Keri.Event.Rotation`, `Keri.KeyState.PreRotation` | `RotationConfig`, `mkRotation`, `commitKey` |

### Supporting concepts

- **CESR encoding** — all cryptographic material (keys, digests, signatures)
  is encoded as self-framing Base64url text with a derivation-code prefix.
  Types: `Ed25519PubKey` (`"D"`), `Blake2bDigest` (`"E"`),
  `Ed25519Sig` (`"0B"`). Module: `Keri.Cesr.*`.

- **Interaction anchors** — interaction events carry arbitrary JSON anchors
  (`ixAnchors :: [Value]`) without changing key state. Used to bind
  external data (proposals, approvals) to the KEL.

- **Signing thresholds** — `stateSigningThreshold :: Int` in `KeyState`
  defines the minimum number of valid signatures required to authorize an
  event. Set at inception, updatable via rotation.

## 2. Concept Mapping

Side-by-side mapping from kelgroups to KERI.

| kelgroups concept | Current implementation | KERI equivalent | keri-hs reference |
|---|---|---|---|
| **Group bootstrap** | Passphrase + first `IntroduceMember` proposal. `authMode` in `Bootstrap.hs:19-25` switches on `adminCount == 0`. | **Inception event** with initial keys and signing threshold | `mkInception :: InceptionConfig -> Event` |
| **Member key** | `memberKey :: Text` in `Types.hs:64-72` — trusted, never validated | **CESR-encoded Ed25519 public key** validated on decode | `Cesr.decode :: Text -> Either String Primitive` |
| **Event signer** | `subSigner :: Text` field in `Server/JSON.hs:55-63` — passed through unchecked | **Indexed signature** verified against key state | `verifySignatures keys threshold msg sigs` |
| **Proposal** | `Base (Propose proposal)` in `Event.hs:37-42` | **Interaction anchor** carrying proposal JSON | `InteractionConfig { ixAnchors = [proposalJson] }` |
| **Approval** | `Base (Approve pid)` in `Event.hs:37-42` | **Interaction anchor** carrying approval reference | same, with anchor referencing proposal SAID |
| **Proposal digest** | `proposalDigest p = "proposal:" <> pack (show p)` in `Fold.hs:184-187` — placeholder | **SAID** of the proposal interaction event | `computeSaid` over `serializeEvent` bytes |
| **Event storage** | SQLite `events (id INTEGER PRIMARY KEY AUTOINCREMENT, signer TEXT, event BLOB)` in `Store.hs:72-76` | **KEL** with digest chain | `Kel.append :: Kel -> SignedEvent -> Either String Kel` |
| **Event serialization** | CBOR via `Codec.Serialise` in `Store/Serialise.hs` | **Canonical JSON** with deterministic field order | `serializeEvent :: Event -> ByteString` |
| **Admin majority** | `majority gs = (adminCount gs + 1) \`div\` 2` in `State.hs:66-73` | **Signing threshold** (`kt` field in events) | `stateSigningThreshold` in `KeyState` |
| **Key state** | Not tracked — members map is flat | `KeyState` with current keys, next commitments, sequence number | `applyEvent :: KeyState -> Event -> Either String KeyState` |

## 3. The Gaps

Concrete list of what kelgroups does NOT implement, ordered by severity.

### Gap 1: ~~No signature verification~~ — CLOSED

Server verifies Ed25519 signatures on all event submissions. PureScript
client signs events before submitting. Implemented on `feat/keri-bridge`.

**Caveat:** Clients do not yet verify signatures on events fetched from
the server. This is addressed by [#13](https://github.com/paolino/kelgroups/issues/13).

---

### Gap 2: ~~No self-certifying identifiers~~ — CLOSED

Member keys are validated as CESR-encoded Ed25519 public keys on
introduction. `InvalidKey` validation error rejects anything else.
Implemented on `feat/keri-bridge`.

**Caveat:** Keys are self-certifying in the sense that they are the
public key itself, but not yet KERI self-certifying identifiers (SAID of
inception event). That requires Gap 6 (group inception).

---

### Gap 3: No SAID (HIGH)

**Design doc claims:** proposals have cryptographic digests.

**Code does:** `proposalDigest p = "proposal:" <> pack (show p)` in
`Fold.hs:184-187`. This is a human-readable string, not a cryptographic
hash. The code has a `TODO: use proper SAID/hash via keri-hs` comment.

**KERI requires:** event identifiers are computed via SAID — hash over
the serialized event with a placeholder in the digest field.

**keri-hs:** `computeSaid` in `Keri.Crypto.Digest`.

---

### Gap 4: No digest chain (HIGH) — tracked in [#13](https://github.com/paolino/kelgroups/issues/13)

**Design doc claims:** events form a Key Event Log.

**Code does:** events are stored with SQLite autoincrement IDs
(`Store.hs:72-76`). There is no hash linking between events. An event
can be silently deleted or reordered without detection.

**KERI requires:** every event (except inception) includes `priorDigest` —
the hash of its predecessor. Tampering breaks the chain.

**keri-hs:** `priorDigest` field on `InteractionData` and `RotationData`.

**Core invariant:** When a user signs an event, they sign "I append X to
a KEL whose tip has digest D." The signature commits to the entire
history up to that point. Without this, signatures prove authorship but
not ordering — the server can present different histories to different
clients undetected.

**Conflict handling:** When a submission references a stale tip (another
client appended in between), the server rejects it. The client must
fetch the new events, show the user the updated state, and let them
re-submit, edit, or discard their draft. No automatic retry — the user
must acknowledge the new state.

See [#13](https://github.com/paolino/kelgroups/issues/13) for full
specification.

---

### Gap 5: No canonical serialization (MEDIUM)

**Design doc claims:** events are serialized for storage.

**Code does:** CBOR via `Codec.Serialise` in `Store/Serialise.hs:41-181`.
CBOR is a compact binary format but is not the KERI wire format and
is not deterministic without extra care.

**KERI requires:** canonical JSON with protocol-defined field ordering
(`v`, `t`, `d`, `i`, `s`, `p`, `kt`, `k`, ...). This determinism is
essential — `computeSaid` and signature verification depend on it.

**keri-hs:** `serializeEvent` in `Keri.Event.Serialize`.

---

### Gap 6: No key state machine (MEDIUM)

**Design doc claims:** the group tracks membership.

**Code does:** `GroupState` in `State.hs:34-41` has a flat `members :: Map Text Member`.
There is no concept of current vs. next keys, no sequence numbers,
no pre-rotation commitments.

**KERI requires:** `KeyState` tracks `stateKeys`, `stateNextKeys`,
`stateSequenceNumber`, `stateLastDigest`, and evolves via `applyEvent`.

**keri-hs:** `Keri.KeyState.applyEvent`, `Keri.KeyState.initialState`.

---

### Gap 7: No witnesses or receipts (LOW)

**Current scope:** single trusted server.

**KERI full spec:** witness infrastructure provides out-of-order delivery,
duplicity detection, and availability guarantees.

**Decision:** out of scope for now. The server acts as sole witness.

## 4. Architectural Question: One KEL or Many?

KERI specifies one KEL per identifier. kelgroups currently has one event log
for the entire group. Three options:

### Option A: Group-as-identifier

The group itself IS a KERI identifier. The inception event lists all
initial admin keys. The signing threshold equals the admin majority.

- **Membership changes** = rotation events (new key set, new threshold)
- **Proposals and approvals** = interaction events with JSON anchors
- **Group identifier** = SAID of the inception event

**Pros:** simple, one KEL to manage, directly maps to kelgroups' current
single-log model. keri-hs already supports multi-sig inception.

**Cons:** rotation replaces the entire key set, which means every membership
change requires coordination of all current members. Does not cleanly model
individual member identity.

### Option B: Member KELs + group log

Each member has their own KERI KEL (their own identifier, their own key
rotation). The group maintains a separate log that references member
identifiers for signature verification.

- **Member joins** = their KEL's inception event is anchored in the group log
- **Member key rotation** = happens in their own KEL, group verifies
  against member's current key state

**Pros:** KERI-orthodox, each member controls their own key lifecycle,
clean separation of concerns. Supports members participating in
multiple groups.

**Cons:** significantly more complex. Group must verify member KELs,
handle out-of-sync states, manage KEL discovery.

### Option C: Hybrid (recommended for incremental adoption)

The group has a KEL (option A). Members prove identity via
challenge-response using their Ed25519 keys, but do not maintain
individual KELs initially.

- **Bootstrap** = group inception with initial admin keys
- **Authentication** = server issues a challenge, member signs with
  their key, server verifies against the group's current key state
- **Key rotation** = deferred until needed

**Pros:** simple starting point, closes the critical gaps (signature
verification, self-certifying identifiers, digest chain) without the
complexity of per-member KELs. Can migrate to option B later by
introducing member KELs.

**Cons:** members cannot independently rotate keys. The group KEL
must be updated for any key change.

### Recommendation

Start with **Option C** (hybrid). It closes the critical gaps with
minimal architectural disruption. Option B can be adopted later as
a separate evolution step once the foundation is solid.

### Trust model

The server is untrusted. Clients perform all cryptographic operations:
key generation, event signing, SAID computation. The server's role is
strictly verification — it checks signatures against the current key
state but never holds or generates private keys. This is a fundamental
design constraint that applies to every step below.

## 5. Incremental Bridge Path

Each step is independently shippable and testable.

### Step 1: Signed events

Closes **Gap 1** (no signature verification).

- Add `keri-hs` dependency to `kelgroups.cabal`
- `Submission` gains `subSignature :: Text` (CESR-encoded Ed25519 signature)
- Server computes `serializeSubmission sub` and verifies:
  `Ed25519.verify pubKey msgBytes signature`
- Reject submissions with invalid signatures
- **Tests:** generate keypairs, sign submissions, verify round-trip
- **Files:** `Server.hs`, `Server/JSON.hs`, `kelgroups.cabal`

### Step 2: CESR keys

Closes **Gap 2** (no self-certifying identifiers).

- Member keys must be valid CESR-encoded Ed25519 public keys
- Validate on `IntroduceMember`: `Cesr.decode key` must succeed and
  return `Ed25519PubKey`
- Existing test helpers switch from `"alice"`, `"bob"` to real
  generated keypairs
- **Tests:** invalid CESR keys are rejected, valid ones accepted
- **Files:** `Validate.hs`, test helpers

### Step 3: SAID for proposals

Closes **Gap 3** (no SAID).

- Replace `proposalDigest` placeholder with `computeSaid` over
  canonical JSON serialization of the proposal
- `ProposalId` = SAID of the proposal
- **Tests:** same proposal always produces same SAID, different
  proposals produce different SAIDs
- **Files:** `Fold.hs`, `Event.hs`

### Step 4: Digest chain

Closes **Gap 4** (no digest chain).

- Each stored event includes `priorDigest` (hash of previous event's
  serialized bytes)
- First event's `priorDigest` = inception event's digest (or a
  well-known genesis value)
- Verify chain integrity on replay
- **Tests:** tampered events break the chain, clean replay succeeds
- **Files:** `Store.hs`, `Event.hs`

### Step 5: Canonical JSON

Closes **Gap 5** (no canonical serialization).

- Replace CBOR serialization with deterministic JSON matching keri-hs
  field ordering conventions
- Use `serializeEvent` pattern: explicit field ordering via aeson
  `Encoding` builder
- **Migration:** one-time re-encoding of existing SQLite data, or
  version flag in the schema
- **Files:** `Store.hs`, `Store/Serialise.hs` (rename to
  `Store/Serialize.hs`)

### Step 6: Group inception

Closes **Gap 6** (no key state machine) partially.

- Bootstrap = group inception event via `mkInception`
- `InceptionConfig` with initial admin keys and threshold = majority
- Group identifier = SAID of inception event
- Subsequent membership changes modeled as rotation or interaction
  events
- **Tests:** inception produces valid self-certifying identifier,
  key state derived correctly
- **Files:** `Bootstrap.hs`, `Server.hs`

### Step 7: HTTP session authentication

Closes [issue #8](https://github.com/paolino/kelgroups/issues/8).

- Challenge-response: server sends random nonce, client signs with
  Ed25519 key, server verifies against group key state
- Session cookie tracking
- WAI middleware layer
- **Files:** new `Server/Auth.hs`

## 6. Out of Scope

These KERI features are explicitly deferred:

- **Per-member KELs** — each member as their own KERI identifier
  (option B above)
- **Key rotation** — pre-committed next keys and rotation events for
  the group
- **Witness/receipt infrastructure** — out-of-band availability and
  duplicity detection
- **OOBI protocol** — out-of-band introduction for discovering KELs
- **Delegated identifiers** — hierarchical identifier delegation
