# Data — 38

- D1 Signed event: keri-hs `Event` (icp, rot, ixn; receipts refused) plus indexed signatures
  `[(index, CESR signature)]` (keri-hs `Keri.Kel.SignedEvent`).
- D2 Member KEL: non-empty, oldest first, satisfying spec R3 event by event: first is the
  inception with `i` = `d`; event n has `s` = n, `i` = prefix, `p` = digest of event n-1;
  each rotation's `k` matches the previous establishment event's `n`. Current keys = last
  establishment event's `k`/`kt`; commitment = its `n`/`nt`. `tip` = digest of the last event.
- D3 Hosted set: map prefix → D2. A prefix is hosted iff present. Only `host` adds a key;
  only appends extend a value; nothing removes or rewrites.
- D4 Refusal classes (each stores nothing) and HTTP status:
  | class | status |
  |---|---|
  | body or event not decodable | 400 |
  | event kind not icp/rot at `POST /kel` (ixn, rct) | 422 |
  | SAID mismatch, `i` != `d` on inception, missing next-key commitment, thresholds out of range, witnesses present | 422 |
  | rotation not revealing the committed keys | 422 |
  | signatures invalid or under threshold for the controlling keys | 422 |
  | rotation for an unhosted prefix | 404 |
  | inception of a hosted prefix; rotation whose `p`/`s` is not the tip's successor | 409 |
  Refusal bodies name the class in a stable machine-readable field.
- D5 Wire form (`POST /kel` body; each element of `GET /kel/<prefix>`):
  `{"event": <KERI event object, labels v t d i s p kt k nt n bt b/br ba c a as keri-hs serializes>, "signatures": [{"index": <int>, "signature": "<CESR>"}]}`.
  Signatures are verified over the keri-hs canonical serialization of the decoded event.
  `POST /kel` 200 body: `{"prefix", "sn", "digest"}`. `GET` 404 when unhosted.
- D6 Storage: one row per event (prefix, sn, canonical event bytes, signatures, digest),
  unique (prefix, sn), in the server database. Old-group tables unchanged apart from R7.
  No `server_identity` table; a fresh database holds no key material.
