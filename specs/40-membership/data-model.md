# Data — 40

- D1 Payload wire form (inside the #39 group anchor, exact keys):
  `{"t": "genesis"}` | `{"t": "add", "member": <prefix>}` | `{"t": "remove", "member": <prefix>}`
  | `{"t": "grant", "member": <prefix>}` | `{"t": "revoke", "member": <prefix>}`
  | `{"t": "leave"}` | `{"t": "app", "data": <any JSON>}`.
  `<prefix>` is a JSON string (a member KEL prefix). Every non-genesis payload uses the #39
  non-genesis anchor (`group`, `prev`, `payload`). Missing/extra keys or a non-string member:
  not a group action (400).
- D2 Roster: members and admins, each a set of prefixes (order not observable); R2 effects.
  Invariant of every admitted chain: members empty or admins non-empty; admins ⊆ members.
- D3 Responses: unchanged #39 D3.
- D4 Refusals (extends #39 D4; each stores nothing):
  | condition | status | `error` |
  |---|---|---|
  | signer not an admin (add, remove, grant, revoke) | 403 | `notAnAdmin` |
  | add target's KEL not hosted | 404 | `memberNotHosted` |
  | add target already a member | 409 | `alreadyMember` |
  | remove/grant target not a member | 409 | `targetNotMember` |
  | grant target already an admin | 409 | `alreadyAdmin` |
  | revoke target not an admin | 409 | `targetNotAdmin` |
  | last-admin guard fails | 409 | `lastAdmin` |
  Check order: #39 order (decode; retry; signer hosted; KEL rule; genesis: id unused;
  non-genesis: group exists, signer a member, `prev` is the head), then signer an admin, then
  target hosted (add), then target state, then the last-admin guard. The first failing check
  decides. A write failure is 500 and stores nothing.
- D5 Storage: the `member_kel_events` table only (#38 D6), created by the member KEL store
  when it opens the database file. No other table is created; existing foreign tables are
  ignored.
