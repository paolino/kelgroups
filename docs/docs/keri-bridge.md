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

## 4. Architecture: L1/L2 Separation

### Problem

KERI supports multi-sig with signing thresholds (`kt`), but that
mechanism authorizes a single event with multiple signatures collected
at once. kelgroups governance is *asynchronous voting* — admins submit
separate approval events over time, and a decision is enacted when
majority is reached.

Putting the entire voting process on a single chain means L1 is
cluttered with intermediate votes. Every client must replay the full
propose/approve sequence to derive the current state. Enacted decisions
are not directly visible — they are implicit in the fold.

### Design: L1 for outcomes, L2 for voting

**L1 (main KEL)** — the group's primary hash-chained event log.
The first event is the server's inception event (the server is not an
admin — it has no voting power). Subsequent events are outcomes:
enacted decisions and expired proposals. Each enacted event carries the
proposal SAID and the collected admin approval signatures as proof.
The fold over L1 is simple — it applies enacted decisions sequentially.

**L2 (per-proposal KELs)** — one ephemeral KEL per proposal, using the
same code and structure as L1 (signed events, digest chain, SAID). The
L2 inception event anchors the proposal content and timeout metadata.
The only interaction events allowed on an L2 are approvals — each
approval anchors the proposal SAID, signed by the approving admin.
The server rejects any other event type on L2.

Voting order is irrelevant — it doesn't matter whether Alice approved
before or after Bob. Only the set of approvals matters. The L2 KEL
structure is reused because the code already exists, not because
ordering is meaningful.

**Server identifier** — the server has its own KERI identifier (its own
keypair, with inception as L1 event 0). It is not an admin and cannot
approve proposals. It acts as an aggregator: when an L2 reaches
threshold, the server creates a single interaction event on L1
containing the proposal SAID and the collected approval signatures
(extracted from L2 events). The server signs this L1 event, but its
signature is attestation, not a trust assumption — the embedded admin
signatures are the real proof, independently verifiable by any client.

### Replay prevention

Proposals include a client-generated nonce as part of their content.
The proposal SAID is computed over the full content including the nonce,
so identical proposals submitted at different times produce different
SAIDs. Approval signatures are over the proposal SAID, binding them
to a specific proposal instance. The L1 enactment carries the proposal
SAID (which covers the nonce), so any client can verify that approvals
were not replayed from a different proposal — without needing the L2.

On L1, the server generates the inception nonce (establishing its own
identity). On L2, the proposing admin generates the nonce (the proposal
is the admin's act, not the server's).

The server rejects proposals whose SAID matches any existing or past
L2 (a simple set of seen SAIDs). This prevents both accidental
resubmission and intentional replay.

### Lifecycle of a proposal

1. **Propose** — an admin submits a proposal to the server, including
   a client-generated nonce in the proposal content. The server creates
   an L2 KEL: inception event anchoring the proposal content (with
   nonce) and timeout. The proposal's identity = SAID of this inception
   event, which depends on the admin's nonce.
2. **Vote** — admins submit approval events to the L2. Each approval
   is a signed interaction event anchoring the proposal SAID. The
   server verifies the signature against the current key state and
   rejects non-admin signers or duplicate approvals.
3. **Enact** — when the server sees enough approvals on L2 (admin
   majority), it writes an enacted interaction event on L1. This event
   anchors: the proposal SAID and the approval signatures (each as an
   `(admin-key, signature)` pair). This is a compact proof — the full
   L2 chain is not copied to L1.
4. **Expire** — if the timeout elapses before threshold is met, the
   server writes an expired event on L1 referencing the proposal SAID.
5. **Garbage collect** — after resolution (enacted or expired), the L2
   KEL can be discarded. The L1 event is the self-contained permanent
   record.

### Timeout enforcement

Each L2 is created with a timeout (set at proposal creation). The
server enforces it. This is verifiable: if the L2 signatures show
threshold was met before the timeout, and the server wrote "expired"
instead, any client with the L2 data can prove the server lied.

### Invariants

Formalized in Lean 4: predicate definitions in
`lean/KelGroups/KEL.lean`, proofs in `lean/KelGroups/KELInvariants.lean`.

1. **L1 is append-only and hash-chained** (`hashChainValid`). Every
   non-inception event has `priorDigest.isSome` and its sequence
   number equals its predecessor's plus one. The inception event has
   `sequenceNumber = 0` and `priorDigest = none`. The predicate is
   generic — it applies to both L1 and L2 chains.

2. **L1 event 0 is the server's inception** (`l1StartsWithInception`).
   The oldest L1 event has `sequenceNumber = 0`,
   `priorDigest = none`, and payload `inception k` for some key `k`.
   This key is the server's public key (`serverKey`). The server is
   not an admin and has no voting power.

3. **Only the server writes to L1** (`l1ServerOnly`). Every event in
   L1 has `signer = serverKey l1`. If the server key cannot be
   extracted (no valid inception), the predicate is `False`.

4. **Every L1 enacted event is self-contained**
   (`l1EnactedSelfContained`). For enacted events: the proposal SAID
   is non-zero (`said ≠ 0`) and at least one approval proof is
   present (`proofs.length > 0`). Inception and expired events
   satisfy the predicate trivially. Any client can verify the
   enactment from L1 alone, without fetching the L2.

5. **Approval signatures are over the proposal SAID**
   (`l2ApprovalsMatchSAID`). Every approval event in an L2 references
   the same SAID as the L2's proposal. Inception events satisfy the
   predicate trivially. This binds each approval to a specific
   proposal instance.

6. **Proposal SAIDs are unique** (`proposalSAIDsUnique`). The list of
   proposal SAIDs across all L2s has no duplicates (`List.Nodup`).
   Each proposal includes a client-generated nonce; the SAID is
   computed over the full content including the nonce. The server
   rejects proposals with a previously-seen SAID. Proved: adding a
   fresh SAID to a unique list preserves uniqueness.

7. **The proposing admin controls the nonce** (`l2InceptionByAdmin`).
   The L2 inception event is signed by a key that is not the server
   key and is in the current admin list. The server cannot forge the
   nonce without invalidating the admin's signature.

8. **L2 only accepts approvals** (`l2OnlyApprovals`). Inception events
   have `sequenceNumber = 0`; all subsequent events have
   `sequenceNumber > 0` and are approvals. Only inception at
   position 0, only approvals after.

9. **No duplicate approvals** (`l2NoDuplicateApprovals`). The signer
   keys extracted from approval events in an L2 have no duplicates
   (`List.Nodup`). Each admin approves at most once per proposal.

10. **Threshold = admin majority** (`thresholdMet`). Enactment
    requires `approvalCount ≥ majority adminCnt` where
    `majority n = (n + 1) / 2`. Proved: 3 admins / 2 approvals meets
    threshold; 3 admins / 1 approval does not; 1 admin / 1 approval
    meets threshold; bootstrap (0/0) satisfies trivially.

11. **L2 has a timeout** (`l2HasTimeout`). The L2 inception event
    carries a timeout field that is greater than zero. On expiry
    without threshold, the server writes an expired event on L1.
    Verifiable: if L2 data shows threshold was met before timeout, a
    lying server is detectable.

12. **L2 is ephemeral** (`l1EnactmentComplete`). The L1 enacted event
    carries enough approval proofs to meet threshold independently
    (`thresholdMet proofs.length adminCnt`). After resolution, the L2
    can be garbage collected — the L1 event is the self-contained
    permanent record.

### State machine transitions

The invariants above are static predicates. To prove the system
*maintains* them, each operation is modeled as a transition function
with preservation theorems. Definitions in `lean/KelGroups/KEL.lean`,
proofs in `lean/KelGroups/KELInvariants.lean`.

**L2 transitions (per-proposal voting chain):**

- **`mkL2`** — creates an L2 with a single inception event. The
  proposing admin signs. Proved to satisfy: `hashChainValid`,
  `l2NoDuplicateApprovals`, `l2OnlyApprovals`, `l2HasTimeout`
  (given `timeout > 0`), `l2InceptionByAdmin` (given admin ∉ server,
  admin ∈ admins), `l2ApprovalsMatchSAID` (vacuously — no approvals
  yet).

- **`appendApproval`** — appends an approval event referencing the
  proposal SAID. The approving admin signs. Proved:
  `appendApproval_preserves_approvals_match` (if the existing L2
  matches the SAID, the extended L2 still does),
  `appendApproval_fresh_preserves_no_duplicates` (if the signer is
  fresh, no-duplicate-approvals is preserved).

**L1 transitions (main outcome chain):**

- **`mkL1`** — creates an L1 with the server inception event. The
  server signs with its own key. Proved to satisfy: `hashChainValid`,
  `l1StartsWithInception`, `l1ServerOnly`, and all events are
  `l1EnactedSelfContained`.

- **`appendEnacted`** — appends an enacted event carrying the proposal
  SAID and collected approval proofs. Proved:
  `appendEnacted_preserves_self_contained` (given `proposalSAID ≠ 0`
  and `proofs.length > 0`, self-containment holds for all events
  including the new one).

- **`appendExpired`** — appends an expired event carrying the proposal
  SAID. Proved: `appendExpired_preserves_self_contained` (expired
  events satisfy self-containment trivially).

**Combined validity structures:**

- `L1Valid` bundles invariants 1–4: hash chain, inception, server-only,
  self-contained.
- `L2Valid` bundles invariants 5, 7–9, 11: approvals match SAID,
  inception by admin, only approvals, no duplicates, has timeout.

Each transition preserves the fields of its validity structure.
This maps directly to QuickCheck state machine testing: each
preservation theorem becomes a property that generates valid states,
applies the transition, and asserts the invariant holds after.

### Trust model

The server is untrusted. Clients perform all cryptographic operations:
key generation, event signing, SAID computation. The server's role is
strictly verification and aggregation — it checks signatures against
the current key state, monitors L2 KELs for threshold/timeout, and
packages results into L1. It never holds or generates private keys.

The server's own KERI identifier allows it to sign L1 events, but this
signature is not a trust assumption. It is attestation that the server
verified the L2 threshold. The approval signatures embedded in the L1
enactment event are the actual proof — any client can re-verify them
against the admin keys in the current key state.

### What this replaces

The previous options (A: group-as-identifier, B: member KELs + group
log, C: hybrid) are superseded by this design. Option C's starting
point (group KEL with challenge-response auth) is still the foundation
for L1, but the voting mechanism moves to L2 KELs instead of being
interleaved on L1.

Per-member KELs (option B) remain a future evolution for individual
key lifecycle management.

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

### Step 6: Group inception + server identifier

Closes **Gap 6** (no key state machine) partially.

- Bootstrap = group inception event via `mkInception`
- `InceptionConfig` with initial admin keys and threshold = majority
- Group identifier = SAID of inception event
- Server gets its own KERI identifier (keypair + inception event)
- Server signs L1 events with its own key
- **Tests:** inception produces valid self-certifying identifier,
  key state derived correctly, server identity verifiable
- **Files:** `Bootstrap.hs`, `Server.hs`

### Step 7: L2 voting KELs

Implements the L1/L2 separation described in section 4.

- L2 uses the same KEL infrastructure as L1 (same code path)
- L2 inception anchors proposal content + timeout
- L2 interactions restricted to approvals (proposal SAID as anchor)
- Server rejects any other event type on L2
- Server monitors L2 for threshold (admin majority) or timeout
- On threshold: server extracts `(admin-key, signature)` pairs from
  L2 approvals and writes enacted event on L1 with compact proof
- On timeout: server writes expired event on L1
- L2 KELs discarded after resolution
- Client verifies L1 enacted events by checking embedded approval
  signatures against current key state
- **Tests:** voting lifecycle (propose → approve → enact), timeout
  expiry, approval signature verification from L1 events, L2
  event type restriction
- **Files:** `Server.hs`, `Fold.hs`

### Step 8: HTTP session authentication

Closes [issue #8](https://github.com/paolino/kelgroups/issues/8).

- Challenge-response: server sends random nonce, client signs with
  Ed25519 key, server verifies against group key state
- Session cookie tracking
- WAI middleware layer
- **Files:** new `Server/Auth.hs`

## 6. Out of Scope

These KERI features are explicitly deferred:

- **Per-member KELs** — each member as their own KERI identifier
- **Key rotation** — pre-committed next keys and rotation events for
  the group
- **Witness/receipt infrastructure** — out-of-band availability and
  duplicity detection
- **OOBI protocol** — out-of-band introduction for discovering KELs
- **Delegated identifiers** — hierarchical identifier delegation
