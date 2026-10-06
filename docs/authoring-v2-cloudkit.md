# Authoring v2 CloudKit adapter

The native adapter lives in `Voxglass/App/Sync/CloudKitAuthoringV2Sync.swift` and uses the existing private container `iCloud.guru.parso.voxglass`. It syncs the independent authoring-v2 SQLite outbox into the per-user private zone `VGStudioAuthoringV2`. Existing Library records and `VGProductionStudioZone` remain unchanged.

Each authoring entity is one `VGAuthoringEntityV2` record whose record name is the entity UUID. Its fields are `protocolVersion` (Int64), `entityID` (String), `entityKind` (String), `payloadJSON` (String), `mutationID` (String), and `payloadSHA256` (String). CloudKit system fields, including the change tag, are archived with `encodeSystemFields(with:)` and stored with the local entity. New edits use the restored server record so CloudKit can enforce its normal change-tag conflict check. Save batches are explicitly atomic within the v2 zone. A conflict is fed through the local three-way reducer and queued for another save only when it has no unresolved field candidates; the adapter never adopts a server tag and blindly overwrites the server copy.

Remote records are committed through the no-echo inbox before the engine checkpoint is persisted. If applying a fetched page fails, the adapter retains the prior engine serialization so the page is fetched again after restart. The engine serialization, inbox, entity system fields, and outbox all live in SQLite; `UserDefaults` is not used. A CloudKit account switch pauses sends until a foreground synchronization call resumes under the new account state.

## Development schema and production promotion

The adapter creates the custom zone through `CKSyncEngine`. CloudKit creates the record type and fields in the Development schema the first time a v2 record is saved. No manual record data or Production record should be created in CloudKit Console.

After a signed development build has written and read back a v2 project on two devices:

1. Open [CloudKit Console](https://icloud.developer.apple.com/) and select `iCloud.guru.parso.voxglass`.
2. Choose **Development** and inspect **Schema → Record Types → VGAuthoringEntityV2**. Verify the six fields above and check that `VGStudioAuthoringV2` is a private custom zone created by the app.
3. Use **Deploy Schema Changes** to promote the tested additive schema to **Production**. Review the displayed changes before deploying. Schema promotion does not copy Development records.
4. Do not use **Reset Environment**. Do not create a record type named `VGStudioAuthoringV2`; that is the zone name.

Production promotion is intentionally a later release action. The v2 path is not enabled by existing app startup or old releases; integration into project mutation/privacy-consent flows and live two-device validation are still release gates. Until those gates pass, keep the Production schema unchanged.

## Verification status

The Linux host cannot run Xcode or Swift locally. GitHub Actions is the platform build/test authority. The store tests exercise engine-state checkpoint persistence, full-system-field byte retention, outbox acknowledgment, remote apply, and transaction rollback. The Xcode CI job compiles the iOS, watchOS, and native macOS targets; a signed, live CloudKit two-device test is still required to validate CloudKit runtime behavior and the Development schema.
