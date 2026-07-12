# Voxglass UI & Backend Cleanup Plan

## A. Search Tab Double-Click Focus Fix

**File:** `Voxglass/Features/Search/SearchView.swift`
- **Line 59-63:** Add `.contentShape(Rectangle())` to the `searchPanel` HStack after `.frame(height: 40)` and before `.glassSurface(cornerRadius: 20)`
- The TextField at font size 15 is ~20-24px tall inside a 40px HStack, leaving dead space above/below. `.contentShape(Rectangle())` makes the entire HStack frame hittable and forwards taps to the TextField.

## B. Remove Explore Tab Add Panels

**File:** `Voxglass/Features/Discover/DiscoverView.swift`
- Remove `import UniformTypeIdentifiers` (line 2)
- Remove `@State private var showingImporter = false` (line 11)
- Remove `@State private var archiveURL = ""` (line 12)
- Remove `addArchiveURLPanel` from body (line 19)
- Remove `importPanel` from body (line 20)
- Remove `.fileImporter(isPresented: $showingImporter, ...)` modifier (lines 25-31)
- Remove `addArchiveURLPanel` computed var (lines 67-107)
- Remove `importPanel` computed var (lines 109-141)
- Remove `addArchiveURL()` method (lines 207-214)
- Remove `handleImportResult()` method (lines 216-227)

## C. Remove Playback Section

**File:** `Voxglass/Features/Settings/SettingsView.swift`
- Remove `settingsGroup("Playback")` block (lines 23-28):
  - "Background Audio"
  - "AirPlay"
  - "Sleep Timer"
  - "Playback Speed"

## D. Remove Tips & Support Section

**File:** `Voxglass/Features/Settings/SettingsView.swift`
- Remove `settingsGroup("Tips & Support")` block (lines 35-38):
  - "Tip Jar"
  - "Support"

## E. Remove SourcesView Sections

**File:** `Voxglass/Features/Settings/SettingsView.swift`
- Remove `sourceList` from SourcesView body (line 228)
- Remove `placeholders` from SourcesView body (line 229)
- Remove `sourceList` computed var (lines 287-305) — "Connected Sources"
- Remove `placeholders` computed var (lines 307-328) — "Available Later" (Local Files, iCloud Drive)
- Remove `errorBinding` (lines 330-339)
- Remove `bookCount(for:)` (lines 341-343)
- Remove `SourceRow` private struct (lines 355-414)
- Remove `.task { await libraryStore.refresh() }` modifier (lines 246-248)

## F. Move License + Version to About Page

**File:** `Voxglass/Features/Settings/SettingsView.swift`
- Remove from SettingsView body (lines 52-53):
  - `MoreInfoRow(icon: "doc.text.fill", title: "License", detail: "GPLv3")`
  - `MoreInfoRow(icon: "number", title: "Version", detail: "1.1")`
- Add to AboutView body: new section with License and Version info, reading version dynamically from `Bundle.main`

## G. Reorder: Library (Sources) Below Cache

**File:** `Voxglass/Features/Settings/SettingsView.swift`
- Move `settingsGroup("Library")` block (lines 9-21) to be below the "Downloads & Cache" section (lines 30-33)

## H. Remove Dead MoreInfoRow Struct

**File:** `Voxglass/Features/Settings/SettingsView.swift`
- Remove `MoreInfoRow` private struct (lines 416-443) — no callers remain after removing Playback, Tips, License, and Version rows

## I. Unify Library + Explore List Item Layouts

### CompactBookRowView (Library)
**File:** `Voxglass/DesignSystem/VoxglassComponents.swift` (lines 166-196)
- Artwork: `size: 46` → `size: 56`, `cornerRadius: 9` → `cornerRadius: 12`
- Title: add `.lineLimit(2, reservesSpace: true)` and `.minimumScaleFactor(0.82)` (keep both)
- Add `.frame(minHeight: 80)` before glassSurface
- Add explicit accessibility

### InternetArchiveResultRow (Explore/Search)
**File:** `Voxglass/Features/Search/SearchView.swift` (lines 133-188)
- Artwork: `size: 48` → `size: 56`, `cornerRadius: 9` → `cornerRadius: 12`
- Title: add `.minimumScaleFactor(0.82)`
- Min height: `84` → `80`
- Remove `.frame(maxWidth: .infinity, alignment: .leading)` on VStack (matches Library which doesn't have it)

Final unified values:
| Property | Value |
|---|---|
| Artwork | 56x56, cornerRadius 12 |
| HStack spacing | 12 |
| Padding | 12 |
| Glass cornerRadius | 14 |
| Title | 14pt medium, lineLimit(2, reservesSpace: true), minimumScaleFactor(0.82) |
| Subtitle | 11.5pt, ink3 |
| Meta line | 11.5pt, ink3 |
| Min height | 80 |

## J. Backend Cleanup

### LibraryStore
**File:** `Voxglass/Core/Library/LibraryStore.swift`
- Remove `importLocalAudio(from:)` (lines 56-68)

### LibraryRepository
**File:** `Voxglass/Core/Library/LibraryRepository.swift`
- Remove `importLocalAudio(from:)` (lines 98-128)
- Remove `ensureLocalFilesSource()` (lines 207-228)
- Remove `importer` property (line 12)
- Remove `importer` from init parameter (line 14)

### LocalAudioImporter
**File:** `Voxglass/Core/Library/LocalAudioImporter.swift`
- Delete entire file (lines 1-112) — no callers remain

## Expected Test Impact
- `InternetArchiveCatalogTests.testArchiveURLParser*` — stays (parser is still used by SourcesView)
- `InternetArchiveCatalogTests.testInternetArchiveImportRoundTrips*` — stays (uses `importInternetArchiveItem`)
- `LibraryRepositoryTests` — stays (uses `.localFiles` only as DB seed, enum case preserved)
- No new tests needed for UI changes
