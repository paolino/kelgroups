# Data — 42

- D1 Device record (in the device store, a string): the prefix and the current key as a
  private JWK (`KelGroups.Client.Jwk`). Nothing else: no next key, no KEL, no group state. At most
  one per device store. Absent = no identity on this device.
- D2 Next-key backup (a file the user keeps apart from the device): the prefix and the next key
  as a private JWK. Nothing else; never the current key. Import validates the JWK fully
  (`parseJwkJson` rules) and the prefix field; errors never contain key material.
- D3 Device store: load, save and clear of the one device record string. Instances: in memory
  (tests) and `window.localStorage` under one fixed key (browser). Unencrypted (#10).
- D4 Custody outcome and refusals. Done = the new backup (D2) to export, the device record
  written. Refusals, with the device store unchanged:
  `BadBackup` (malformed document) · `NotCommitted` (the backup key is not the committed next key
  of the hosted, validated KEL) · `KelRefused {refusal}` (the hosted KEL fails `validateKel`, or
  its prefix differs) · `DeviceOccupied {prefix}` (inception on an occupied device, or rotation
  of another identity than the device's) · `Rejected {status, error}` (the server refused the
  event and the hosted KEL does not hold it) · `Undecided {...}` (no answer and the hosted KEL
  unreadable; carries the generated keys for export, R6). `SyncRefusal` (#41 D5) gains
  `NoDeviceKey` for `act` on an empty device.
- D5 Event shape (R1, R2): single key, `kt` = `nt` = 1, `n` = [commitment of the next public
  key], no witnesses, `c` = [], `a` = []; the rotation's `p` and `s` from the validated hosted
  KEL. Wire form is #41's `encodeSignedEvent`.
