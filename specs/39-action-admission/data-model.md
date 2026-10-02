# Data — 39

- D1 Group anchor: the single element of an `ixn`'s `a`, a JSON object with exactly these keys:
  - genesis: `{"payload": {"t": "genesis"}}`;
  - other: `{"group": <group id>, "prev": <digest of the head action>, "payload": <payload>}`.
  Payload: `{"t": "genesis"}` | `{"t": "app", "data": <any JSON>}` (exact keys). Other tags are
  #40's. A genesis carrying `group` or `prev`, a non-genesis missing either, any extra key or
  element: not a group action.
- D2 Action: signer (`i`), group id (`group`, or the event's `d` at genesis), `p`, payload,
  `prev` (none at genesis), the signed event. Chain: the admitted actions of one group,
  genesis first, each later `prev` = `d` of its predecessor; head = `d` of the last. Roster:
  members and admins (genesis: the signer as both; app: unchanged).
- D3 Wire form: `POST /actions` body = the #38 signed event form
  `{"event": <ixn>, "signatures": [{"index", "signature"}]}`. 200 body:
  `{"group": <id>, "head": <d of the action>, "prefix": <signer>, "sn": <s>}`; an identical
  retry returns the same body.
- D4 Refusals (each stores nothing), with exactly one condition violated:
  | class | status |
  |---|---|
  | body, event or anchor not decodable (D1) | 400 |
  | event not an `ixn`; SAID mismatch; signatures invalid or under threshold | 422 |
  | signer not hosted; group id with no chain | 404 |
  | signer not a current member | 403 |
  | `p`/`s` not the signer's tip successor; `prev` not the head; genesis of an existing id | 409 |
  Check order (the first failing check decides the status): decode; R5 retry; signer hosted;
  the #38 interaction rule in its order (SAID, `i`/`p`/`s` against the tip, signatures);
  genesis: id unused; non-genesis: group exists, signer a member, `prev` is the head.
  Refusal bodies name the class in the stable machine-readable `error` field (as #38).
  A write failure is 500 and stores nothing.
- D5 Storage: unchanged `member_kel_events` rows (#38 D6); an admitted action is one row.
  Chains and heads exist only in memory, rebuilt on open.
