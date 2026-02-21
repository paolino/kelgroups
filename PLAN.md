# Plan: Implement KERI Bridge Steps 1+2

## Context

The keri-bridge.md gap analysis identifies 7 gaps between kelgroups and
KERI compliance. This plan implements the first two steps: **CESR keys**
(Gap 2) and **signed events** (Gap 1). These are tightly coupled —
signature verification requires valid public keys.

**Trust model:** Clients perform all cryptographic operations. The server
is untrusted — it only verifies signatures, never holds private keys.

## Changes

### 1. Add keri-hs dependency

- `kelgroups.cabal`: add `keri-hs` to library `build-depends`
- Verify keri-hs is available in the nix flake

### 2. CESR key validation (Step 2 — do first, Step 1 depends on it)

- `Validate.hs`: on `IntroduceMember key _ _`, validate
  `Cesr.decode key` succeeds and returns `Ed25519PubKey`
- New `ValidationError` constructor: `InvalidKey Text`
- `Types.hs`: `memberKey :: Text` stays Text but is now guaranteed valid CESR

### 3. Signed submissions (Step 1)

- `Server/JSON.hs`: add `subSignature :: Text` to `Submission`
  (update ToJSON/FromJSON instances)
- `Server.hs`: after validation, verify signature:
  1. Serialize the event (the signed message)
  2. Decode `subSigner` as CESR Ed25519 public key
  3. Decode `subSignature` as CESR Ed25519 signature
  4. Verify with Ed25519.verify
  5. Reject with 401 if verification fails
- Use aeson `encode` for signing serialization (refined in Step 5)

### 4. Test helpers — real keypairs

- `test/TestHelpers.hs`: keypair generation + signing helpers via keri-hs
- Update all tests to use real CESR keys and valid signatures
- `test/Generators.hs`: generate valid CESR keys for QuickCheck

### 5. Bootstrap mode

- Bootstrap submissions still need passphrase + valid signature
- First `IntroduceMember` uses a real CESR-encoded key

## Files to modify

| File | Change |
|---|---|
| `kelgroups.cabal` | Add `keri-hs` dependency |
| `lib/KelGroups/Validate.hs` | CESR key validation |
| `lib/KelGroups/Server/JSON.hs` | Add `subSignature` to Submission |
| `lib/KelGroups/Server.hs` | Verify signatures on POST |
| `test/TestHelpers.hs` | Keypair generation + signing |
| `test/E2ESpec.hs` | Real keys + signatures |
| `test/MultiClientSpec.hs` | Real keys + signatures |
| `test/ServerSpec.hs` | Real keys + signatures |
| `test/Generators.hs` | Valid CESR key generators |

## Verification

```bash
cd /code/kelgroups-dev
nix develop --quiet -c bash -c "just format && just ci"
```
