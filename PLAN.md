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

### Remaining steps

Steps 3–7 from the keri-bridge gap analysis remain after #13:

| Step | Gap | Status |
|------|-----|--------|
| 3. SAID for proposals | Gap 3 | Pending |
| 4. ~~Digest chain~~ | ~~Gap 4~~ | → merged into #13 |
| 5. Canonical JSON | Gap 5 | Pending |
| 6. Group inception | Gap 6 | Pending |
| 7. HTTP session auth | [#8](https://github.com/paolino/kelgroups/issues/8) | Pending |
