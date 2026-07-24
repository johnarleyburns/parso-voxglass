# Voxglass — Unified Book Page Plan

**Mockups:** [`docs/mockups/unified-book-page.html`](mockups/unified-book-page.html)

## Context

Voxglass currently shows the same book in two places that disagree with each other.

- `Voxglass/Features/Player/NowPlayingView.swift` (700 lines) — cover, title, author, narrator, chapter, genre chip,
  scrubber, transport, a six-icon action bar, the full chapter list, and "Discover More" links.
- `Voxglass/Features/Library/BookDetailView.swift` (410 lines for `BookDetailView` itself) — cover, title, author links,
  narrator line, provenance chip, a **full-width 2×2 grid of 46 pt buttons** (Favorite / Offline / Playlist / Share),
  the summary, tags, a narrators section, a 6-chapter preview, bookmarks row, and "All Chapters".

Neither is complete. Now Playing has no summary, no share, no playlist, no provenance, no tappable author. Book Details has
no scrubber, no speed, no sleep timer, no bookmark button, no EQ, and no AirPlay. Users bounce between them and the two
screens duplicate the same `currentBook` resolution, the same cellular-download confirmation dialog, the same
remove-offline confirmation, the same bookmarks sheet, and the same offline state machine — twice, with drifting details.

Neither screen has an **AirPlay route picker at all**. Grepping the app finds exactly one AirPlay reference:
`AVPlayerAudioEngine.swift:159` sets `.allowAirPlay` on the audio session. There is no `AVRoutePickerView` anywhere, so
today the only way to move audio to a HomePod is through Control Center.

**Intended outcome:** one screen, `BookPageView`, that is the single destination for a book everywhere in the app — from
My Books, from a playlist, from the mini-player, from Siri. It carries every feature from both screens, always shows author
and narrator, clamps the description to one line with a **Show more** control placed immediately above the chapter list,
replaces every full-width action button with a 40 pt icon, adds AirPlay, and hides the long tail behind a `⋯` overflow menu.

---

## Target design

### One layout, two states

The page renders identically whether or not this book is the active session. Only the transport block differs, so there is
no visual jump when playback starts.

| | `.playing` — this book is `playback.currentSession?.book.id` | `.browsing` — any other book |
|---|---|---|
| Scrubber | live, draggable | saved resume position, brass tint, not draggable until play |
| Centre button | white ⏸/▶ | brass **▶** (primary action) |
| Side transport | active | 42% opacity, still tappable (starts playback then acts) |
| Chapter line | current chapter title | `Resume · 5. Riddles in the Dark`, or `19 chapters` if unstarted |
| Cover | 214 pt | 190 pt with a 48% progress ring |

State is derived, never stored:

```swift
private var isActiveSession: Bool { playback.currentSession?.book.id == book.book.id }
```

### Vertical order

1. Grabber (sheet) or back chevron (pushed) + breadcrumb
2. Cover, with `ProvenanceChip` bottom-left (reuse from `VoxglassComponents.swift`) and progress ring in `.browsing`
3. **Title / Author › / Read by … › / chapter line** — author and narrator are always present and always tappable
   (`AuthorDetailView`, `NarratorDetailView`, both already in `BookDetailView.swift`)
4. Chip row: genre (from `LibriVoxBrowseCategory.category(forSubjects:)`), chapter count, download state, "Public domain"
5. Scrubber + `17:43 / 6h 12m left in book / -22:17`
6. Transport: ⏮ ↺15 ⏯ ↻30 ⏭
7. **Icon action row** (below)
8. **About** — one clamped line + `Show more ⌄`
9. **Chapters** — full list, current row highlighted, per-chapter narrator via `NarratorDisplay.chapterLine`,
   then `Bookmarks (n)` and `All Chapters` rows
10. **Discover more** — existing `discoveryLink` rows

The About block sits directly above Chapters, which is what puts "Show more" "down by the chapters" as requested. Expanding
it pushes the chapter list down; it does not open a sheet.

### Icon action row

Seven 40 pt icons on a 44 pt hit target, evenly spread, with 8.5 pt captions:

`1.0×` Speed · `☾` Sleep · `🔖` Bookmark · `♥` Favorite · `⤓` Offline · `􀉦` AirPlay · `⋯` More

- **Speed / Sleep / Bookmark / Favorite / Offline** — move over from `NowPlayingView` unchanged, including the
  progress-ring download button and its `.downloading/.cached/.failed` cases, and all `nowplaying.*` accessibility
  identifiers (keep the identifiers; UI tests and future automation depend on them).
- **AirPlay — new.** `Voxglass/Features/Player/RoutePickerButton.swift`, a `UIViewRepresentable` wrapping
  `AVRoutePickerView` with `activeTintColor = Palette.brass`, `tintColor = white 0.6`, sized 40×40.
- **⋯ More** — opens the overflow sheet.

Under accessibility text sizes the row degrades through `ViewThatFits` to
`Speed · Favorite · AirPlay · ⋯`, and Sleep/Bookmark/Offline move into the overflow. Nothing shrinks below 44 pt.

### Overflow sheet (`⋯`)

Everything that used to be a full-width button or a second screen:

| Section | Rows |
|---|---|
| This book | Share (`ShareLink`, was a 46 pt button), Add to Playlist… (`AddToPlaylistSheet`), Bookmarks (n), All Chapters |
| Audio | Equalizer (`EQView`), Volume normalization toggle |
| Discover | More by *author*, More read by *narrator*, More in *genre* |
| Manage | Remove offline copy (destructive), Remove from My Books (destructive) |

Both destructive rows keep their existing `confirmationDialog` copy verbatim.

---

## Implementation

### New files

| File | Contents |
|---|---|
| `Voxglass/Features/Player/BookPageView.swift` | The unified page. Public init: `BookPageView(book: BookWithChapters?, showingNowPlaying: Binding<Bool>)`. `book == nil` means "whatever is playing" (the sheet case). |
| `Voxglass/Features/Player/BookPageOverflowSheet.swift` | The `⋯` sheet. |
| `Voxglass/Features/Player/RoutePickerButton.swift` | `AVRoutePickerView` wrapper. |
| `Voxglass/Features/Player/BookPageActionRow.swift` | Icon row + `ViewThatFits` degradation, so the row is unit-testable in isolation. |

### Resolution of the displayed book

Both existing screens already compute this; hoist one copy into `BookPageView`:

```swift
private var resolved: BookWithChapters? {
    if let book { return libraryStore.book(withID: book.book.id) ?? book }
    guard let s = playback.currentSession else { return nil }
    return libraryStore.book(withID: s.book.id) ?? BookWithChapters(book: s.book, chapters: s.chapters)
}
```

(`NowPlayingView.currentBook` at `NowPlayingView.swift:131` and `BookDetailView.currentBook` at `BookDetailView.swift:19`
are the two originals.)

### Call sites to change

`BookDetailView(book:showingNowPlaying:)` → `BookPageView(book:showingNowPlaying:)` at:

- `Voxglass/Features/Library/LibraryView.swift:63`
- `Voxglass/Features/Listen/ListenView.swift:81`, `:111`
- `Voxglass/Features/Library/BookDetailView.swift:491`, `:549` (inside `AuthorDetailView` / `NarratorDetailView`)
- `Voxglass/Features/Library/PlaylistsView.swift` (playlist rows)

`NowPlayingView()` → `BookPageView(book: nil, showingNowPlaying: $showingNowPlaying)` at
`Voxglass/App/RootView.swift:74`.

### Files retained, moved, deleted

- **Delete** `NowPlayingView` (the struct; keep `NowPlayingView.authorQuery/narratorQuery/genreQuery` by moving them to
  `BookPageView` as statics — `CatalogDiscoveryView` and tests reference them).
- **Keep, move to a new `Voxglass/Features/Library/BookRelatedViews.swift`**: `ChaptersView`, `AuthorDetailView`,
  `NarratorDetailView`, `ChapterRow`, `AddToPlaylistSheet` — all currently living at the bottom of `BookDetailView.swift`.
- **Delete** `BookDetailView` itself once the call sites move.
- **Unchanged**: `CatalogBookDetailView` (`Features/Discover/DiscoverView.swift` etc.) — that is the *remote, not-yet-imported*
  catalog result page and is a different job. It gains one thing: after import it pushes `BookPageView` rather than
  `BookDetailView`.
- **Unchanged**: `MiniPlayerView`, `GlassDock`, all of `VoxglassCore`.

### Behaviours that must survive the merge

Checklist for review — each one exists today in exactly one of the two screens:

- [ ] `RecentlyViewedBooksStore.recording(bookID:in:)` on appear (was `BookDetailView.swift:59`)
- [ ] Genre load via `libraryStore.bookSubjects(for:)` + `LibriVoxBrowseCategory.category(forSubjects:)` (was `NowPlayingView.swift:126`)
- [ ] Cellular confirmation dialog before whole-book download, including the `cacheFullBooksOnCellular` default write
- [ ] Remove-offline confirmation; remove-from-My-Books confirmation + `dismiss()`
- [ ] Bookmark haptic (`UIImpactFeedbackGenerator`) then present bookmarks sheet
- [ ] `playback.bookmarkCount ?? bookmarkCount` bookmarks row, hidden at 0
- [ ] `session.bookRemaining` "left in book" label
- [ ] Sleep timer countdown rendered *inside* the icon (`moon.zzz.fill` + `12m`)
- [ ] Skip interval labels driven by `AppPreferencesStore.Keys.skipBackInterval/skipForwardInterval` and `SkipSymbol`
- [ ] Scrub gesture semantics: `isScrubbing` latch, seek on `.onEnded` only
- [ ] All `nowplaying.speed / .sleepTimer / .bookmark / .favorite / .download / .eq` accessibility identifiers
- [ ] `libraryDetailLine(sourceTitle:)` detail line and `ProvenanceChip`

---

## Tests

This repo already asserts UI structure by reading source text (`ArtworkPresentationTests`, `DynamicTypeGuardTests`).
Follow that pattern in a new `VoxglassTests/BookPageUnificationTests.swift`:

1. `testLegacyDetailAndNowPlayingViewsAreGone` — no file under `Voxglass/Features` declares `struct NowPlayingView` or
   `struct BookDetailView`, and no file contains `BookDetailView(book:`.
2. `testBookPageKeepsAccessibilityIdentifiers` — `BookPageView.swift` + `BookPageActionRow.swift` contain all six
   `nowplaying.*` identifiers.
3. `testBookPageExposesAirPlay` — `RoutePickerButton.swift` contains `AVRoutePickerView`, and the action row references it.
4. `testActionRowUsesIconsNotFullWidthButtons` — the action row source contains no `SecondaryActionButton`,
   no `PrimaryActionButton`, and no `.frame(height: 46)`.
5. `testDescriptionIsClampedWithShowMore` — `BookPageView.swift` contains `lineLimit(isDescriptionExpanded ? nil : 1)`
   and the `Show more` string.

Update `ArtworkPresentationTests.swift:75`, which currently reads `Voxglass/Features/Library/BookDetailView.swift`,
to read the new page. Existing `MiniplayerRestoreTests` and `NowPlayingArtworkTests` are Core-level and unaffected.

---

## Verification

1. `swift build` then `xcodegen && xcodebuild -scheme Voxglass -destination 'platform=iOS Simulator,name=iPhone 16' build`
2. `swift test` — includes the new source-guard tests.
3. On device/simulator, walk the matrix:
   - My Books → book **not** playing → page shows brass ▶, resume position, one-line About.
   - Tap ▶ → same page, no layout jump, scrubber goes live.
   - Mini-player → sheet → identical page for the same book.
   - Tap **Show more** → description expands in place, chapter list moves down, tap **Show less** → collapses.
   - `⋯` → Share sheet appears; Add to Playlist works; Remove offline copy shows the existing dialog.
   - AirPlay icon → route picker lists AirPods/HomePod; picking one moves audio and the icon turns brass.
   - Dynamic Type at AX3 → row degrades to 4 icons, no clipping, all targets ≥ 44 pt.
   - VoiceOver → author, narrator, and every icon announce; the `nowplaying.*` identifiers still resolve.
4. Kill and relaunch mid-chapter: position is unchanged (the merge must not touch `PlaybackCoordinator`).
