# Plan: KERI Bridge

## Progress

### Steps 1+2: Signed events + CESR keys — DONE

Implemented in commit `6795f7d` on `feat/keri-bridge`.

- Ed25519 signature verification on all event submissions
- CESR key validation on member introduction
- PureScript client signs events before submitting
- All tests use real keypairs and signatures
- 87 Haskell tests, 24 PureScript property tests pass

**Trust model caveat:** The server verifies what clients submit (input
sanitization), but clients do not yet verify what the server returns.
The server signature check keeps the KEL clean but does not make the
server untrusted from the client's perspective.

### Next: Hash-chain events and client-side verification — [#13](https://github.com/paolino/kelgroups/issues/13)

This is the **critical** step to achieve the untrusted-server property.

**Core invariant:** When a user signs an event, they sign
"I append X to a KEL whose tip has digest D" — not just "I authored X."
The signature commits to the entire history up to that point.

Without this, individual signatures prove authorship but not ordering.
The server can show different histories to different clients undetected.

**What it requires:**
- Each event includes `priorDigest` (hash of predecessor)
- The signed payload includes `priorDigest`
- Server validates the hash chain on append
- Server returns `(signer, signature, event)` triples from GET /events
- Client verifies signatures and digest chain on replay
- Stale-tip conflicts (concurrent submissions) are rejected; the client
  shows the user the updated state and lets them re-submit, edit, or
  discard their draft event

See [#13](https://github.com/paolino/kelgroups/issues/13) for full
specification including conflict UX.

### Architecture: L1/L2 separation

The voting mechanism moves off L1. Instead of interleaving proposals
and approvals on the main chain:

- **L1 (main KEL)** starts with the server's inception event (event 0).
  Subsequent events are outcomes only — enacted decisions and expired
  proposals. Each enacted event carries the proposal SAID + collected
  admin approval signatures as compact proof.
- **L2 (per-proposal KELs)** use the same KEL code as L1. L2 inception
  anchors the proposal content + timeout. The only allowed interaction
  events are approvals (each anchoring the proposal SAID, signed by an
  admin). Voting order is irrelevant — only the set of approvals matters.
- **Server identifier** — the server has its own KERI keypair (L1
  event 0). It is not an admin and cannot vote. It aggregates L2
  results into L1. Its signature is attestation, not a trust
  assumption — the embedded approval signatures are the real proof.
- **Timeout** — each L2 has a timeout set at creation. On expiry the
  server writes "expired" on L1. Verifiable: if L2 shows threshold
  was met before timeout, any client can catch a lying server.

### Invariants

Formalized in Lean 4 (`lean/KelGroups/KEL.lean` predicates,
`lean/KelGroups/KELInvariants.lean` proofs). Lean predicate names in
parentheses.

1. **L1 is append-only and hash-chained** (`hashChainValid`).
   Non-inception events: `priorDigest.isSome`, sequence = predecessor + 1.
   Inception: `sequenceNumber = 0`, `priorDigest = none`. Generic over
   payload type — applies to both L1 and L2.
2. **L1 event 0 is the server's inception** (`l1StartsWithInception`).
   Oldest L1 event has `sequenceNumber = 0`, `priorDigest = none`,
   payload `inception k`. Server key extracted by `serverKey`.
3. **Only the server writes to L1** (`l1ServerOnly`). Every L1 event
   has `signer = serverKey l1`. `False` if no valid inception.
4. **Every L1 enacted event is self-contained**
   (`l1EnactedSelfContained`). Enacted: `said ≠ 0` and
   `proofs.length > 0`. Inception/expired: trivially true.
5. **Approval signatures are over the proposal SAID**
   (`l2ApprovalsMatchSAID`). All L2 approvals reference the same SAID.
6. **Proposal SAIDs are unique** (`proposalSAIDsUnique`). `List.Nodup`
   over seen SAIDs. Client nonce makes identical proposals produce
   different SAIDs.
7. **The proposing admin controls the nonce** (`l2InceptionByAdmin`).
   L2 inception signer ≠ server key ∧ signer ∈ admin list.
8. **L2 only accepts approvals** (`l2OnlyApprovals`). Inception at
   `sequenceNumber = 0`; all others at `sequenceNumber > 0`.
9. **No duplicate approvals** (`l2NoDuplicateApprovals`). Approval
   signer keys have no duplicates (`List.Nodup`).
10. **Threshold = admin majority** (`thresholdMet`).
    `approvalCount ≥ (adminCnt + 1) / 2`. Proved for 3/2, ¬3/1,
    1/1, 0/0.
11. **L2 has a timeout** (`l2HasTimeout`). Inception carries
    `timeout > 0`.
12. **L2 is ephemeral** (`l1EnactmentComplete`). L1 enacted event
    carries enough proofs to meet threshold independently.

See `docs/docs/keri-bridge.md` section 4 for full design.

### Remaining steps

Steps 3–8 from the keri-bridge gap analysis remain after #13:

| Step | Gap | Status |
|------|-----|--------|
| 3. SAID for proposals | Gap 3 | Pending |
| 4. ~~Digest chain~~ | ~~Gap 4~~ | → merged into #13 |
| 5. Canonical JSON | Gap 5 | Pending |
| 6. Group inception + server identifier | Gap 6 | Pending |
| 7. L2 voting KELs | L1/L2 architecture | Pending |
| 8. HTTP session auth | [#8](https://github.com/paolino/kelgroups/issues/8) | Pending |
