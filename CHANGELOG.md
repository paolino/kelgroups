# Changelog

## 1.0.0 (2026-09-06)


### Features

* add Ed25519 signature verification and CESR key validation ([e397438](https://github.com/paolino/kelgroups/commit/e397438a8f81c05b08ada58aabc62b4ebe25dfe0))
* add KEL state machine transitions and preservation proofs ([f4a99b4](https://github.com/paolino/kelgroups/commit/f4a99b4c0fda4c57c39b2c351c9552809d8f3a7b))
* add L1Valid lifecycle theorems ([4f12ff8](https://github.com/paolino/kelgroups/commit/4f12ff847aff9adcfcbcb0bc71268c01731b074a))
* add nix docker image builder ([a2c556c](https://github.com/paolino/kelgroups/commit/a2c556cd178d365da00149362651ed4bfb1a00e6))
* adopt keri-hs KEL format for hash-chained event storage ([03c4069](https://github.com/paolino/kelgroups/commit/03c40692a16796aff8053dbf4802fd1272e86322)), closes [#13](https://github.com/paolino/kelgroups/issues/13)
* **client:** member key export/import as JWK ([c5457c7](https://github.com/paolino/kelgroups/commit/c5457c7afefe99eafc97f12fdb9f5d3536a5ab04))
* Ed25519 private key export/import as JWK (RFC 7517/8037) ([368b596](https://github.com/paolino/kelgroups/commit/368b596fef0b6d393c2ac7afc631d236c55d86d1))
* Ed25519 private key export/import as JWK (RFC 7517/8037) ([937a8ea](https://github.com/paolino/kelgroups/commit/937a8ea231e54018aed5ecb65ab57d5c5f962b0e))
* email on members, Admin role split, server access control ([7fa7720](https://github.com/paolino/kelgroups/commit/7fa77204ffaf5f54504f46dfd7f9ab9b163fa423))
* Haskell library skeleton with base group management types ([b231599](https://github.com/paolino/kelgroups/commit/b2315992fd2991d68474ab3069bf6c7416866ae5))
* HTTP server with WAI, JSON serialization, and SSE ([d669c31](https://github.com/paolino/kelgroups/commit/d669c319d74bb4240f16e4a003255f24796150ef))
* initial repo with design doc and MkDocs setup ([2d606e2](https://github.com/paolino/kelgroups/commit/2d606e280dbfe798424b34b95732530b37c7e7fd))
* Lean 4 formalization of group invariants ([1936554](https://github.com/paolino/kelgroups/commit/1936554eb026b813b03d416bbd3bcb130a4be319))
* Lean 4 state machine transitions and invariant preservation proofs ([0acf11c](https://github.com/paolino/kelgroups/commit/0acf11cff9e8d7f535b43de2fd9e8b31595e6b3f))
* Lean validation/fold proofs and QC properties ([b11974d](https://github.com/paolino/kelgroups/commit/b11974db4586bc170aefe51924fd7cd613aa0721))
* PureScript client with QuickCheck property tests ([97c1aba](https://github.com/paolino/kelgroups/commit/97c1aba799dc166380b0624393c58b3345b31f0f))
* server identity and L1 inception (Step 6) ([e31a8b8](https://github.com/paolino/kelgroups/commit/e31a8b8001b06b71203699d50a23fb1421170638))
* server identity export-key/import-key commands ([28a02b9](https://github.com/paolino/kelgroups/commit/28a02b996858fdefbd9e02dc5b469018eb1959d5))
* SQLite-backed KEL store with random access ([0a8ac64](https://github.com/paolino/kelgroups/commit/0a8ac64a8704e6407385afcb71d7373bd75ca8d0))
* **vote:** declare the Vote substrate vocabulary and state types ([#35](https://github.com/paolino/kelgroups/issues/35)) ([9762ad4](https://github.com/paolino/kelgroups/commit/9762ad4db50f370348ea71abd44f7e969349d4b4))


### Bug Fixes

* bump haskell.nix pin past appendContext breakage ([f44bf57](https://github.com/paolino/kelgroups/commit/f44bf57c7aa428b0ea8610f1021431f6bc48b432))
* PureScript unused imports and missing email params in tests ([df9ca34](https://github.com/paolino/kelgroups/commit/df9ca34a7ced7930276a4866b9d51203e86526e0))
