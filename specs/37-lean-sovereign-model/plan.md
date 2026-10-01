# Plan — 37

Lean only, new namespace `KelGroups.Sovereign`, modules under `lean/KelGroups/Sovereign/`,
aggregated by `lean/KelGroups/Sovereign.lean` and imported once from `lean/KelGroups.lean`
(the default target's root). Old modules untouched. keri-lean pinned at e37386c7, unchanged:
reuse `KERI.Crypto` scalar types (Digest, SAID, Key, Signature); reuse `KERI.Event` types where
they fit and say why where they do not. No keri-lean `axiom` may appear in any T0–T6
`#print axioms`.

One slice (S1, OWNER): model + T0–T6 + axiom guard + mutant receipt. Bisect-safe: one commit
on top of the planning commit; `just ci` green at every commit.

Axiom check is enforced by the build: for each of T0–T6 a `#guard_msgs in #print axioms`
asserting the exact axiom list (subset of propext, Classical.choice, Quot.sound), so a
`sorry`/`sorryAx` or keri-lean axiom breaks `lake build`.

Mutant evidence: for each theorem, one mutation of the admission/membership RULE (not the
proof) that makes `lake build` fail, recorded with command and exit code in the receipt.
