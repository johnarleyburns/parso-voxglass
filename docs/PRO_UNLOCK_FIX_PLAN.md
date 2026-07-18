# Fix Plan: Pro purchase succeeds but paywall stays up and features stay locked

Status: ready for implementation. Written 2026-07-17 after a full investigation; all file/line
references verified against `main` at commit 616a013.

## Context

A StoreKit purchase on the Pro paywall completes successfully — the transaction is verified,
finished, `StoreManager.isPro` is set true, and `EntitlementCache` (UserDefaults key
`voxglass.pro.entitlement`) is written. Persistence is correct: everything unlocks after an app
relaunch. The bug is purely **UI observation**, with two root causes:

- **A — the paywall never reacts to success.** `ProPaywallView`
  (`Voxglass/Features/Settings/ProPaywallView.swift`) observes `StoreManager` via `@StateObject`
  but its body never reads `isPro`: no success state, no `.onChange` → `dismiss()`. After purchase
  the sheet stays open still showing "Unlock Pro — $7.99".
- **B — feature gates read a non-observable cache.** Every UI gate calls
  `ProFeature.isEnabled(_:)` → `EntitlementCache.shared.isEntitled`
  (`Voxglass/Core/Services/Pro/ProFeature.swift:13-15`), a plain NSLock-guarded property with no
  publisher. SwiftUI has no dependency edge, so lock badges and gated rows never re-render until
  views are rebuilt. `Voxglass/Features/Library/LibraryView.swift:119` has the same defect via a
  bare `StoreManager.shared.isPro` read inside a computed property.

Ruled out during investigation: product-ID mismatch (`guru.parso.voxglass.pro` matches
`Voxglass/Resources/Pro.storekit`), product-type mismatch (nonConsumable both sides), missing
`transaction.finish()` (called in `StoreManager.verifyAndCache`), missing `Transaction.updates`
listener (started in `StoreManager.init`).

## Hard constraints

- `scripts/guard_wiring.sh` Rule 4 and `VoxglassTests` `ProPaywallContentTests` grep for the
  **literal string** `ProFeature.isEnabled(.caseName)` per advertised feature. Every existing gate
  expression must stay verbatim. Note `.listeningStats` has its only non-Settings literal at
  `Voxglass/Features/Stats/ListeningStatsView.swift:35` — do not remove it.
- The DEBUG test seam (`-VoxglassForcePro` / `-VoxglassForceFreeTier` launch args,
  `EntitlementCache.setTestEntitlement`) must keep working — it routes through
  `EntitlementCache.isEntitled`, which is another reason to keep gates reading
  `ProFeature.isEnabled`.
- Rule 5: no bare `.font(.system(size:))` — use `scaledFont`. Rules 6/7: new files require a
  `project.yml` change + `xcodegen generate` + committing the regenerated project.
- CI runs Linux `swift test` only; simulator tests are a local-only gate (`scripts/test.sh`).

## Approach

Keep every `ProFeature.isEnabled(...)` call site untouched; add
`@ObservedObject private var storeManager = StoreManager.shared` to each gated SwiftUI view so
`isPro` publishing invalidates the body, which then re-reads the (already-updated) cache.
`StoreManager` is `@MainActor` and every runtime entitlement mutation flows through it in lockstep
with the cache, so it is the single observable source. This was chosen over (a) making
`EntitlementCache` observable (thread-marshaling complexity, duplicate observable source of truth)
and (b) rewriting UI gates to `storeManager.isPro` (breaks Rule 4 literals, bypasses the DEBUG
override). `@ObservedObject` — not `@StateObject` — is correct for the externally-owned singleton,
and it triggers invalidation on `objectWillChange` even when body doesn't read the property.

## Edits

### 1. `Voxglass/Core/Services/Pro/StoreManager.swift` — write-order hardening
In `purchase(_:)` (currently lines 42-45) and `observeTransactionUpdates()` (lines 107-109), write
`EntitlementCache.shared.cacheEntitlement(true, productID: ...)` **before** setting `isPro = true`,
so observers re-rendering on the publish read a fresh cache. (`refreshEntitlement()` already has
this order.)

### 2. `Voxglass/Features/Settings/ProPaywallView.swift` — success state + auto-dismiss
- In `purchaseSection`, branch on `storeManager.isPro`: when true, replace the buy/restore buttons
  with a success block — `checkmark.seal.fill` in `Palette.brass`, "Pro Unlocked" text (use
  `scaledFont`), a "Continue" button calling `dismiss()`, and
  `.accessibilityIdentifier("paywall.success")`.
- Add to the outer `ZStack` (iOS 17 two-parameter form):
  ```swift
  .onChange(of: storeManager.isPro) { _, isPro in
      guard isPro else { return }
      Task { try? await Task.sleep(for: .seconds(1.2)); dismiss() }
  }
  ```
- The paywall is only reachable when not entitled (`VoxglassProRow` no-ops the tap when Pro; lock
  badges only render when locked), so this branch is purely the post-purchase/restore path.
- Do not touch the `static let advertised` array — `ProPaywallContentTests` regex-parses it.

### 3. `Voxglass/DesignSystem/VoxglassComponents.swift` — `ProLockedModifier` (line 478)
Add `@ObservedObject private var storeManager = StoreManager.shared` to the modifier struct. Body
stays `if ProFeature.isEnabled(feature)` verbatim. This fixes every `.proLocked(...)` lock badge,
current and future.

### 4. `Voxglass/Features/Settings/SettingsView.swift` — observer in each gated struct
Add `@ObservedObject private var storeManager = StoreManager.shared` to exactly these private
structs (each reads `ProFeature.isEnabled` in body and lacks observation today):
- `CacheSettingsCard` (:272; gate at :357)
- `SyncSettingsCard` (:652; gate at :658)
- `EQSettingsRow` (:739; gates at :746-766)
- `PrefetchDepthRow` (:777; gate at :785)
- `ListeningStatsRow` (:1015; gates at :1022-1038)
- `FolderWatchRow` (:1049; gate at :1054)

`VoxglassProRow` (:114) already observes via `@StateObject` — no change. Keep all
`ProFeature.isEnabled(...)` expressions and accessibility identifiers exactly as-is.

### 5. `Voxglass/Features/Library/LibraryView.swift`
Add `@ObservedObject private var storeManager = StoreManager.shared` to `LibraryView`; change
line 119 `if !StoreManager.shared.isPro` → `if !storeManager.isPro`. The free-pin meter then
disappears live on purchase.

### 6. `ListeningStatsView.swift`, `EQView.swift`, `NowPlayingView.swift`
Add the same `@ObservedObject` to `ListeningStatsView`, `EQView`, and `NowPlayingView`; keep gates
verbatim (`ListeningStatsView.swift:35` especially). In `ListeningStatsView`, change the `.task`
to `.task(id: storeManager.isPro)` so stats load after an in-place unlock (the once-per-appearance
`.task` won't re-fire otherwise).

### 7. Services — no changes (verified during investigation)
EQ taps are only created behind `.eq` gates at call time (`PlaybackCoordinator.swift:633-660`), so
no stale `eqStagesEnabled: false` engine can exist pre-purchase. CacheManager,
OfflineDownloadManager, FolderWatchService, VoxglassCloudSync, LibraryBackupService, and
PlaybackCoordinator all read entitlement per-action — correct as-is. CarPlay snapshots
`isDownloadsPro` per template rebuild; a purchase made on-phone shows on the next rebuild —
acceptable, note as a non-goal in the PR description.

## Tests

### Unit (`swift test`, runs in CI)
1. Extend `ProPaywallContentTests` (repo's source-parsing style): assert `ProPaywallView.swift`
   source contains `.onChange(of: storeManager.isPro` and `paywall.success`.
2. New drift guard (e.g. `ProGateObservationTests`, reusing the existing `appSourceContents()`
   helper pattern): for each `.swift` file under `Voxglass/Features` and `Voxglass/DesignSystem`
   containing `ProFeature.isEnabled(`, assert the file also contains `StoreManager.shared`. This
   prevents the bug class from recurring in new views.

### Local simulator UI test (local-only gate)
New `VoxglassProPurchaseUITests.swift` in `VoxglassUITests` using StoreKitTest:
```swift
session = try SKTestSession(configurationFileNamed: "Pro")
session.disableDialogs = true
session.clearTransactions()
```
Launch clean (existing splash/onboarding skip args; do **not** pass `-VoxglassForcePro` or
`-VoxglassForceFreeTier` — they would mask the real flow). Flow: More tab → Pro upsell →
"Unlock Pro" → wait for `paywall.success` → assert sheet dismisses → assert `settings.eq` exists,
`pro.lock.eq` gone, Pro row reads "Pro Unlocked". Requires adding `Pro.storekit` to the UI test
target in `project.yml` + `xcodegen generate` + committing the regenerated project (Rule 6).

### Manual verification recipe (simulator + `Voxglass/Resources/Pro.storekit`)
1. Xcode scheme → Run → Options → StoreKit Configuration → `Pro.storekit`. Delete the app from the
   simulator first (clears the cached UserDefaults entitlement), then run.
2. Start playing a book (to test mid-session unlock). Tap a lock badge (e.g. EQ on Now Playing) →
   paywall → "Unlock Pro" → confirm the StoreKit test purchase sheet.
3. Expect: "Pro Unlocked" success state, sheet auto-dismisses ~1s later, lock badges gone
   **without relaunch**; Settings shows "Pro Unlocked", 2 GB/10 GB cache presets, Listening Stats,
   Folder Watch, Sync, Backup all unlocked; My Books free-pin meter gone; EQ engages mid-session.
4. Debug → StoreKit → Manage Transactions → refund the purchase → background/foreground the app →
   features re-lock (via `Transaction.updates` → `refreshEntitlement`).
5. Relaunch with `-VoxglassForcePro`, then `-VoxglassForceFreeTier`, to confirm the DEBUG seam.

### Gates to run before commit
`scripts/guard_wiring.sh` (Rule 4 literals preserved, Rule 5 scaledFont, Rules 6/7 regenerated
project), `swift test`, `scripts/test.sh`, then the manual recipe.

## Sequencing
1. StoreManager write-order swap (isolated, safe).
2. ProPaywallView success state + auto-dismiss.
3. ProLockedModifier + the six SettingsView structs + LibraryView + the three feature views
   (including `task(id:)` in ListeningStatsView).
4. Tests + `project.yml`/xcodegen for the new UI-test file.
5. Run all gates and the manual recipe.
