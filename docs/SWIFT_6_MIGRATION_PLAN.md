# Voxglass Swift 6 Migration Plan

## Goal

Move every source target in the Swift package and Xcode project to Swift 6
language mode with complete concurrency checking. The migration is complete
only when the iPhone app, watch app, test bundles, command-line tools, package
tests, performance tests, and Release archive all build in Swift 6 with no
unexplained concurrency escape hatch or repository-owned compiler warning.

This is a source and build-configuration migration. It must not change the
SQLite schema, CloudKit records, WatchConnectivity payloads, export formats,
entitlements, deployment targets, or user-visible behavior.

## Current State

The repository is intentionally mixed-mode today:

| Target | Current language mode | Migration action |
| --- | --- | --- |
| `VoxglassCore` | Swift 5 with upcoming `StrictConcurrency` | Switch to Swift 6 and remove the now-redundant upcoming-feature flag |
| `VoxglassCoreTests` | Swift 5 | Switch to Swift 6 and repair test isolation |
| `VoxglassPerformanceTests` | Swift 5 | Switch to Swift 6 without weakening timing gates |
| `VoxglassEncoders` | Swift 6 | Keep Swift 6 and include in the final audit |
| `VoxglassCoreTestSupport` | Swift 6 | Keep Swift 6; remove avoidable unsafe sendability in fakes |
| `VoxglassRing` | Package default under tools 6.0 | Declare Swift 6 explicitly |
| `collection-counts` / `curated-lists` | Package default under tools 6.0 | Declare Swift 6 explicitly |
| `Voxglass` iPhone app | `SWIFT_VERSION = 5.0` | Switch generated Xcode configuration to 6.0 |
| `VoxglassWatch` | `SWIFT_VERSION = 5.0` | Switch generated Xcode configuration to 6.0 |
| `VoxglassUITests` | Inherits Swift 5 | Switch to Swift 6 |
| `VoxglassWatchUITests` | Inherits Swift 5 | Switch to Swift 6 |
| `VoxglassCarPlaySmokeTests` | Inherits Swift 5 | Switch to Swift 6 |

The package already declares `// swift-tools-version: 6.0`; the remaining
package pins are in `Package.swift`. XcodeGen's `project.yml` is the source of
truth for app and test targets and currently sets `SWIFT_VERSION: "5.0"` at the
project level. `Voxglass.xcodeproj` must be regenerated, never hand-edited.

The initial source audit found two `nonisolated(unsafe)` state holders, five
`MainActor.assumeIsolated` notification callbacks, and 24
`@unchecked Sendable` conformances. Some production conformances protect state
with locks or serialize access through SQLite and may remain valid; mutable test
fakes and UI/framework adapters should generally move to explicit actor or lock
ownership instead.

## Migration Rules

- Keep Xcode 16+/Swift 6.0 as the minimum supported toolchain contract even
  when development uses a newer Swift 6 compiler.
- Keep iOS 17, watchOS 10, and macOS 14 deployment targets unchanged.
- Use explicit actor ownership and Sendable value snapshots. Do not silence a
  diagnostic by adding `@unchecked Sendable`, `nonisolated(unsafe)`,
  `MainActor.assumeIsolated`, or broad `@preconcurrency` imports.
- Retain an existing `@unchecked Sendable` conformance only when all mutable
  state is demonstrably protected by a lock, actor, serial executor, or
  immutable-after-init invariant. Add a nearby invariant comment and a focused
  race/serialization test.
- Use `@preconcurrency import` only for a specific Apple framework whose
  annotations remain incomplete after owned code is correctly isolated. Record
  the framework and removal condition next to the import.
- Do not enable global default main-actor isolation. The core contains real
  background parsing, audio, storage, rendering, and sync work; isolation must
  describe actual ownership instead of moving all work onto the UI actor.
- Preserve serialized test execution and the existing opt-in performance-test
  environment because those constraints are independent of language mode.

## Implementation

### 1. Establish the Swift 6 diagnostic baseline

- Add a repository guard that fails if `Package.swift` contains
  `.swiftLanguageMode(.v5)`, if `project.yml` contains a Swift version below
  6.0, or if the generated project contains `SWIFT_VERSION = 5.0`.
- Capture clean SwiftPM, iPhone, watch, and Release build logs before editing.
  Group diagnostics by ownership boundary rather than fixing whichever file is
  first in compiler order.
- Record every existing unsafe annotation in an audit table with one disposition:
  remove, replace with actor isolation, replace with synchronization, or retain
  with a proven invariant.
- Rebuild after each group because Swift 6 often reveals downstream errors only
  after an earlier isolation failure is resolved.

### 2. Move all SwiftPM targets to Swift 6

- In `Package.swift`, explicitly apply `.swiftLanguageMode(.v6)` to every source,
  executable, support, and test target. Remove `.swiftLanguageMode(.v5)` and
  `.enableUpcomingFeature("StrictConcurrency")`; Swift 6 provides complete
  checking directly.
- Migrate `VoxglassCore` first so its public actor and Sendable contracts are
  stable before repairing callers and tests.
- Keep pure models, events, commands, parser output, sync envelopes, and export
  state as immutable `Sendable` values.
- Keep UI-facing repositories, playback coordination, CloudKit coordinators,
  and stores on their existing explicit actors. Add actor annotations to
  protocols when all conformers share that ownership instead of annotating
  individual calls inconsistently.
- For background audio, parsing, rendering, sync, and SQLite work, pass Sendable
  inputs into isolated workers and return Sendable results. Never send a
  framework object, mutable class graph, database handle, or callback-owned
  buffer across an actor boundary.

### 3. Repair framework and lifecycle boundaries

- Replace the `SystemPlaybackBridge` notification closures that use
  `MainActor.assumeIsolated` with callbacks that enqueue a main-actor task. Do
  not assume NotificationCenter delivery remains on the registering thread.
- Make the `NarrationFlow` observation task actor-owned and remove its
  `nonisolated(unsafe)` storage. Cancellation and replacement must occur on the
  same actor as the flow.
- Replace the global unsafe fixture seed with a lock-protected deterministic
  generator or an actor-local generator that remains reproducible under serial
  and targeted test execution.
- Audit AVFoundation, AudioToolbox, CarPlay, CloudKit, StoreKit,
  WatchConnectivity, URLSession, XMLParser, and app/watch lifecycle delegates.
  Each nonisolated delegate callback must copy the minimum Sendable data and
  then enter the owner actor before reading or mutating app state.
- Add `@Sendable` and global-actor annotations to callback types at protocol
  boundaries so implementations and tests receive the same compiler contract.
  Avoid heterogeneous dictionaries outside the immediate serialization layer.

### 4. Audit unsafe Sendable conformances

Handle the existing annotations by category:

- **Mutable test fakes:** Convert fetchers, transports, ID generators, license
  providers, capture fakes, and segment-player fakes to actors or protect their
  scripted state with a test synchronization helper. Tests must use async access
  rather than unsafely reading mutable properties.
- **UI/framework services:** Main-actor isolate artwork, StoreKit, audio-session,
  UI-test capture, and similar services when their framework contract is
  UI-thread-bound. For delegate-only helper objects, keep a Sendable immutable
  handoff closure and no unsynchronized mutable state.
- **Storage and sync infrastructure:** Review SQLite stores/repositories,
  CloudKit cache boxes, phone sync core, export recorders, ring buffers, and
  rendering counters individually. Preserve `@unchecked Sendable` only where
  the implementation already has complete synchronization; document the
  invariant and add contention tests suitable for Thread Sanitizer runs.
- **Test-only counters:** Replace ad hoc boxes with the same synchronization
  helper used by support fakes so tests model the production concurrency
  contract rather than bypassing it.

The final audit must find no `nonisolated(unsafe)` or
`MainActor.assumeIsolated`. Any remaining `@unchecked Sendable` or
`@preconcurrency` occurrence must appear in the documented audit table and have
focused verification.

### 5. Move every Xcode target to Swift 6

- Change the base setting in `project.yml` to `SWIFT_VERSION: "6.0"` and add
  `SWIFT_STRICT_CONCURRENCY: complete` so the checked-in configuration makes the
  intended policy explicit.
- Run `xcodegen generate --spec project.yml` and commit both `project.yml` and
  the generated `Voxglass.xcodeproj/project.pbxproj` changes. Verify the project
  diff contains only expected regeneration plus Swift 6 settings.
- Build the iPhone and watch schemes separately. Repair app, watch, UI-test, and
  CarPlay-smoke target errors with the same actor/value-boundary rules used in
  the package.
- Build Release as well as Debug. Whole-module optimization can expose
  diagnostics and generic sendability issues that do not appear in an
  incremental Debug build.

### 6. Make Swift 6 permanent in CI

- Extend the guarded-tests job with the language-mode guard and a checked-in
  XcodeGen drift check.
- Run SwiftPM logic and performance suites with Swift 6 exactly as today:
  serial logic tests first, then the opt-in timing suite.
- Keep the generic iOS and watch compile jobs. Add a Release archive without
  signing to pull the same compiler surface forward before the signed
  TestFlight job.
- Capture build logs and fail on warnings attributed to repository source,
  manifests, resources, scripts, or project settings. If Apple-generated code
  emits a toolchain warning that cannot be fixed in source, allowlist the exact
  diagnostic with Xcode version, rationale, and removal condition; do not use a
  broad warning suppression.

## Public Contract Changes

Swift 6 actor and Sendable annotations are source-visible contracts. During the
migration, expect these deliberate API changes:

- Protocols that represent UI-owned playback, library, StoreKit, CloudKit, and
  watch state may become `@MainActor`.
- Cross-actor closures gain `@Sendable`; UI callbacks gain `@MainActor` where
  appropriate.
- Mutable fake configuration and observation become async or actor-isolated.
- Value types passed through tasks, renderers, sync, and watch messages gain
  explicit `Sendable` conformance.

Do not change serialized field names, enum raw values, database schemas, file
paths, wire payloads, or public product behavior as part of these source-level
changes.

## Test Plan

Add focused tests alongside each ownership change:

- Delegate callbacks invoked from a background executor update observable state
  only after entering the expected actor.
- Notification-driven playback persistence and audio-route handling remain
  ordered and do not lose terminate/background events.
- Mutable fakes remain deterministic when accessed from concurrent tasks.
- SQLite stores, asset repositories, ring buffers, sync caches, export
  recorders, and render counters preserve their invariants under contention.
- Task cancellation for narration observation, download, rendering, sync, and
  export cannot mutate a replacement task's state.
- WatchConnectivity and CloudKit boundaries round-trip typed Sendable snapshots
  without changing their existing serialized representation.

Run the complete acceptance matrix from a clean checkout:

```sh
# Project generation and static guards
xcodegen generate --spec project.yml
git diff --exit-code Voxglass.xcodeproj
bash scripts/guard_wiring.sh
bash scripts/test_guards.sh
bash scripts/guard_production.sh

# SwiftPM logic and performance tests
swift test --no-parallel --skip VoxglassPerformanceTests
VOXGLASS_TIMING_TESTS=1 swift test --no-parallel \
  --filter VoxglassPerformanceTests

# Generic Debug builds
xcodebuild build -project Voxglass.xcodeproj -scheme Voxglass \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project Voxglass.xcodeproj -scheme VoxglassWatch \
  -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO

# Existing local iPhone/watch smoke tests
bash scripts/test.sh --all

# Unsigned Release archive/build coverage
xcodebuild archive -project Voxglass.xcodeproj -scheme Voxglass \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath /tmp/Voxglass-Swift6.xcarchive CODE_SIGNING_ALLOWED=NO
```

Run the relevant schemes with Thread Sanitizer during development for retained
lock-backed `@unchecked Sendable` types. Sanitizer runs supplement the normal CI
matrix; they do not replace deterministic synchronization tests.

## Acceptance Criteria

- `rg 'swiftLanguageMode\(.v5\)|SWIFT_VERSION[ =:]+[" ]?5' Package.swift project.yml Voxglass.xcodeproj`
  returns no match.
- Every package and Xcode target compiles in Swift 6 language mode with complete
  concurrency checking.
- SwiftPM logic tests, performance tests, guarded tests, iPhone smoke, watch
  smoke, generic Debug builds, and the Release archive all pass.
- Clean logs contain no repository-owned warning.
- No `nonisolated(unsafe)` or `MainActor.assumeIsolated` remains.
- Every retained `@unchecked Sendable` or `@preconcurrency` use is documented,
  narrowly scoped, and backed by a synchronization or boundary test.
- XcodeGen regeneration is clean and CI rejects future Swift 5 settings.
- No persistence, CloudKit, watch wire-format, export-format, entitlement,
  deployment-target, or user-visible behavior change is included.

## Delivery and Rollback

Implement on a dedicated migration branch in reviewable commits: diagnostic
guard, package/core migration, framework-boundary fixes, test-support migration,
Xcode target switch, then CI/documentation. Keep the branch green at each
commit, but merge it as one coordinated migration after the complete acceptance
matrix passes.

Because this migration has no data-model or wire-format change, rollback is a
revert of the migration merge. Do not partially roll individual targets back to
Swift 5; mixed language modes are the current transitional state and are not an
acceptable post-migration fallback.
