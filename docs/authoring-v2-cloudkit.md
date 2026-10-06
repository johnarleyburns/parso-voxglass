# Authoring v2 CloudKit adapter

The native adapter lives in `Voxglass/App/Sync/CloudKitAuthoringV2Sync.swift` and uses the existing private container `iCloud.guru.parso.voxglass`. It syncs the independent authoring-v2 SQLite outbox into the per-user private zone `VGStudioAuthoringV2`. Existing Library records and `VGProductionStudioZone` remain unchanged.

Each authoring entity is one `VGAuthoringEntityV2` record whose record name is the entity UUID. Its fields are `protocolVersion` (Int64), `entityID` (String), `entityKind` (String), `payloadJSON` (String), `mutationID` (String), and `payloadSHA256` (String). CloudKit system fields, including the change tag, are archived with `encodeSystemFields(with:)` and stored with the local entity. New edits use the restored server record so CloudKit can enforce its normal change-tag conflict check. Save batches are explicitly atomic within the v2 zone. A conflict is fed through the local three-way reducer and queued for another save only when it has no unresolved field candidates; the adapter never adopts a server tag and blindly overwrites the server copy.

Remote records are committed through the no-echo inbox before the engine checkpoint is persisted. If applying a fetched page fails, the adapter retains the prior engine serialization so the page is fetched again after restart. The engine serialization, inbox, entity system fields, and outbox all live in SQLite; `UserDefaults` is not used. A CloudKit account switch pauses sends until a foreground synchronization call resumes under the new account state.

## Development schema and production promotion

The phone exposes this adapter under **Settings → Sync → Sync narration projects**. It is off by default and requires an explicit confirmation. It uploads project metadata and chapter/script structure to the user's private database; recording audio, source files, and artwork bytes remain on each device. New projects, edits, and deletions are queued locally and sent on foreground sync. Remote authoring edits are applied to the local project while preserving local takes.

The adapter creates `VGStudioAuthoringV2` through `CKSyncEngine`. CloudKit can create the record type and fields automatically in Development when the app first saves a record. **TestFlight uses the Production CloudKit environment**, where new record types and fields cannot be created by the app. Therefore, create and deploy the additive schema before turning on this feature in a TestFlight build ([Apple: CloudKit containers and environments](https://developer.apple.com/documentation/cloudkit/ckcontainer), [Apple: deploying a CloudKit schema](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema)). No record data needs to be created in CloudKit Console.

To prepare the schema for the TestFlight two-device test:

1. Open [CloudKit Console](https://icloud.developer.apple.com/) and select `iCloud.guru.parso.voxglass`.
2. Choose **Development** and inspect **Schema → Record Types → VGAuthoringEntityV2**. Verify the six fields above and check that `VGStudioAuthoringV2` is a private custom zone created by the app.
3. Use **Deploy Schema Changes** to promote the additive schema to **Production**. Review the displayed changes before deploying. Schema promotion does not copy Development records.
4. Do not use **Reset Environment**. Do not create a record type named `VGStudioAuthoringV2`; that is the zone name.

After deploying the schema and installing the next TestFlight build on two devices signed into the same Apple Account, enable **Sync narration projects** on one device and allow the first sync to finish. Check the private Production database for records in the `VGStudioAuthoringV2` zone, then make a title or script edit on one device and use **Sync Narration Projects Now** on the other. Start with sequential edits; simultaneous changes to the same field are recorded as unresolved conflicts and do not yet have an in-app resolution screen. Confirm the text update arrives and each device retains its own locally stored recording assets. Use a throwaway project until this passes.

## Verification status

The Linux host cannot run Xcode or Swift locally. GitHub Actions is the platform build/test authority. The store tests exercise engine-state checkpoint persistence, full-system-field byte retention, outbox acknowledgment, remote apply, conflict merging, and transaction rollback. The Xcode CI job compiles the iOS, watchOS, and native macOS targets. A signed two-device TestFlight run against Production is still required to validate CloudKit runtime behavior after the schema has been deployed.
