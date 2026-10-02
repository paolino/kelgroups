# Data — 41

- D1 Wire forms reused unchanged: signed event (`KelGroups.Kel.Codec` header), group anchor and
  payloads (`KelGroups.Group` header), `POST /actions` answers and refusal classes
  (`KelGroups.Server`). A client-built anchor serializes exactly as the server re-serializes it.
- D2 Group index, `GET /groups/<gid>` 200:
  `{"head": "<digest>", "kels": [{"prefix": "<prefix>", "tip": "<digest>"}, ...]}` — one entry
  per prefix that signed an action of the group or was the target of an `add`, sorted by prefix,
  no duplicates; `tip` is that KEL's current tip. 404 `{"error": "noSuchGroup", "detail": …}`.
  Non-evidence: the client trusts nothing in it beyond "where to look".
- D3 Suffix, `GET /kel/<prefix>?after=<sn>`: `sn` canonical non-negative decimal (as
  `KelGroups.Kel.Codec` thresholds); 200 = hosted events with `s > sn`, oldest first (`[]` past
  the tip); no `after` = whole KEL; any other `after` value 400
  `{"error": "badQuery", "detail": …}`; unhosted 404 `unhosted` (as today). Other query keys are
  ignored.
- D3k `ValidatedKel` (client): prefix, the signed events as received, tip, `s` of the tip, current
  keys and threshold, next commitments and threshold. Only M2 constructs it.
- D4 `GroupView` (client): group id, head, the chain (genesis first), roster (Lean `Roster`:
  `members`, `admins`, in `applyCore` order), and the validated KELs it was built from. Equality
  is structural; only a refusal-free sync constructs it.
- D5 `SyncRefusal`: `KelInvalid {prefix, s, reason}` · `Gap {missing digest}` ·
  `NotOnLine {digest}` · `RuleViolation {digest, class}` with the server's refusal class names
  (`notAMember`, `prevNotHead`, `notAnAdmin`, `memberNotHosted`, `alreadyMember`,
  `targetNotMember`, `alreadyAdmin`, `targetNotAdmin`, `lastAdmin`) · `HistoryRewritten {prefix, s}`
  · `Transport {status, detail}`.
- D6 Submission outcome: `Admitted {group, head, prefix, sn}` (200, also for an identical resend)
  · `Refused {status, error}` · `Unanswered` (attempts exhausted). A pending own action lives
  only in the outcome, never in a `ValidatedKel` or `GroupView` (R10).
