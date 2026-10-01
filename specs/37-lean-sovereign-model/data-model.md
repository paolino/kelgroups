# Data — 37

- D1 Member identifier: the prefix (SAID) of a hosted KEL.
- D2 Member KEL event: inception, rotation, or group action; each non-inception event carries
  `p` = digest of the previous event of the same KEL. Tip of a KEL = digest of its last event;
  an unhosted identifier has no tip.
- D3 Group action: signer identifier, group id (SAID), `p` (Digest), payload, `prev`
  (Option Digest), signature. Payload: genesis | add x | remove x | grant x | revoke x | leave |
  opaque application data.
- D4 Server state: member KELs (identifier → KEL), and per group id the admitted chain
  (admission order). Group head = digest of the chain's latest action; no chain = group absent.
  Membership is DERIVED from the chain (replay of core actions from genesis), not stored.
- D5 Assumptions structure (explicit parameter, no `axiom`): digest of an event, SAID of a
  genesis action, signature validity predicate, KERI validity predicates for inception and
  rotation; fields: digest injective on events; no event embeds its own digest (as `p` or
  `prev`); any further field must be stated and justified in the receipt.
- State invariants on reachable states: S1 chains are single prev-linked lines from genesis;
  S2 no action occurs twice in a chain; S3 admins ⊆ members; S4 members ≠ ∅ → admins ≠ ∅;
  S5 every admitted action is the corresponding entry of its signer's KEL.
