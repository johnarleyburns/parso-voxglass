# Narration Markers, Loading Feedback, And Tactile Taps

Date: 2026-07-22

## Summary

Make solo narration a first-class browsing signal and make every tappable app action feel acknowledged. Remote catalog result taps should immediately show row or card loading state plus light haptic feedback while metadata imports. Books stay unmarked by default; only confidently classified solo narration gets a visible `Solo Narration` marker.

This plan covers runtime behavior, conservative narration classification, affected UI surfaces, loading and haptic acceptance criteria, source guard tests, and review mockups.

## Goals

- Show a `Solo Narration` marker only when the app can confidently classify a book as a single-reader recording.
- Add a solo-only filter to local library search and every remote catalog list surface.
- Add immediate loading feedback when a remote catalog row or recommendation card is tapped to import metadata.
- Add light tactile feedback for app actions initiated through buttons, navigation rows, menus, and tappable item surfaces.
- Keep mixed, cast, volunteer, multiple-reader, or unknown narration unmarked.

## Non-Goals

- Do not introduce a visible `Mixed Narration` badge.
- Do not block imports globally when one result is importing; only the tapped identifier should be disabled.
- Do not classify remote search results as solo from weak signals such as title keywords alone when reader metadata is missing.
- Do not add haptics to text field focus, picker segment changes, sliders, drags, scroll gestures, or system gestures.

## Core Model

Add a small public enum in Core:

```swift
public enum NarrationKind: String, Codable, Equatable, Sendable {
    case solo
    case mixedOrUnknown
}
```

Add derived properties rather than a database column at first:

- `Book.narrationKind`
- `BookWithChapters.narrationKind`
- `InternetArchiveSearchResult.narrationKind`

Rationale: existing persisted data already stores narrator arrays, and the classification rule is deterministic. A derived model avoids a migration while keeping old books classifiable after narrator backfill.

## Classification Rules

Default state is `.mixedOrUnknown`.

Classify as `.solo` only when normalized metadata produces exactly one plausible human narrator.

Solo examples:

- `Read by Expatriate`
- `Read by Carl Banks`
- `Reader: Elizabeth Klett`
- one LibriVox reader repeated across all chapters

Mixed or unknown examples:

- no reader metadata
- multiple extracted names
- `Read by Jane Doe and John Smith`
- `Narrator: Jane Doe, John Smith`
- `volunteers`
- `cast`
- `full cast`
- `various`
- `group`
- `dramatic reading`
- `collaborative`
- `unknown`
- `anonymous`
- `LibriVox volunteers`

Normalization steps:

1. Trim whitespace, punctuation, repeated spaces, and simple leading labels.
2. Extract known patterns: `Read by`, `Narrated by`, `Reader:`, `Narrator:`, `Performed by`, `Voiced by`.
3. Split candidate lists on commas, ampersands, slashes, and the word `and`.
4. Deduplicate names case-insensitively.
5. Reject blocked collective or ambiguous terms.
6. Return `.solo` only when exactly one candidate remains.

Remote catalog classification is intentionally conservative. False negatives are acceptable; false positives are not.

## UI Treatment

Add `SoloNarrationBadge` to the design system using existing brass/glass styling:

- Compact capsule.
- Label: `Solo Narration`.
- Small enough for rows and horizontal cards.
- Uses existing type scale and color tokens.
- No companion badge for mixed or unknown books.

Show the badge anywhere a book is represented by a shared row or card component:

- `BookListRow`
- `CompactBookRowView`
- local Library rows
- author detail lists
- narrator detail lists
- playlist lists
- Listen recommendation rails
- Search remote result rows
- Explore collection result rows
- CatalogDiscovery result rows

Show text metadata near the narrator line on detail surfaces:

- Book Page / Now Playing header
- unified metadata stack below title
- any summary/detail header that already renders narrator metadata

Suggested detail layout:

```text
Read by Elizabeth Klett >
Solo Narration
```

The `Solo Narration` line should be near narration metadata, not grouped with genre or storage status.

## Search And Catalog Filters

Add a `Solo Narration` checkbox/toggle to:

- Search tab remote catalog results.
- Explore collection result lists.
- CatalogDiscovery screens launched from More by Author, More by Narrator, and More by Genre.
- Listen recommendations.
- Local Library search/filter controls.

Behavior:

- Local library solo filtering uses `BookWithChapters.narrationKind`.
- Remote catalog solo filtering uses only confident search metadata available in `InternetArchiveSearchResult`.
- If remote reader metadata is missing, exclude the item when the solo-only filter is enabled.
- If remote metadata says `solo version` but does not resolve to a single reliable reader or equivalent strong solo signal, exclude it.
- Existing query mode behavior remains unchanged when the toggle is off.

## Remote Import Loading Feedback

Extend `InternetArchiveResultRow`:

```swift
struct InternetArchiveResultRow: View {
    let result: InternetArchiveSearchResult
    var isLoading: Bool = false
}
```

Render `BookListRow` accessory as `.loading` for the importing row:

```swift
InternetArchiveResultRow(
    result: result,
    isLoading: importingIdentifier == result.identifier
)
.disabled(importingIdentifier == result.identifier)
```

Apply this pattern to:

- Search
- Explore
- CatalogDiscovery

For Listen horizontal recommendation cards:

- Store the same `importingIdentifier`.
- On card tap, set it immediately before metadata import begins.
- Show a small `ProgressView` and dim overlay only for the tapped card.
- Disable only that card while it imports.

Acceptance criteria:

- A remote result tap produces visible loading feedback in the same row or card before network import completes.
- Other rows remain tappable while one result imports.
- No import surface uses `.disabled(importingIdentifier == ...)` without also rendering a visible loading indicator.
- Loading state clears on success and failure.

## Tactile Feedback

Add a design-system tactile layer:

```swift
enum TactileFeedback {
    static func tap() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
}
```

Add a view modifier:

```swift
extension View {
    func tactileTap() -> some View {
        simultaneousGesture(TapGesture().onEnded { TactileFeedback.tap() })
    }
}
```

Apply `tactileTap()` to:

- app `Button` activations
- `NavigationLink` rows and icon buttons
- menu trigger controls
- row/card tap surfaces implemented with `onTapGesture`
- custom shared buttons in `VoxglassComponents`
- player sheet action icons where the app owns the control

Do not apply to:

- text field focus
- drag gestures
- sliders
- scroll views
- picker segment changes
- system route picker internals

Existing explicit haptics in player controls may be migrated to `TactileFeedback.tap()` or intentionally retained if the effect is different and covered by a source guard.

## Implementation Checklist

1. Core classification
   - Add `NarrationKind`.
   - Add `NarrationClassifier` or extend `NarratorExtractor` with solo classification helpers.
   - Add derived `narrationKind` properties to `Book`, `BookWithChapters`, and `InternetArchiveSearchResult`.
   - Expand ambiguous-term rejection in narrator extraction.

2. Design system
   - Add `TactileFeedback`.
   - Add `tactileTap()` view modifier.
   - Add `SoloNarrationBadge`.
   - Add or reuse a loading accessory in `BookListRow`.

3. Remote result rows
   - Add `isLoading` to `InternetArchiveResultRow`.
   - Pass `isLoading: importingIdentifier == result.identifier` from Search.
   - Pass `isLoading: importingIdentifier == result.identifier` from Explore.
   - Pass `isLoading: importingIdentifier == result.identifier` from CatalogDiscovery.
   - Ensure disabled state is scoped to the importing identifier.

4. Listen recommendations
   - Add solo-only toggle.
   - Apply remote solo filter.
   - Add card loading overlay and per-card disabled state.
   - Add solo badges to cards.

5. Local library
   - Add solo-only toggle to Library search/filter controls.
   - Apply `BookWithChapters.narrationKind`.
   - Show badges through shared row components.

6. Detail surfaces
   - Show `Solo Narration` near the narrator line in Book Page / Now Playing.
   - Keep mixed or unknown unmarked.

7. Tactile coverage
   - Apply `tactileTap()` or shared wrapper usage across app buttons, navigation rows, menus, and tappable cards.
   - Avoid text inputs and drag/slider gestures.

8. Docs
   - Add this plan.
   - Add `docs/mockups/narration-feedback.html`.
   - Link the mockup from `docs/mockups/index.html`.

## Test Plan

Run all relevant tests:

```sh
swift test
scripts/guard_wiring.sh
xcodebuild build -project Voxglass.xcodeproj -scheme Voxglass -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO
```

Add pure unit tests:

- `Read by Expatriate` returns `.solo`.
- `Read by Carl Banks` returns `.solo`.
- Multiple names return `.mixedOrUnknown`.
- Missing reader returns `.mixedOrUnknown`.
- `volunteers`, `cast`, `various`, `group`, and `dramatic reading` return `.mixedOrUnknown`.

Add source/UI guard tests:

- Search remote rows pass `isLoading: importingIdentifier == result.identifier`.
- Explore remote rows pass `isLoading: importingIdentifier == result.identifier`.
- CatalogDiscovery remote rows pass `isLoading: importingIdentifier == result.identifier`.
- Row/card loading state renders `ProgressView`.
- No remote import surface silently disables a result without a loading indicator.
- `Solo Narration` appears through shared book row/card components.
- Book Page metadata includes `Solo Narration` when narration is classified as solo.
- Search, Explore, CatalogDiscovery, Listen, and Library surfaces contain the solo-only toggle.

Add haptic source guard tests:

- Shared buttons use `tactileTap()` or invoke `TactileFeedback.tap()`.
- `NavigationLink` item surfaces use `tactileTap()` or a shared wrapper.
- Existing explicit haptics in player controls are migrated or named as intentionally retained.

## Acceptance Criteria

- Every tappable app action has tactile feedback unless it is a text input, slider, drag, scroll, picker segment, or system gesture.
- Tapping a remote catalog row/card gives immediate visible loading feedback on that exact item.
- Only the importing remote item is disabled.
- Books with one plausible narrator show `Solo Narration` in lists/cards and near the narrator line on detail surfaces.
- Books with missing, mixed, cast, volunteer, group, dramatic, various, or unknown narration show no narration badge.
- Solo-only filtering is available in local Library, Search, Explore, CatalogDiscovery, and Listen.
- Remote solo filtering is conservative and excludes unknown reader metadata.
- The docs and mockups can be opened directly from disk for review.

## Risks And Mitigations

- Risk: free-form Internet Archive descriptions can be inconsistent.
  Mitigation: classify as solo only from strong reader extraction or reliable structured metadata.

- Risk: haptic modifiers attached too high in the view tree could fire for non-action taps.
  Mitigation: apply at explicit action controls and shared action wrappers only.

- Risk: adding badges at every call site could drift.
  Mitigation: prefer shared `BookListRow`, `CompactBookRowView`, and horizontal card entry points.

- Risk: row loading indicators could be missed on a catalog surface.
  Mitigation: add source guards for every `.disabled(importingIdentifier == ...)` import path.
