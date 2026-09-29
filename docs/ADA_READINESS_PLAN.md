# Voxglass — Apple Design Award Readiness Plan

**Mockups (visual contract):** [`docs/mockups/ada-readiness.html`](mockups/ada-readiness.html). Open it straight
from disk. Where a mockup element has an HTML `id`, that `id` **is** the `.accessibilityIdentifier` you must use.

**Written:** 2026-09-28. Line numbers are as of commit `ac3d694`. If a line number has drifted, search for the quoted
code; the quote wins over the number.

**Scope:** the six items from the 2026-09-28 ADA review:

| # | Item | Phase ids | Size |
|---|---|---|---|
| 1 | Remove every trace of the retired paid tier from the UI | **P1** | hours |
| 2 | Layered Liquid Glass app icon (Icon Composer `.icon`) | **I1–I2** | days (owner-gated) |
| 3 | Accessibility: type scale, contrast, VoiceOver, audits | **A1–A5** | 1–2 weeks |
| 4 | Full localization (Tier 1 + Tier 2 incl. Hebrew RTL) | **L0–L6** | 2–4 weeks |
| 5 | Live Activity, Dynamic Island, widget redesign, controls | **W1–W4** | 1–2 weeks |
| 6 | Narrate refocused on LibriVox volunteering + motion/haptics polish | **N1–N2, M1–M2** | 1 week |

Out of scope (do not touch): iPad-specific listening layouts, light mode, the Mac app's UI, CarPlay, StoreKit
product configuration, and anything in `docs/RELEASE_PLAN.md`'s resume/position machinery.

### 0.7 Owner amendment: LibriVox-only narration publishing

The narration product has one built-in submission path: **LibriVox**. A completed narration may also be exported to
**Personal Listening** as a local preview before the narrator submits it. Remove the Internet Archive and commercial /
ACX narration publishing paths from the narration UI, validation flow, export routing, completion actions, and related
smoke coverage. Do not remove unrelated Core destination compatibility needed to decode existing persisted projects;
legacy projects must remain readable, but they must not expose those destinations as new narration choices.

---

## 0. Agent brief: read this first

You are a coding agent executing a decided plan in an existing Swift 6 / SwiftUI repository. The decisions are made.
Your job is to implement them phase by phase **without re-deriving or re-opening them**.

### 0.1 Execution order (not the same as item numbering)

Strings must be final before they are extracted for translation, and fonts must be migrated before layouts are
checked in long languages. Run the phases in this order:

```
P1 → N1 → N2 → A1 → A2 → A3 → A4 → A5 → W1 → W2 → W3 → W4 → M1 → M2 → L0 → L1 → L2 → L3 → L4 → L5 → L6
I1 and I2 are owner-gated and can run at any point (see §2).
```

### 0.2 Working method

- **One phase = one commit.** Use an imperative subject with a conventional prefix (`fix:`, `feat:`, `a11y:`, `l10n:`,
  `chore:`). The body names the phase id and the acceptance criteria it meets. End every commit message with:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` (or your own model's attribution line if the harness
  gives you one).
- **Stop after each phase and report**: what changed, which gates passed, and any decision you had to make. Do not
  chain phases unless the owner explicitly tells you to run several.
- If a phase's acceptance criteria cannot be met, **stop and report**. Do not weaken a test, do not raise a budget, do
  not mark the phase done.
- **When this plan and the repository disagree on a fact** (a path, a type name, a line), the repository wins; report the
  discrepancy. **When they disagree on intent**, this plan wins. Never pick one silently.

### 0.3 Gates (run before every commit)

```sh
swift test                      # host logic + source-level tests (VoxglassTests); also the pre-commit hook
scripts/guard_production.sh     # grep gates (runs on Linux CI)
scripts/test_guards.sh          # proves every gate can fail: every NEW gate needs a probe here
scripts/guard_wiring.sh
scripts/check-swift6.sh
```

- `git commit` runs `swift test` in a hook. Use a **600 s timeout** for `git commit` and 120 s for `git push`.
  **Do not push** unless the owner asks.
- Before starting any test, build or commit, run `ps aux | grep -E "swift-test|swift-build|xcodebuild" | grep -v grep`.
  If a run is already going, wait for it to finish. Never run two at once against this checkout.

### 0.4 Devices: physical first, no simulators

- **Never boot, build for, or test on a simulator** unless the owner explicitly asks in the current session. The UI
  smoke suite (`scripts/test.sh`) is simulator-based, so **the owner runs it**, not you. You may compile the UI test
  bundles without running them:
  ```sh
  xcodebuild build-for-testing -scheme Voxglass \
    -destination 'generic/platform=iOS' -derivedDataPath /tmp/voxglass-bft
  ```
- To build for the device, find it with `xcrun devicectl list devices`, then:
  ```sh
  xcodebuild -scheme Voxglass -destination 'platform=iOS,id=<UDID>' \
    -derivedDataPath /tmp/voxglass-device build
  ```
  If no physical device is connected, **stop and report**. Do not fall back to a simulator.
- **Never pass `-sdk`** to `xcodebuild` for the `Voxglass` scheme; it embeds the Watch app (see `CLAUDE.md`).
- Anything visual (lock screen, Dynamic Island, VoiceOver, icon rendering) is verified by the **owner on device**
  using the walk-throughs in §9. Your report must list which of those walks each phase needs.

### 0.5 Repository conventions (non-negotiable)

- **XcodeGen.** Edit `project.yml`, then run `xcodegen generate`. Never hand-edit `Voxglass.xcodeproj`.
- **Swift 6, strict concurrency.** No `@preconcurrency`, `nonisolated(unsafe)` or `@unchecked Sendable` without a
  one-line justification comment. `scripts/check-swift6.sh` must pass.
- **`@Observable` only.** `ObservableObject` in new code fails gate `check_no_observable_object`.
- **Core stays platform-free.** `Voxglass/Core/**` must not import ActivityKit, WidgetKit, UIKit, AppIntents or
  StoreKit (gate `check_core_platform_free`). Platform code lives in `Voxglass/App/**`, `Voxglass/Features/**`,
  `VoxglassWidgets/**`, or the new shared folder `VoxglassShared/**` (added in W1).
- **One UI smoke test per device.** Extend `testAppBootsVisitsAllTabsEQAndProductions` with private helper legs. Never
  add a new UI test function or target. The phone leg must stay under about 8 minutes.
- **Brass budget.** `scripts/brass_budget.txt` (currently `321`) caps `Palette.brass` / `VoxglassTheme.accent`
  references in Features + DesignSystem. Do not raise it. If a phase needs more brass, remove brass somewhere else,
  or stop and report.
- **Never lose playback position.** No phase may add a second writer to `PositionStore`. Every playback mutation
  goes through `PlaybackCoordinator`.
- **No silent background work** (`CLAUDE.md`). Live Activities and widgets must reflect real current state. A Live
  Activity must never show "playing" when nothing is playing.
- 4-space indent. `///` on every `public` symbol. No force-unwraps outside tests. `// MARK: -` in files over about
  150 lines.

### 0.6 New gate numbering

The existing ADA-series gates in `scripts/guard_production.sh` are G-A1…G-A6. New gates continue from **G-A7**. Each
new grep gate gets:
1. a `check_ada_*` function;
2. a call in the "Run all checks" list;
3. a planted probe in `scripts/test_guards.sh` that proves it can fail.

Source-level checks that need multi-line parsing go in Swift Testing suites under `VoxglassTests/` (the pattern used by
`DynamicTypeGuardTests` and `LicenseGatePlacementTests`).

---

## 1. Item 1: remove the retired paid tier (P1)

### 1.1 Why

Since 2026-09-09 nothing is gated: `NarrationProStore` hands `StaticLicenseProvider(.pro)` to every call site
(`current_status.md`). The UI still sells "Pro", though. A juror who sees a "Pro" chip in an app that says it is free
reads it as unfinished or dishonest. This is the cheapest credibility fix in the plan.

### 1.2 Verified inventory (at `ac3d694`)

| Location | What is there | Action |
|---|---|---|
| `Voxglass/Features/Settings/SettingsView.swift:777` | `Text("Voxglass Pro is a one-time purchase. …")` | **Delete** the Text and its modifiers. Put the mission line from the mockup in its place (id `settings.about.mission`). |
| `SettingsView.swift`: the sync section titled "Bookmarks & Favorites Sync" | legacy Pro-era title | Rename to **"iCloud Sync"**. Keep the body text. |
| `Voxglass/Features/Production/ProPurchaseView.swift` (whole file) | purchase / restore / price UI | **Delete the file.** Replace it with `ExportFormatsView.swift` (see 1.3). |
| `NarrationFlow.swift:3165, 3192, 3214–3216` | `showProDetails` + "See what Pro includes" button (`help.proDetails`) | Delete the button, the state and the sheet. |
| `NarrationFlow.swift:3285, 3340, 3366–3368` | "Learn about export formats" opens `ProPurchaseView` | Keep the button. Make it open `ExportFormatsView`. Rename the state to `showExportFormats`. Button id `import.exportFormats`. |
| `NarrationFlow.swift:3431–3441` | "Commercial release" row with `proChip: true` and the "Delivered with Voxglass Narration Pro…" hint | Remove `proChip` and the hint. The row moves under "More destinations" in **N1**; P1 only removes the chip and hint. |
| `NarrationFlow.swift:3448–3470` | `destinationRow(…, proChip:)` and the chip view | Delete the `proChip` parameter and the chip view. |
| `NarrationFlow.swift:697–698` | blocker "Narration Pro required" | Delete the branch. It is unreachable because the provider is pinned to `.pro`. |
| `NarrationFlow.swift:2816` | `exportError = "Commercial retail export is a Voxglass Narration Pro feature."` | Delete the branch (unreachable). |
| `NarrationFlowScreens.swift:1793` | `destinationRow(.acx, …, proChip: true)` | Remove `proChip:`. |
| `NarrationFlowScreens.swift:1853–1857` | `.sheet(isPresented: $showProPurchase) { ProPurchaseView(…) }` | Delete the sheet and `showProPurchase`, plus any button that set it. Run `grep -n showProPurchase` to find them. |
| `NarrationFlowScreens.swift:2083–2106` | second `destinationRow(…, proChip:)` with chip | Delete the parameter and the chip view. `let unlocked = …` becomes unconditional `true`. Delete any locked-state styling. |
| `VoxglassUITests/VoxglassUITests.swift:1099–1106` | `testNarrationProDetailsAreVisibleFromImport` | **Delete the test function.** It tests removed UI, and it breaks the one-test-per-device rule anyway. |
| `VoxglassTests/Production/License/LicenseGateTests.swift:163` | `"Features/Production/ProPurchaseView.swift"` in `permittedPaths` | Remove the entry. |

Run `grep -rn "proDetails\|ProPurchase\|proChip\|showPro" Voxglass VoxglassUITests VoxglassTests` after the edits. The
only hits allowed are inside the `LicenseGatePlacementTests` doc comment, which you should also update.

**Do not remove** `LicenseGate`, `NarrationProStore`, `StaticLicenseProvider`, `StoreKitLicenseProvider`, the StoreKit
config, or `isProUnlocked`. The plumbing stays, pinned to `.pro`. This phase removes *copy and UI*, not architecture.
`SupportDevelopmentStore` and the "Support" section of Settings stay as they are: a thank-you with no entitlement.

### 1.3 `ExportFormatsView` (new; replaces ProPurchaseView)

`Voxglass/Features/Production/ExportFormatsView.swift`. This is a read-only sheet: `NavigationStack`, title
"Export formats", a Done button, and a list of destinations with their formats. Carry these facts over from the
deleted file and the destination constants in `Voxglass/Core/Production/Destinations/`. Do not invent formats.

| Destination | Formats (read from `Destinations/` constants; do not hard-code numbers that disagree with them) |
|---|---|
| LibriVox | 128 kbps CBR mono MP3, 44.1 kHz, ID3 tags, per-section files |
| Personal Listening | Lossless WAV chapters for a local preview before submission |

Footer text: "Every format is free. Voxglass never charges for export." The sheet id is `formats.sheet` (see mockup
§A1).

### 1.4 New gate G-A7: no paid-tier copy

Add `check_ada_no_paid_tier_copy` to `guard_production.sh`. It scans **string literals** in `Voxglass/Features`,
`Voxglass/DesignSystem`, `Voxglass/App`, `VoxglassWidgets` and `VoxglassWatch` for:

```
"[^"]*\b(Pro|Upgrade|Unlock|one-time purchase|Restore purchase)\b[^"]*"
```

Lines containing `paid-copy-exempt:` are skipped. The Support section's "Contribute to Development" copy does not
match. If something legitimate does match (for example "Pro" as part of a word like "Project"), the `\b` word
boundaries already exclude it. Add a probe to `test_guards.sh`.

### 1.5 Acceptance (P1)

- [ ] `grep -rn '"Pro"\|Narration Pro\|Voxglass Pro' Voxglass VoxglassWatch VoxglassWidgets` returns nothing.
- [ ] `ProPurchaseView.swift` is gone; `ExportFormatsView.swift` exists and is reachable from the import screen.
- [ ] G-A7 passes and its probe fails as expected in `test_guards.sh`.
- [ ] `swift test` passes, including `LicenseGatePlacementTests`.
- [ ] `build-for-testing` compiles the UI test bundle.
- [ ] Owner walk §9.1 is listed in your report.

---

## 2. Item 2: layered Liquid Glass app icon (I1–I2)

### 2.1 Why

The current icon (`Voxglass/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`, generated by
`scripts/make_icon.py`) is a flat periodic-table tile: "23", "V", "Voxglass", "50.942" in Helvetica on a dark
gradient.

- It contains **words**, which the HIG advises against. They also become illegible at 29–60 pt.
- It has no depth layers, so it gets no Liquid Glass treatment and no designed dark, clear or tinted appearance.
- It doesn't use the brand brass at all.

The icon is the first thing an editor sees.

### 2.2 Decision

**Concept A, "Vox pane", is the recommendation** (mockup §B shows A, B and C in every appearance). It has three
layers:

1. **Background:** vertical gradient from `#241A10` to `#0A0B0D`. It matches `VoxglassTheme.warmBackground`, so the
   icon and the app's first screen feel continuous.
2. **Glass pane:** a rounded rectangle, about 62 % of the canvas, rotated −8°, with the Liquid Glass material enabled
   in Icon Composer. It represents the "glass" in the name.
3. **Voice mark:** seven vertical rounded bars in brass `#E3A44B` whose heights form a **V**: tall at both edges and
   shortest in the centre. It reads as a waveform first and a V second. There is no text.

Concepts B (an open book whose pages are waveforms) and C (the element tile without text) are alternatives if the owner
rejects A.

### 2.3 I1: agent-authored layer artwork (commit 1)

1. Create `design/icon/` containing `background.svg`, `pane.svg` and `mark.svg`, each 1024×1024 with a transparent
   canvas outside the shape. Use plain SVG (rect/path, no filters, no text, no embedded raster), because Icon Composer
   applies the glass, shadow and specular effects itself.
   - Mark geometry (exact): bars 56 px wide with a 28 px corner radius, and 36 px gaps. Seven bars fit in
     7×56 + 6×36 = 608 px, starting at x = 208. The bottoms all sit on y = 752. Heights are
     `[520, 400, 280, 184, 280, 400, 520]`. Fill: `#E3A44B`.
   - Pane: `rect x=192 y=192 w=640 h=640 rx=148`, `transform="rotate(-8 512 512)"`, fill `#FFFFFF`, opacity 0.18.
     Icon Composer replaces the fill with glass.
   - Background: a full-bleed `rect` with a `linearGradient` from `#241A10` (top) to `#0A0B0D` (bottom).
2. Add `design/icon/README.md` with the exact Icon Composer steps from §2.4, so the owner can follow them without this
   plan.
3. Delete nothing yet. Commit: `chore: add layered icon artwork for Icon Composer`.

**Stop here and report.** I2 needs the owner to produce `AppIcon.icon` in Icon Composer. It's a GUI tool with no
supported CLI; hand-written `icon.json` files are not a supported authoring path, so do not attempt one.

### 2.4 Owner step (about 20 minutes, in Icon Composer)

Open Icon Composer via Xcode ▸ Open Developer Tool ▸ Icon Composer, then:

1. New document. Drag in `background.svg`, then `pane.svg`, then `mark.svg`. Each becomes its own group, stacked from
   back to front.
2. **Background group:** Liquid Glass off. **Pane group:** Liquid Glass on, translucency about 50 %, shadow neutral.
   **Mark group:** Liquid Glass on, specular on.
3. Check the Default, Dark, Clear (light and dark) and Tinted previews. The mark must stay legible in Tinted. If it
   doesn't, set the mark's tinted appearance fill to white.
4. Check the watchOS circle preview (platforms: iOS, macOS, watchOS).
5. Save as `Voxglass/Resources/AppIcon.icon`.

### 2.5 I2: wire the `.icon` into every target (commit 2)

1. In `project.yml`, add `- path: Voxglass/Resources/AppIcon.icon` under `resources:` for **`Voxglass`** and
   **`VoxglassMac`**. VoxglassMac currently shares `Voxglass/Resources/Assets.xcassets`; see line ~279.
2. Delete `Voxglass/Resources/Assets.xcassets/AppIcon.appiconset/` with `git rm -r`. The `.icon` and the appiconset
   are both named `AppIcon`, and two icons with the same name break the asset compile.
   `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` stays unchanged.
3. Run `xcodegen generate`, then verify:
   `grep -n "AppIcon.icon" Voxglass.xcodeproj/project.pbxproj` must show `lastKnownFileType = folder.iconcomposer.icon`
   and membership in the Resources build phase of both targets. **If XcodeGen 2.46 classifies it as a plain folder,
   stop and report.** Do not hand-edit the pbxproj.
4. Update `scripts/audit_app_store_release.sh:123`. Replace the appiconset PNG check with:
   `require((root / "Voxglass/Resources/AppIcon.icon/icon.json").is_file(), "iOS/macOS app icon (.icon) is missing")`.
5. **Watch:** leave `VoxglassWatch/Resources/Assets.xcassets/AppIcon.appiconset` and `scripts/check_watch_app_icon.sh`
   unchanged in this phase. Moving the Watch to the `.icon` is a follow-up; list it in your report.
6. Replace `scripts/make_icon.py` with a note at the top saying it's superseded by `design/icon/` + `AppIcon.icon` and
   is kept only for history. Do not delete it, because the audit script history references it.
7. Verify on device: build for the connected iPhone, and build `VoxglassMac` for `platform=macOS`. Both must
   succeed. In the device build log, confirm that `actool` processed `AppIcon.icon`.

### 2.6 Acceptance (I1–I2)

- [ ] Three SVG layers in `design/icon/`, with no text elements (`grep -c "<text" design/icon/*.svg` is 0 for each file).
- [ ] `AppIcon.icon` is in the Voxglass and VoxglassMac resources, and the appiconset is gone from the shared catalog.
- [ ] The release audit passes with the new check.
- [ ] Owner walk §9.2 (Home Screen in default, dark, clear and tinted) is listed in your report.

---

## 3. Item 3: accessibility (A1–A5)

An audiobook app's core audience includes blind and low-vision listeners. The Inclusivity bar is "a VoiceOver user
prefers this app", not just "compliant".

### 3.1 A1: type scale migration

**Problem (verified).** `scaledFont(size:weight:design:)` (`Voxglass/DesignSystem/ScaledFontModifier.swift`) scales
every size `relativeTo: .body` from hard-coded base points. There are 657 call sites. Base sizes below Apple's 11 pt
minimum include 10 pt ×29, 10.5 ×7, 9 ×9, 8.5 ×2, 8 ×1 and 7 ×1. Because everything scales against `.body`, captions
and titles don't follow their own text-style curves. The token system `voxType(_:)` (`VoxglassType.swift`) already
uses text styles correctly but is used much less.

**Decision.** Replace every `scaledFont(size:…)` with a text-style API:

```swift
// Voxglass/DesignSystem/ScaledFontModifier.swift — add alongside the existing modifier
extension View {
    /// Dynamic Type font from a system text style. Use this for all UI text.
    func voxFont(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design? = nil) -> some View {
        font(.system(style, design: design, weight: weight))
    }
}
```

Keep `scaledFont(size:)` only for **display numerals of 34 pt and above** (splash, hero timers, stats). Each remaining
call must carry a `// type-exempt: <reason>` comment on the same line. Change its `relativeTo:` from `.body` to
`.largeTitle`.

**Mapping (mechanical; apply exactly):**

| Base `size:` | New style | Notes |
|---|---|---|
| < 11.75 (7 – 11.5) | `.caption2` | Anything under 11 pt grows to 11 pt. That is intended. |
| 11.75 – 12.74 | `.caption` | |
| 12.75 – 13.99 | `.footnote` | |
| 14 – 15.74 | `.subheadline` | |
| 15.75 – 16.49 | `.callout` | |
| 16.5 – 18.49 | `.body` | 18 → 17 is accepted. |
| 18.5 – 20.99 | `.title3` | |
| 21 – 24.99 | `.title2` | |
| 25 – 33.99 | `.title` | |
| ≥ 34 | `.largeTitle`, **or** keep `scaledFont` with `// type-exempt:` if it's a display numeral or splash wordmark | |

`weight:` and `design:` carry over unchanged.

**How to do it:** write `scripts/migrate_scaled_fonts.py`. It's a one-shot tool: commit it with the phase, then
delete it in the next commit. Its regex:
`\.scaledFont\(size:\s*([0-9.]+)(\s*,\s*weight:\s*[^,)]+)?(\s*,\s*design:\s*[^)]+)?\)`
Rewrite each match with the table above, skipping any line that already has `type-exempt:`. Print a per-file count.
Then review by hand every file in `Voxglass/Features/Production/Discovery/` (NarrationFlowScreens.swift alone has
167 sites). Check for fixed `.frame(width:)` / `.frame(height:)` next to text that now grows. Replace those with
`minHeight` / `@ScaledMetric` sizes, or let them grow.

**Layout rules while you're in these files:**
- Any `HStack` of text plus a trailing value that can truncate at accessibility sizes switches to a vertical layout.
  Use `ViewThatFits(in: .horizontal) { HStack {…}; VStack(alignment: .leading) {…} }`, or check
  `dynamicTypeSize.isAccessibilitySize`.
- Remove `.lineLimit(1)` from titles and descriptions. Keep it only on single-token things like timecodes or
  "Chapter 3" eyebrows, and mark those with `// lineLimit-exempt:`.
- Chips and pills (`Capsule()` backgrounds) must not use a fixed height.

**Gates:**
- **G-A8** (grep, `check_ada_type_scale`): `scaledFont(size:` without `type-exempt:` anywhere in
  `Voxglass/Features` or `Voxglass/DesignSystem`, except the modifier's own file, is a violation. Add a probe.
- Extend `VoxglassTests/DynamicTypeGuardTests.swift` with `noTypeExemptBelowDisplaySize`. Parse every
  `scaledFont(size: N` line that carries `type-exempt:` and require N ≥ 34.

**Acceptance (A1):** zero non-exempt `scaledFont(size:` calls; every exempt one is ≥ 34 pt; `swift test` and the gates
pass; device build succeeds; owner walk §9.3 (AX5 text size) is listed.

### 3.2 A2: contrast, hierarchy, Increase Contrast, color independence

**Problem (verified, computed with the WCAG 2.x formula):**

| Token | Value | Contrast on `#0A0B0D` |
|---|---|---|
| `Palette.ink2` (secondary) | `Color(white: 0.92).opacity(0.58)` → about `#8C8D8E` | about **5.9:1** |
| `Palette.ink3` (tertiary) | `#AEB2B8` | about **8.9:1** |

**Tertiary text is currently brighter than secondary text.** The hierarchy is inverted. There is also no Increase
Contrast variant anywhere: only six references to `colorSchemeContrast` / `reduceTransparency` exist in the whole app.

**Decision: new values.** They're specified once as platform-free hex so they can be unit-tested.

Create `Voxglass/Core/Design/PaletteSpec.swift` (Core; no SwiftUI import):

```swift
/// Hex values for the Voxglass palette in standard and Increase Contrast modes.
/// The app's `Palette` reads these; `PaletteContrastTests` proves each text
/// token meets WCAG AA on every surface in both modes.
public enum PaletteSpec {
    public struct Pair: Sendable { public let standard: UInt32; public let highContrast: UInt32 }
    public static let bg          = Pair(standard: 0x0A0B0D, highContrast: 0x000000)
    public static let surface     = Pair(standard: 0x17191D, highContrast: 0x101114)
    public static let raised      = Pair(standard: 0x1B1D22, highContrast: 0x141519)
    public static let ink         = Pair(standard: 0xF2F4F6, highContrast: 0xFFFFFF)
    public static let ink2        = Pair(standard: 0xC4C7CC, highContrast: 0xE6E8EB)   // ≈11.3:1 / ≈16:1
    public static let ink3        = Pair(standard: 0x8E9298, highContrast: 0xBFC3C8)   // ≈6.0:1 / ≈11:1
    public static let brass       = Pair(standard: 0xE3A44B, highContrast: 0xF2BE6E)
    public static let hairlineAlpha = (standard: 0.10, highContrast: 0.28)
    public static let surfaceLineAlpha = (standard: 0.08, highContrast: 0.24)
    /// WCAG 2.x relative luminance of an sRGB hex colour.
    public static func luminance(_ hex: UInt32) -> Double { … }
    /// WCAG 2.x contrast ratio between two opaque colours (≥ 1).
    public static func contrast(_ a: UInt32, _ b: UInt32) -> Double { … }
}
```

In `Voxglass/DesignSystem/VoxglassTheme.swift`, make `Palette.bg/surface/ink/ink2/ink3/brass/hairline/surfaceLine`
**dynamic** so that no call site changes:

```swift
private static func dynamic(_ pair: PaletteSpec.Pair) -> Color {
    Color(uiColor: UIColor { traits in
        UIColor(hex: traits.accessibilityContrast == .high ? pair.highContrast : pair.standard)
    })
}
```

Point `VoxglassTheme.paper`, `.paperRaised`, `.ink` and `.deepGlass` at the same Palette tokens. That removes the
duplicate `Color(hex:)` literals from `VoxglassTheme`.

**Tests:** `VoxglassTests/PaletteContrastTests.swift`:
- `ink`, `ink2`, `ink3` and `brass` are each ≥ 4.5:1 on `bg`, `surface` and `raised`, in both modes.
- `ink2` is strictly greater than `ink3` on `bg` in both modes. This is the hierarchy test that would have caught the
  inversion.
- `onBrass` (`0x21170B`) is ≥ 4.5:1 on `brass`.

**Color independence (Differentiate Without Color).**
- Audit every `Palette.ok`, `Palette.danger` and `VoxglassTheme.ok/danger` use with
  `grep -rn "Palette\.\(ok\|danger\)\|VoxglassTheme\.\(ok\|danger\)" Voxglass/Features Voxglass/DesignSystem`.
- Each state conveyed by colour must also carry a glyph (`checkmark.circle.fill` / `exclamationmark.triangle.fill` /
  `xmark.octagon.fill`) or a word.
- Where the design wants colour only, add the glyph when
  `@Environment(\.accessibilityDifferentiateWithoutColor)` is true.
- List every site you touched in the commit body.

**Reduce Transparency.**
- `ArtworkAmbientBackground` and `RaisedSurface` must switch to the opaque `PaletteSpec.raised` fill when
  `@Environment(\.accessibilityReduceTransparency)` is true.
- `glassEffect` already falls back on its own; leave it.

**Acceptance (A2):** PaletteContrastTests pass; every colour-only state has a non-colour equivalent; owner walk §9.4
(Increase Contrast, Differentiate Without Color, Reduce Transparency) is listed.

### 3.3 A3: VoiceOver semantics (iPhone)

The player already has labels, an adjustable scrubber (`ScrubberView.swift:83–86`), and Chapters and Bookmarks rotors
(`BookPageView.swift:871`, `BookmarksView.swift:53`). Coverage drops sharply in Narrate, Settings, Discover shelves
and the design-system components. Implement the following **in the shared components first**, so one change covers
many screens:

| Component / screen | Change |
|---|---|
| `SectionTitle` (`VoxglassComponents.swift:4`) | `.accessibilityAddTraits(.isHeader)` on the title Text. This covers every shelf heading in one line. |
| Book rows / cards (`BookRowView`, shelf cards in `VoxglassComponents.swift`, `DiscoverView`, `LibraryView`) | `.accessibilityElement(children: .combine)` plus one composed label: "*Title*, by *Author*, read by *Narrator*, *42 percent listened*" (omit parts that are missing). Add `.accessibilityActions { Play / Resume, Download, Add to My Books }`, calling the same closures as the visible buttons or context menu. |
| Root (`RootView.tabShell`) | `.accessibilityAction(.magicTap) { playback.togglePlayPause() }`. A two-finger double-tap anywhere plays or pauses. This matters a lot to blind listeners. |
| Mini player (`MiniPlayerAccessory.swift`) | Combine into one element: "Now playing, *Title*, *Chapter*, *paused/playing*". Actions: Play/Pause, Skip back N, Skip forward N, Open player. |
| Sleep timer | When the timer fires, and when it's set from the Live Activity, post `AccessibilityNotification.Announcement("Sleep timer ended. Playback paused.")` or "Sleep timer set for 30 minutes". |
| Downloads | On completion, post an announcement: "*Title* downloaded". |
| Speed control | `.accessibilityValue("1.5 times")`, and `accessibilityAdjustableAction` stepping through `PlaybackRate.menuLadder`. |
| Narrate record button | Label "Record paragraph *n* of *m*", or "Stop recording" while recording. Hint: "Double-tap to start. Recording stops automatically at the end of the paragraph." Only use that hint if it's true; read `AudioSessionCapture` first. |
| Paragraph review rows | Combined label: "Paragraph *n*, *approved / needs re-record / not recorded*". Actions: Play take, Approve, Re-record. |
| Icon-only buttons everywhere | Must have `.accessibilityLabel`. The `+` header action in `NarrationTabView.swift:27` becomes an SF Symbol `plus` with the label "Start a narration" (the label already exists; change `headerSecondaryActionTitle: "+"` to use `headerSecondaryActionSystemImage: "plus"`). |
| Decorative images | Cover art inside a row that already names the title: `.accessibilityHidden(true)`. Ambient backgrounds: hidden. |

**Source test, `VoxglassTests/AccessibilitySourceTests.swift`**, is a heuristic in the same style as
`DynamicTypeGuardTests`:
- For every `Button {` or `Button(action:` in `Voxglass/Features/**` and `Voxglass/DesignSystem/**`, read its label
  closure (up to the matching `}`).
- If the closure contains `Image(systemName:` and neither `Text(` nor `Label(`, then an `.accessibilityLabel(` must
  appear within 15 lines after the closure.
- Skip any button with `a11y-exempt:` on its line.
- Before adding exemptions, fix what it finds. Report the count you fixed.

**Acceptance (A3):** AccessibilitySourceTests pass with zero exemptions in the Player/Chrome/Listen/Library features;
magic tap is wired; owner walk §9.5 (the full VoiceOver script) is listed.

### 3.4 A4: Apple Watch accessibility

The Watch app has 4 `accessibilityLabel`s in 1,258 lines (`VoxglassWatch/*.swift`), plus `VoxglassWatch/Production/`.

- Label every transport, crown-adjustable and icon-only control in `WatchBookDetailView`, `WatchLibraryView`,
  `WatchRootView` and the Production views. Use the same wording as the phone, e.g. "Skip back 15 seconds".
- Library rows: combined label with title, author and "downloaded" / "on iPhone".
- Volume and position controls driven by the Digital Crown: `.accessibilityValue` plus `accessibilityAdjustableAction`.
- Extend `AccessibilitySourceTests` to scan `VoxglassWatch/**` too.

**Acceptance (A4):** the source test covers Watch sources with zero violations; owner walk §9.6.

### 3.5 A5: automated audits in the smoke tests

In `VoxglassUITests/VoxglassUITests.swift`, add a private helper and call it from the **existing** test function
(do not add a test function):

```swift
/// Runs Xcode's accessibility audit on the current screen. Known system-owned
/// false positives are skipped by identifier, each with a reason.
private func auditAccessibility(_ app: XCUIApplication, _ screen: String) throws {
    try app.performAccessibilityAudit(for: [.contrast, .elementDetection, .hitRegion,
                                            .sufficientElementDescription, .textClipped, .trait]) { issue in
        // Return true to ignore. Only system chrome may be ignored, never Voxglass views.
        guard let id = issue.element?.identifier else { return false }
        return Self.auditAllowlist.contains(id)
    }
}
private static let auditAllowlist: Set<String> = [
    // Add entries only with a one-line reason each. Start empty.
]
```

- Call it after each tab first renders (Listen, My Books, Discover, Narrate), on the Book page, and in Settings.
- Add **one** Dynamic Type leg at the end of the existing test:
  1. Relaunch with `-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXL`.
  2. Visit Listen and the Book page.
  3. Audit with `[.dynamicType, .textClipped]`.
- The smoke test is simulator-only (it uses a `/tmp` host export directory), so you **compile it only**
  (`build-for-testing`). The owner runs `scripts/test.sh` and sends you failures.
- **Watch:** if `performAccessibilityAudit` compiles for the watchOS UI test target, add one audit call in
  `VoxglassWatchUITests` on the library and now-playing screens. If the API isn't available on watchOS, skip it and
  say so in your report.

**Acceptance (A5):** both UI test bundles compile; the owner's `scripts/test.sh` run passes with an empty allowlist or
a justified one; the phone leg stays under about 8 minutes (report the owner's measured time).

---

## 4. Item 6a: Narrate refocused on LibriVox volunteering (N1–N2)

*This runs before localization so translators get the final copy.*

### 4.1 Why

Narrate today reads like a pro audio studio: retail destination profiles, mastering chain, M4B, FLAC masters, batch
export. The award story is simpler and stronger:

> **Listen to the world's public-domain audiobooks, and add your voice to them.**

LibriVox is read by volunteers. An app that closes the loop from listener to reader is the Social Impact pitch. There
are no commercial or Internet Archive narration publishing lanes in the product.

### 4.2 N1: information architecture and copy

1. **Hero with no active project.** `NarrationStudioHero` (`NarrationTabView.swift:86`) currently renders nothing when
   there's no project. Add an empty state (mockup §C, `narration.hero.empty`):
   - eyebrow "LIBRIVOX VOLUNTEERS"
   - title "Give a book its voice"
   - body: "*N* public-domain works are waiting for a reader. Record a chapter in 20 minutes and it joins the free
     LibriVox catalog, for anyone, forever." *N* is the real `discovery.availableNeeds.count`. If that count is 0 or
     not loaded yet, drop that sentence. Never show a placeholder number.
   - primary button "Find a book to read" (`narration.hero.findBook`), which opens `NarrationNeedsView`
   - secondary text button "Narrate your own text" (`narration.hero.ownText`), which opens the same flow as the
     `+` button
2. **Default destination.** In `NarrationFlow.swift`, `draftDestinationChoice` defaults to `.personal` (line ~318).
   When the flow starts from a `NarrationNeed` (a LibriVox need), set it to **`.librivox`**. When it starts from
   own text, keep `.personal`. Find where `startNeed` is consumed and set it there.
3. **Destination picker order** (`purposePicker`, `NarrationFlow.swift:~3418`; and the second picker in
   `NarrationFlowScreens.swift:~1790`):
   1. LibriVox — the built-in and only completed-narration submission path
   2. Personal Listening — a local preview before submission
   Commercial retail, ACX, and Internet Archive narration publishing destinations must not appear in the picker,
   completion actions, export formats sheet, validation routing, or narration mockups. Legacy Core destination profiles
   remain readable only so existing persisted projects can be decoded; they are never offered as new choices.
   - Heading "WHERE THIS IS GOING" becomes "Where will this be heard?" and uses `.voxType(.eyebrow)`.
4. **Hero button label bug.** `NarrationTabView.swift:103` uses
   `Button(phase.label == "Review" ? "Review \(…) takes" : "Record next paragraph", …)`. That compares a display
   string (it breaks under localization) and produces a `String` (so it's never localized). Replace it with a switch
   on the phase enum and two separate `Button(LocalizedStringKey)` branches. Read the phase type to find the correct
   case name.
5. **Settings "About".** Replace the deleted Pro line with the mission text from the mockup
   (`settings.about.mission`): "Voxglass is free, has no ads or tracking, and is open source. Books come from
   LibriVox volunteers and the Internet Archive."

### 4.3 N2: the contribution moment

After a successful **LibriVox** export there's a celebration: `NarrationFlowScreens.swift:2906` already has
`.sensoryFeedback(.success, trigger: celebration)`. Make that moment explicit (mockup §C, `contribution.done`):
- symbol `hands.and.sparkles.fill` with `.symbolEffect(.bounce, value: celebration)`
- title "Your chapter is ready for LibriVox"
- body: "*m* minutes of *Title*, read by you. Upload it from the LibriVox forum thread to add it to the public domain."
  *m* is the real assembled duration, rounded down.
- actions: "Share package" (the existing export share) and "How to submit" (the existing LibriVox checklist view, if
  there is one; otherwise a link to `https://librivox.org/pages/volunteer-for-librivox/`).
- Do **not** claim it has been published. The user submits it themselves; Voxglass never uploads automatically
  (gate `check_no_auto_upload`).

**Acceptance (N1–N2):** the empty hero renders with a real count or without the sentence; a need-started flow
defaults to LibriVox; only LibriVox and Personal Listening are offered; no display-string comparisons remain
(`grep -rnE '\.label == "' Voxglass` is empty); the celebration screen matches the mockup; the UI test ids are
preserved or updated in the same commit.

---

## 5. Item 5: Live Activity, Dynamic Island, widgets, controls (W1–W4)

`docs/INTENTS_LIVE_ACTIVITY_SIRI_PLAN.md` is the original design, and its P0 (Siri intents) has shipped
(`Voxglass/App/VoxglassIntents.swift`). This section **supersedes that plan's Parts 2–3** with verified,
repo-specific steps. The design principle carries over unchanged: every surface mutates playback only through intents
that land on `PlaybackCoordinator`.

### 5.1 Verified current state

- `VoxglassWidgets` target exists (`project.yml:136`) with one `StaticConfiguration` widget and one `ControlWidget`
  (`VoxglassWidgets/VoxglassWidgets.swift`).
- **Bug: the widget's Resume button does not play in the background.** The widget target defines its *own*
  `ResumeListeningIntent` (`VoxglassWidgets.swift:~72`) whose `perform()` just writes a flag
  (`WidgetPlaybackCommandStore.requestResume()`). The app polls that flag every 1 s from `RootView`
  (`RootView.swift:~91–96`, `handleWidgetCommand`). That poll only runs while the app's UI is alive, so tapping
  Resume on a suspended app does nothing until the app is foregrounded. W1 fixes this.
- `NowPlayingSnapshot.coverThumbnailPNG` exists but is never written. The widget has no artwork and uses a generic
  `.fill.tertiary` background.
- No `ActivityKit` usage anywhere. `NSSupportsLiveActivities` is absent from `project.yml`.
- `PlaybackCoordinator.updateNowPlayingInfoIfNeeded` (around `PlaybackCoordinator.swift:1895`) already dedupes on
  book, chapter, isPlaying and rate. That's the natural hook point for Live Activity updates.

### 5.2 W1: shared intent layer (fixes the widget resume bug)

**Pattern.** For an `AudioPlaybackIntent` or `LiveActivityIntent` compiled into **both** the app and the extension,
the system runs `perform()` in the app process. Put the intent types in a folder shared by both targets. Route
`perform()` through an enum that has a real implementation in the app target and a no-op in the widget target.

1. Create `VoxglassShared/` at the repo root. In `project.yml`, add `- path: VoxglassShared` to the `sources:` of both
   `Voxglass` and `VoxglassWidgets`, then run `xcodegen generate`.
2. `VoxglassShared/PlaybackCommand.swift`:
   ```swift
   /// A playback command issued from outside the app UI (widget, control, Live Activity).
   enum PlaybackCommand: String, Codable, Sendable { case resume, togglePlayPause, skipBackward, skipForward, cycleSleepTimer }
   ```
3. `VoxglassShared/PlaybackControlIntents.swift` defines these intents. Each one's `perform()` is
   `try await PlaybackCommandRouter.perform(.x)`.
   - `ResumeListeningIntent: AudioPlaybackIntent` (moved; returns `ProvidesDialog`)
   - `TogglePlaybackIntent: LiveActivityIntent`
   - `SkipBackwardIntent: LiveActivityIntent`
   - `SkipForwardIntent: LiveActivityIntent`
   - `CycleSleepTimerIntent: LiveActivityIntent`

   Every one has `static let openAppWhenRun = false`.
4. `Voxglass/App/PlaybackCommandRouter.swift` (app only) contains the real implementation:
   - `.resume` is the exact body of today's `ResumeListeningIntent.perform()` from `VoxglassIntents.swift:74–101`.
     Move it; don't duplicate it. It returns the dialog string.
   - `.togglePlayPause`: `coordinator.togglePlayPause()`.
   - `.skipBackward` / `.skipForward`: `await coordinator.skip(by: ∓interval)`, with the interval read from
     `AppPreferencesStore.Keys.skipBackInterval` / `skipForwardInterval` (defaults 15 / 30).
   - `.cycleSleepTimer`: `off → .duration(default from Settings "Default Sleep Timer") → .endOfChapter → off`, via
     `coordinator.setSleepTimer(_:)`. It posts the VoiceOver announcement from A3.

   Every branch first calls `await VoxglassIntentBridge.prepare()`.
5. `VoxglassWidgets/PlaybackCommandRouter.swift` (widget only) has the same signature and returns `nil`. It must never
   be reached. Add a `///` saying so.
6. Delete from `VoxglassWidgets.swift`: the local `ResumeListeningIntent`. Delete from `VoxglassIntents.swift`: the
   app's `ResumeListeningIntent` (now shared). `VoxglassShortcuts` still references `ResumeListeningIntent()`, which
   now resolves to the shared type.
7. **Keep** `WidgetPlaybackCommandStore` and the `RootView` poll until the owner confirms device walk §9.7 step 1
   (resume from the widget while the app is suspended). Then remove both in a separate small commit:
   `fix: remove widget command poll`.
8. Update `VoxglassTests/VoxglassIntentsContractTests.swift` so its source paths include
   `VoxglassShared/PlaybackControlIntents.swift`. Add these assertions:
   - every intent in that file declares `openAppWhenRun = false`
   - nothing in `VoxglassShared/**` or `VoxglassWidgets/**` mentions `PositionStore`, `SQLitePositionStore`,
     `AppDatabase(` or `LibraryRepository` (the single-writer guard)
   - the skip branches read `skipBackInterval` / `skipForwardInterval` and don't hard-code 15/30

**Acceptance (W1):** app and widget build for device; intents contract tests pass; the owner confirms §9.7 step 1.

### 5.3 W2: Core content model and update policy (platform-free, unit-tested)

`Voxglass/Core/Playback/LiveActivityContent.swift`:

```swift
/// Platform-free description of what the lock-screen Live Activity shows.
public struct LiveActivityContent: Equatable, Sendable {
    public var bookID: UUID
    public var title: String
    public var author: String
    public var narrator: String?
    public var chapterTitle: String
    public var chapterIndex: Int          // 1-based
    public var chapterCount: Int
    public var isPlaying: Bool
    public var rate: Float
    public var chapterElapsed: TimeInterval
    public var chapterDuration: TimeInterval?
    public var bookRemaining: TimeInterval?   // across all chapters, at 1×
    public var sleep: SleepState              // .off | .until(Date) | .endOfChapter
    public var capturedAt: Date               // from the Clock seam, not Date()
}

/// Decides when ActivityKit gets a push. Pure; tested in LiveActivityUpdatePolicyTests.
public enum LiveActivityUpdatePolicy {
    /// Push only on a meaningful change. Never on a plain playhead tick.
    public static func shouldPush(previous: LiveActivityContent?, next: LiveActivityContent) -> Bool
    /// The interval the lock screen animates itself between pushes, adjusted for rate.
    public static func progressInterval(for c: LiveActivityContent) -> ClosedRange<Date>?
    /// When the system should grey the activity out.
    public static func staleDate(for c: LiveActivityContent) -> Date?
}
```

Rules, each covered by a test:
- **Push on:** book or chapter change, play/pause, a rate change, a sleep state change, or a seek (`|Δelapsed − expected
  drift| > 5 s`).
- **No push** when only `chapterElapsed` advanced consistently with `rate × wall time`. This is the 1 Hz tick; the
  "never on the progress path" rule from the original plan.
- `progressInterval`: start = `capturedAt − chapterElapsed / rate`, end = `start + chapterDuration / rate`. It's `nil`
  when paused or when the duration is unknown. Test it at rate 1.0, 1.5 and 3.5.
- `staleDate` = end of the progress interval + 60 s while playing; `capturedAt + 15 min` while paused.

**Bridge hook.** In `PlaybackPlatformBridge.swift`:
- Add `func updateLiveActivity(_ content: LiveActivityContent?)`, with a default no-op in the protocol extension.
- `NoopPlaybackBridge` records the last value for tests.
- In `PlaybackCoordinator`, build the content at the same sites that call `updateNowPlayingInfoIfNeeded`, and also in
  `setSleepTimer(_:)`, `handleSleepTimerFired()` and after `seek(to:)`. Pass `nil` when `currentSession` becomes nil.
- The coordinator consults `LiveActivityUpdatePolicy.shouldPush` before calling the bridge, so the bridge never sees
  tick-rate traffic.

**Tests:** `VoxglassTests/LiveActivityUpdatePolicyTests.swift` covers every rule above. A coordinator-level test
(existing fakes in `VoxglassCoreTestSupport`) plays for 10 simulated seconds and asserts **exactly one** bridge push.

### 5.4 W3: ActivityKit controller and Live Activity UI

1. In `project.yml`, add `NSSupportsLiveActivities: true` to the `Voxglass` Info properties.
   `NSSupportsLiveActivitiesFrequentUpdates` stays absent.
2. `VoxglassShared/BookActivityAttributes.swift`:
   ```swift
   struct BookActivityAttributes: ActivityAttributes {
       struct ContentState: Codable, Hashable {
           var chapterTitle: String; var chapterIndex: Int; var chapterCount: Int
           var isPlaying: Bool; var rate: Float
           var progressStart: Date?; var progressEnd: Date?      // nil when paused
           var chapterFraction: Double                           // shown when paused
           var bookRemaining: TimeInterval?
           var sleepUntil: Date?; var sleepEndOfChapter: Bool
           var skipBack: Int; var skipForward: Int
       }
       let bookID: UUID; let title: String; let author: String; let narrator: String?
   }
   ```
   Keep it small: ActivityKit payloads are capped at 4 KB. **No image data in the payload.**
3. **Artwork:** `VoxglassShared/CoverThumbnailStore.swift`, in both targets.
   - The app writes a 160×160 JPEG (quality 0.8) to `<app group>/Artwork/<bookID>.jpg` when a session's artwork loads.
     Hook this where `PlaybackCoordinator.artworkProvider` data arrives in the app (`SystemPlaybackBridge.setArtwork`).
   - The widget reads it with `UIImage(contentsOfFile:)`.
   - Keep at most 20 files; delete the oldest first.
   - Fallback: the `CoverPlate`-style palette tile. Its colours come from the snapshot fields added in W4.
4. `Voxglass/App/LiveActivityController.swift` (`@MainActor final class`, owned by `AppServices`):
   - `update(_ content: LiveActivityContent?)`, called by `SystemPlaybackBridge.updateLiveActivity`.
   - **Start** when content is playing, no activity exists for that `bookID`, and
     `ActivityAuthorizationInfo().areActivitiesEnabled` is true, and the Settings toggle (below) is on.
   - **Update** with `activity.update(ActivityContent(state:, staleDate:))`.
   - **End** with `.immediate` when content is nil (session cleared) or the book changes (then start a new one).
     Paused for more than 15 minutes means end with `.default`.
   - **At launch**, adopt `Activity<BookActivityAttributes>.activities`: keep the one matching the restored session,
     end the rest.
   - Honour the **"Live Activity" toggle** in Settings ▸ Playback (id `settings.liveActivity`, default on), next to the
     existing widget snapshot toggle. This follows `CLAUDE.md`'s "always in the user's control" rule.
   - Guard every ActivityKit call with `#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)` if the Catalyst
     build complains.
5. `VoxglassWidgets/BookLiveActivity.swift` holds `ActivityConfiguration(for: BookActivityAttributes.self)`. Add it to
   `VoxglassWidgetBundle`. The layout contract is mockup §F:
   - **Lock screen:**
     - cover (56 pt, radius 10)
     - eyebrow "VOXGLASS · CH 5 OF 19"
     - title (1 line), then "chapter · narrator" (1 line)
     - sleep capsule, top-trailing, when a timer is set: `☾ 23:41` using `Text(timerInterval:)`, or "☾ End of
       chapter"
     - progress bar: `ProgressView(timerInterval:countsDown:false)` while playing; `ProgressView(value:)` while paused
     - a row with elapsed, "6 h 12 m left in book" (formatted with `Duration.UnitsFormatStyle`), and remaining
     - buttons: `Button(intent: SkipBackwardIntent())` with `SkipSymbol`-equivalent symbol names (the widget can't
       import the app's `SkipSymbol`, so copy its availability logic into `VoxglassShared/SkipSymbols.swift` and have
       the app's `SkipSymbol` call it), toggle, skip forward, sleep cycle
     - background: `.activityBackgroundTint(Color(hex: deep palette))`
     - `.activitySystemActionForegroundColor(brass)`
   - **Dynamic Island:**
     - compact leading: the cover, circular, 22 pt
     - compact trailing: `Text(timerInterval:)` remaining in chapter when playing; a pause glyph when paused
     - minimal: a progress ring (`ProgressView(timerInterval:)` with `.circular` style) around the brass waveform glyph
     - expanded: leading cover 44 pt; trailing rate "1.5×"; center title + chapter; bottom progress + the five-button
       transport
   - Every button has an `accessibilityLabel` ("Skip back 15 seconds", "Pause", …).
6. **Tests:** in `VoxglassIntentsContractTests`, add assertions that `BookLiveActivity.swift` contains no
   `Activity.update`/`request` calls (those only happen in the app), and that `LiveActivityController.swift` is the
   only file in `Voxglass/` that references `Activity<`.

### 5.5 W4: widget redesign and controls

1. **Snapshot fields.** Add to `NowPlayingSnapshot` (Core):
   - `backgroundHex: UInt32?` and `accentHex: UInt32?`, computed in `WidgetSnapshotWriter` from
     `ArtworkPaletteProvider`'s `deep`/`vivid` for the current book
   - `bookRemaining: TimeInterval?`
   - `isPlaying: Bool`
   - `updatedAt: Date`

   Remove `coverThumbnailPNG`, since the cover now comes from `CoverThumbnailStore`. Old JSON must still decode, so
   give every new field a default via a custom `init(from:)`, and test that.
2. **Families** (mockup §G). Keep the `widgetKind` constant so existing placements survive:
   - `systemSmall`: full-bleed cover, a bottom gradient scrim, the title (2 lines), and a progress ring with a
     play/pause `Button(intent: TogglePlaybackIntent())` in the corner.
   - `systemMedium`: the cover on the left; eyebrow "CONTINUE"; title; "Ch 5 · 22 min left"; a progress bar; and
     back, play/pause and forward intent buttons.
   - `accessoryCircular`: a progress ring (`Gauge` with `.accessoryCircularCapacity`) around the first letter of the
     title in serif.
   - `accessoryRectangular`: title, "22 min left in chapter" and a linear gauge.
   - `accessoryInline`: "6 h 12 m left · *Title*".
   - Mark the cover with `.widgetAccentedRenderingMode(.desaturated)` so tinted and clear Home Screens look deliberate.
     Mark text with `.widgetAccentable()`.
   - Background: `.containerBackground(for: .widget) { LinearGradient(backgroundHex → #0A0B0D) }`.
   - Empty state: the brass waveform glyph and "Nothing playing yet" plus "Find a book" (deep link
     `voxglass://discover`). Keep the "Widgets are off in Voxglass settings" state.
3. **Controls.** Keep `ResumeVoxglassControl`. Add:
   - `SleepTimerControl`: `ControlWidgetButton` with `CycleSleepTimerIntent`, label "Sleep Timer", symbol `moon.zzz`.
   - `SkipBackControl`: `ControlWidgetButton` with `SkipBackwardIntent`, symbol from `SkipSymbols.back(configured)`.

   Add both to the bundle.
4. **Timeline:** keep `.after(60 s)`. `WidgetSnapshotWriter.write` already runs on session and isPlaying changes. Also
   call it on chapter change and after a sleep-timer change (via the `RootView` `onChange`s).

**Acceptance (W1–W4):**
- [ ] Policy tests and the snapshot backward-compatibility test pass.
- [ ] Contract tests pass.
- [ ] App, widget, Watch and Mac all build (device + macOS destinations).
- [ ] The brass budget isn't exceeded. Widget code isn't counted, but any Settings toggle code is.
- [ ] Owner walk §9.7 passes in full.

---

## 6. Item 6b: motion and haptics (M1–M2)

### 6.1 M1: player micro-interactions

Currently there are zero `symbolEffect`/`contentTransition` uses, one `sensoryFeedback`, and one
`UIImpactFeedbackGenerator` (`VoxglassTheme.swift:171`). Add these exactly (mockup §H table):

| Element (file) | Motion | Haptic (user-initiated only) |
|---|---|---|
| Play/pause (BookPageView transport, MiniPlayerAccessory) | `Image(systemName: isPlaying ? "pause.fill" : "play.fill").contentTransition(.symbolEffect(.replace.downUp))` | `.sensoryFeedback(.impact(weight: .light), trigger: userToggleCount)` |
| Skip back / forward | `.symbolEffect(.bounce.byLayer, value: skipBackCount)` (a separate counter per button) | `.sensoryFeedback(.impact(flexibility: .soft), trigger:)` |
| Speed label ("1.5×") | `.contentTransition(.numericText(value: Double(rate)))` + `.animation(Motion.standard, value: rate)` | `.sensoryFeedback(.selection, trigger: rate)` |
| Sleep timer countdown | `.contentTransition(.numericText(countsDown: true))`, **minute granularity only** (`sleepDisplayMinute`) | `.selection` when the user sets it; nothing when it fires (the listener may be asleep) |
| Bookmark added | `bookmark` → `bookmark.fill` with `.symbolEffect(.bounce, value: bookmarkCount)` | `.success` |
| Download complete (row badge) | `.symbolEffect(.bounce, value: isDownloaded)` + `.contentTransition(.symbolEffect(.replace))` from `arrow.down.circle` to `checkmark.circle.fill` | none (it isn't user-initiated at that moment) |
| Chapter change | `.contentTransition(.opacity)` on the chapter title | none |
| Scrubber | none | `.sensoryFeedback(.alignment, trigger: crossedChapterBoundary)` only if the scrubber displays chapter markers; otherwise `.selection` on drag end |

Rules:
- **Haptics only for direct user actions.** Never on automatic transitions, timers or remote commands. Drive each
  `sensoryFeedback` from a counter that only the button's action increments. Never use `isPlaying` directly, because
  remote commands change it too.
- **Reduce Motion:** SF Symbol effects adapt on their own. For every *custom* `withAnimation` / `.animation` added in
  this phase, use `reduceMotion ? nil : Motion.standard`.
- **No 1 Hz animations.** Never put a `numericText` transition on the playhead clock.

### 6.2 M2: haptics consolidation

- Replace `UIImpactFeedbackGenerator(style: .light).impactOccurred()` at `VoxglassTheme.swift:171` with the
  `.sensoryFeedback` equivalent at its call site.
- **Gate G-A9** (`check_ada_swiftui_haptics`): `UIImpactFeedbackGenerator|UINotificationFeedbackGenerator|UISelectionFeedbackGenerator`
  anywhere in `Voxglass/Features`, `Voxglass/DesignSystem` or `Voxglass/App` is a violation. Add a probe.

**Acceptance (M1–M2):** G-A9 passes; the brass budget holds; there are no haptics on non-user paths (the commit body
lists each trigger and why it's user-initiated); owner walk §9.8.

---

## 7. Item 4: localization (L0–L6)

### 7.1 Verified current state

- `Voxglass/Resources/Localizable.xcstrings` has **9 keys** (tab names, widget strings) in 7 languages.
- `project.yml` already sets `SWIFT_EMIT_LOC_STRINGS: YES` and `LOCALIZATION_PREFERS_STRING_CATALOGS: YES`.
- About 390 `Text("…")` and 220 `Button("…")` literals are auto-localizable, but they haven't been extracted.
- **121 component parameters are typed `String`** (`title: String`, `subtitle: String`, `caption: String`, … in
  `VoxglassComponents.swift`, `NarrationButtons.swift`, `NarrationPipeline.swift`, `CoverPlate.swift`,
  `VoxglassTheme.swift:71` `VoxglassScreen.title`, and feature-private helpers such as `destinationRow(title:caption:)`).
  `Text(someString)` is **verbatim**, so everything passed through these components is invisible to extraction.
- **Core has 77 display-name properties** returning `String` (e.g. `LibriVoxLanguage.displayName: "German"`, category
  names, blocker messages). `Package.swift` has no `defaultLocalization`.
- The App Shortcut phrases in `VoxglassShortcuts` are English only.
- Traps already found: a `String` ternary inside `Button(…)` (`NarrationTabView.swift:103`, fixed in N1), and
  hard-coded unit strings in time formatting. Audit `Voxglass/DesignSystem/TimeFormatting.swift`.

### 7.2 L0: spike for Core strings (commit only the decision)

Core runs under `swift test` on macOS. Linux CI only runs grep gates, so `String(localized:bundle:)` is available.

1. Add `defaultLocalization: "en"` to `Package.swift`.
2. Add `Voxglass/Core/Resources/Localizable.xcstrings` with one key, used from `LibriVoxLanguage` via
   `String(localized: "German", bundle: .module)`, under `.process("Resources/Localizable.xcstrings")`.
3. Run `swift test`, and build the app for the device.
4. **Decision rule:**
   - If both succeed **and** the German string resolves in a unit test run with `Locale(identifier: "de")` (use
     `String(localized:bundle:locale:)`), keep the `.xcstrings` approach.
   - If `swift test` fails to process the catalog, switch Core to `Resources/en.lproj/Localizable.strings` plus
     per-language `.lproj` folders. SwiftPM has always supported those.

   Report which branch you took.

### 7.3 L1: make everything extractable (code-only; no translations yet)

Rules, applied across `Voxglass/Features`, `Voxglass/DesignSystem`, `Voxglass/App`, `VoxglassWidgets`,
`VoxglassShared` and `VoxglassWatch`:

1. **Component parameters.** Change display-text parameters from `String` to `LocalizedStringKey` when they're only
   rendered with `Text(_:)`. If the value is also used as data (an id, a comparison, accessibility identifier
   composition), use `LocalizedStringResource` and render with `Text(resource)`.
   **Never** localize user or catalog data: book titles, authors, narrator names, chapter titles and paragraph text
   stay `String`, rendered with `Text(verbatim:)` where the literal-vs-key ambiguity would otherwise matter.
2. **Dynamic strings** go through interpolation in a literal, e.g. `Text("\(count) paragraphs")`. Add **plural
   variations** in the catalog for every count-bearing key: paragraphs, minutes, chapters, books, takes, downloads.
3. **Durations and times**: `Duration.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))`, or
   `Text(timerInterval:)`, `Text(date, style:)`. **No** hand-built `"\(h)h \(m)m"`. Byte counts:
   `ByteCountFormatter` (already used). Rates: `rate.formatted(.number.precision(.fractionLength(0...2)))` + "×".
4. **Ternaries** of string literals inside `Text(…)` / `Button(…)` / `Label(…)` must become two separate views, or
   use `LocalizedStringKey` explicitly. **Gate G-A10** (`check_ada_no_literal_ternary`) flags the regex
   `(Text|Button|Label)\([^)]*\?\s*"` in Features/DesignSystem/App/Widgets/Watch. Lines with `l10n-exempt:` are
   skipped. Add a probe.
5. **Core display strings:** all 77 use `String(localized:bundle: .module)` (or the L0 fallback).
   `LibriVoxLanguage.displayName` becomes
   `Locale.current.localizedString(forLanguageCode: id) ?? englishName`. Keep the English names as the fallback and
   as search `tokens`, because tokens are catalog query data and must not be localized.
6. **App Shortcuts:** add `Voxglass/Resources/AppShortcuts.xcstrings` (Xcode's supported mechanism for phrase
   localization). Keep the `\(.applicationName)` token in every phrase.
7. **Accessibility labels and hints** are user-facing strings too. They must be literals or `LocalizedStringKey`.
8. **Data-driven comparisons:** `grep -rnE '== "[A-Z][a-z]+' Voxglass/Features` must show no comparisons against display
   text. Compare enums.
9. **Layout:** replace `.padding(.left/.right)` / `alignment: .left` (if any) with leading/trailing. SF Symbols
   that indicate direction (`chevron.right`, `arrow.right`) must use the auto-mirroring variants or
   `.flipsForRightToLeftLayoutDirection(true)`. Skip glyphs (`gobackward.15` / `goforward.30`) represent time, **not**
   direction, so do **not** mirror them. This matches Apple Music and Podcasts.

**Verification (L1):**
- Export strings with
  `xcodebuild -exportLocalizations -project Voxglass.xcodeproj -localizationPath /tmp/voxglass-loc -exportLanguage en`.
  This runs a build and syncs every catalog. Commit the updated `.xcstrings` files.
- **Expect about 1,000–1,500 keys.** If fewer than 800 keys come back, something still bypasses extraction; find it
  before continuing.
- Build for device, and run the app with `-NSDoubleLocalizedStrings YES` (double-length pseudolanguage) and
  `-AppleTextDirection YES -NSForceRightToLeftWritingDirection YES`. The owner runs this walk (§9.9); you list it.

### 7.4 L2: catalog hygiene tests

`VoxglassTests/LocalizationCatalogTests.swift` parses every `.xcstrings` (JSON) under the repo:
- no key with `extractionState: "stale"`
- every key has a non-empty `comment`; translators need context. Write the comments. The commit is large, and that's
  expected.
- once a language is declared in `LocalizationTiers.tier1` (a static list in the test), every translatable key has a
  localization for it in state `translated` or `needs_review`
- every plural variation present in `en` is present for each tier language

### 7.5 L3: Tier 1 translations (agent draft → human review)

**Tier 1:** `de, fr, es, it, pt-BR, nl, ja, zh-Hans`. These are the largest non-English LibriVox catalogs that
Voxglass already filters on, plus the 7 languages the current catalog already carries.

- Draft every key yourself into the catalog with `state: "needs_review"`.
- Follow the glossary in `docs/localization/GLOSSARY.md`, which you create in this phase:
  - never translate: *Voxglass*, *LibriVox*, *Internet Archive*, *CarPlay*, *iCloud*, *Apple Watch*, *ACX*, *M4B*,
    *FLAC*
  - fixed translations for: *narrate / narration / take / paragraph / chapter / sleep timer / bookmark / My Books /
    Discover / Listen*, one row per language
- Tone: warm, second person, formal "Sie" in German, "vous" in French, "usted" is **not** used in Spanish (use "tú").
  Japanese uses です/ます.
- Mark any key you're unsure of with a translator comment prefixed `REVIEW:`.
- **Release gate:** extend `scripts/audit_app_store_release.sh`. A release build fails if any `.xcstrings` contains
  `"state" : "needs_review"`. The owner arranges native-speaker review (see §8). Reviewers flip the state to
  `translated` in Xcode's catalog editor.

### 7.6 L4: language-aware defaults

- **Onboarding default languages:** `LibriVoxLanguage.defaultSelection` becomes
  `{"eng"} ∪ {device language mapped to a LibriVox id}`, using `Locale.preferredLanguages`. Only languages present in
  `LibriVoxLanguage.all` count.
- Existing users' stored selections are untouched. This only affects the default for new installs.
- Test the mapping (`de-DE → deu`, `pt-BR → por`, `zh-Hans-CN → zho`, `he-IL → heb`, `en-GB → eng`, `xx → eng only`).
- Language chips in onboarding and Settings show the localized language name
  (`Locale.current.localizedString(forLanguageCode:)`), with the native name as a subtitle
  (`Locale(identifier: id).localizedString(forLanguageCode: id)`) (mockup §E).

### 7.7 L5: Tier 2 + RTL

**Tier 2:** `ru, pl, he`. Hebrew is the RTL proof. Same draft-and-review flow as L3.

The RTL audit on device (owner walk §9.9, Hebrew) must check:
- tab bar order, navigation back chevrons and swipe-back direction
- scrubber fill direction (progress runs right-to-left; skip glyphs are **not** mirrored)
- chapter list alignment
- the mini-player layout
- the Live Activity and widgets
- the narration paragraph text, which uses the book's language direction, **not** the UI's. Set
  `.environment(\.layoutDirection, …)` from the book's language for reading-text views only.

### 7.8 L6: localized App Store metadata (owner-assisted)

- Draft App Store name, subtitle, promotional text, description and keywords for Tier 1 + Tier 2 in
  `docs/localization/APP_STORE_METADATA.md`, in the same review state.
- Screenshots per language are an owner task; list it.

**Acceptance (L0–L6):**
- [ ] The catalog test passes.
- [ ] G-A10 passes.
- [ ] The key count is reported.
- [ ] Every Tier 1 and Tier 2 language is fully drafted.
- [ ] The release audit blocks `needs_review`.
- [ ] The language-default tests pass.
- [ ] Owner walks §9.9 and §9.10 are listed.

---

## 8. Owner-only tasks (the agent lists these; it cannot do them)

| When | Task |
|---|---|
| After I1 | Approve icon concept A (or pick B/C), then assemble `AppIcon.icon` in Icon Composer (§2.4). |
| After each phase | Run the device walks in §9 that the agent's report names. Run `scripts/test.sh` for the simulator smoke suite. |
| After A3–A4 | Recruit 2–3 blind or low-vision listeners (e.g. via AppleVis forums) for a TestFlight VoiceOver session. File what they find as issues. |
| After L3/L5 | Native-speaker review per language (one reviewer each; paid or community). Reviewers flip `needs_review` → `translated`. |
| Release | Localized screenshots; App Store Connect featuring nomination timed with the release that ships L3 + W3. |

---

## 9. Device walks (owner, physical iPhone / Watch)

Each walk is short. Tick the steps in the agent's phase report.

**9.1 Paid tier (P1)**
1. Settings ▸ About shows no "Pro" text and does show the mission line.
2. Narrate ▸ + ▸ import ▸ "Learn about export formats" opens a sheet listing formats, with no price or purchase
   button.
3. The destination picker shows no Pro chip.

**9.2 Icon (I2)**
1. Check the Home Screen icon in Default, Dark, Clear and Tinted (long-press the Home Screen, then Edit ▸ Customize).
2. The mark is legible at the Spotlight size.
3. The Settings app row icon is correct.

**9.3 Dynamic Type (A1)**
1. Set the text size to AX5 (Settings ▸ Accessibility ▸ Display & Text Size ▸ Larger Text).
2. Visit Listen, My Books, Discover, Book page, Narrate, and Settings.
3. No text is truncated mid-word, no text overlaps, and every control is reachable by scrolling.

**9.4 Contrast (A2)**
1. Turn on Increase Contrast: secondary text is visibly brighter and hairlines are visible.
2. Turn on Differentiate Without Color: validation states show icons.
3. Turn on Reduce Transparency: the Book page background is opaque.

**9.5 VoiceOver (A3)**
With VoiceOver on and the screen curtain on (three-finger triple-tap):
1. Resume the last book from Listen.
2. Magic tap pauses and resumes.
3. Swipe through the Book page: header, cover skipped, title, author, narrator, transport with labels, the speed
   value adjusts with swipe up/down.
4. Use the Chapters rotor to jump to chapter 3.
5. Set a 15 min sleep timer; the announcement is heard.
6. On a book row in My Books, the actions rotor offers Play and Download.
7. Narrate: start a LibriVox need and record one paragraph, knowing what state you're in at each step.

**9.6 Watch VoiceOver (A4)**
With VoiceOver on the Watch, open the library, play a downloaded book, skip back, and change the volume with the
crown. Every element is spoken meaningfully.

**9.7 Live Activity and widgets (W1–W4)**
1. **The app is suspended** (use another app for 2 minutes). Tap Resume on the Home Screen widget: audio starts
   without the app opening.
2. Lock the phone while playing. The Live Activity shows the cover, chapter, narrator and a moving progress bar.
3. Tap skip back, pause and play on the lock screen. Each responds in under 300 ms without unlocking.
4. Tap the sleep button: "☾ 30:00" appears and counts down; tap twice more to cycle through end-of-chapter and off.
5. Dynamic Island: compact shows the cover and time remaining; long-press gives the expanded view with working
   controls.
6. At 1.5×, the progress bar reaches the chapter end when audio does (±5 s).
7. Pause for 16 minutes: the activity ends.
8. Turn off Settings ▸ Live Activity: no activity appears on the next play.
9. Tinted Home Screen: the widget looks deliberate. The Lock Screen circular and rectangular widgets are correct.
10. Control Center: the Sleep Timer and Skip Back controls work while another app is in the foreground.
11. Plug into CarPlay mid-activity: no duplicate activity and no position jump.

**9.8 Motion (M1)**
1. Play/pause morphs.
2. The skip glyphs bounce, and the haptic fires only on taps (not when AirPods toggle playback).
3. The speed number rolls.
4. Adding a bookmark bounces and gives a success haptic.
5. With Reduce Motion on, custom animations are gone and nothing jumps.

**9.9 Pseudo-localization and RTL (L1, L5)**
1. Launch with the double-length pseudolanguage: no clipped buttons in the six main screens.
2. Launch with Hebrew: the checks in §7.7.

**9.10 Languages (L3–L6)**
1. Set the device to German. The whole UI is German, and the Siri phrases from `AppShortcuts.xcstrings` work when
   spoken in German.
2. Set the device to Japanese. The widget and Live Activity are localized.
3. A new install in German preselects German + English in onboarding.

---

## 10. Definition of done (all six items)

- [ ] No paid-tier copy anywhere (G-A7).
- [ ] The layered `.icon` ships on iOS and macOS, with no text in the icon.
- [ ] No sub-11 pt text; everything uses text styles (G-A8); there are contrast tests for both modes; colour is never
      the only signal; VoiceOver walk §9.5 passes, including with an external blind tester; Watch labels are complete;
      the audits are in the smoke test with an empty or justified allowlist.
- [ ] Tier 1 + Tier 2 (incl. Hebrew RTL) are fully translated **and reviewed**; there are plurals for every count;
      Siri phrases are localized; defaults are device-language-aware.
- [ ] The Live Activity and Dynamic Island are live with correct rate-aware progress; widgets use artwork and support
      tinted mode; three controls exist; the widget resume works while the app is suspended.
- [ ] The Narrate hero leads with LibriVox volunteering; retail export sits under "More destinations"; the
      contribution moment is truthful; micro-interactions and haptics are in place (G-A9).
- [ ] Every phase is committed separately, with gates green and the owner walks ticked.
