# Functions — 42 (new or changed signatures only)

Custody (`KelGroups.Client.Custody`):
- F1 `type DeviceStore = { load :: Effect (Maybe String), save :: String -> Effect Unit, clear :: Effect Unit }`
- F2 `memoryDeviceStore :: Effect DeviceStore` · `localDeviceStore :: Effect DeviceStore`
- F3 `incept :: Transport -> DeviceStore -> Aff (Either CustodyRefusal Backup)` (R1, R3–R6)
- F4 `parseBackup :: String -> Either CustodyRefusal Backup` · `exportBackup :: Backup -> String`
- F5 `rotate :: Transport -> DeviceStore -> Backup -> Aff (Either CustodyRefusal Backup)`
  (argument = the imported backup, result = the new one; R2–R7)
- F6 `deviceSigner :: DeviceStore -> Effect (Maybe Signer)` (the device record as a #41 `Signer`)

Sync / Api:
- F7 `type Transport = { getIndex, getKel, postAction, postKel :: String -> Aff Response }`
- F8 `act :: Transport -> Aff (Maybe Signer) -> GroupView -> Payload -> Aff (Either SyncRefusal Submission)`
  (signer read before every signing round; `Nothing` = `NoDeviceKey`, nothing sent)
- F9 `httpTransport :: String -> Transport` (adds `postKel` = `POST /kel`)

Representation of `Backup` and `CustodyRefusal` (D2, D4) is the commit owner's within the data
model.
