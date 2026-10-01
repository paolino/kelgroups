# Functions — 37 (names indicative; signatures fixed by meaning)

- F1 tip (kel) : Option Digest
- F2 host (state, inception event) : Option State — new identifier only, KERI-valid
- F3 rotate (state, identifier, rotation event) : Option State — `p` = tip, KERI-valid; no head changes
- F4 admit (state, group action) : Option State — none = refused, nothing stored
- F5 step (state, operation) : State — applies F2/F3/F4, unchanged on refusal
- F6 Reachable (state) : Prop — reflexive-transitive closure of F5 from the empty state
- F7 members / admins (chain) : finite sets (or lists) of identifiers — replay of core payloads
- F8 membershipOk (chain, action) : Bool/Prop — R6 rules incl. last-admin guard
All functions are parameterised by the D5 assumptions structure. Decidable where used by T0's
evaluated trace.
