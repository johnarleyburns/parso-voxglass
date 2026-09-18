# Voxglass consumer navigation redesign

## Objective

Make the listening experience feel direct and low-complexity by giving each primary destination one clear job:

1. **Listen** — continue listening and receive recommendations.
2. **My Books** — manage books the user has saved or imported.
3. **Discover** — find new books through one combined search and browse surface.
4. **Narration** — create and manage narrated audiobooks.

The primary change is to remove the standalone Search tab. Search remains highly visible inside Discover, while My Books keeps a contextual search for saved books only.

## Why this change

The current shell exposes five destinations: Listen, My Books, Explore, Search, and Narration. The two catalog destinations overlap:

- Explore contains featured collections, collection-specific search, sorting, filters, descriptions, and download actions.
- Search contains global catalog search, search scope, and narration filtering.
- Both surfaces show the same catalog rows and start playback when a result is tapped.

This asks users to decide where to search before they know the difference. The product comparison supports a simpler model: Audible makes search available from Home, Library, and Discover; Spotify places audiobooks inside Home, Search, and Library rather than creating a separate audiobook hierarchy; Apple Books uses five top-level destinations because it combines ebooks, audiobooks, and a storefront.

Sources:

- [Audible app navigation guide](https://www.blindios.uk/audio-books/audible)
- [Audible discovery improvements](https://www.audible.com/about/newsroom/these-new-audible-enhancements-mean-less-searching-and-more-listening)
- [Spotify audiobook launch](https://newsroom.spotify.com/2022-09-20/with-audiobooks-launching-in-the-u-s-today-spotify/)
- [Spotify audiobook discovery support](https://support.spotify.com/us/article/audiobooks-access-plan/)
- [Apple Books navigation](https://support.apple.com/en-ca/guide/iphone/iphc1af7c57/ios)

## Product principles

- **One place to continue.** Listen opens on the next useful action, not a dashboard of secondary information.
- **One place for saved content.** My Books never mixes the personal library with catalog browsing.
- **One place to find new content.** Discover combines direct search and editorial browsing.
- **Actions should be explicit.** Play, Add to My Books, and Download should not be hidden behind an unexpected transition or an unlabeled icon.
- **Progressive disclosure.** Keep the common path visible; move sort, advanced filters, batch download, and management actions behind contextual controls.
- **Local state should stay local.** A filter changed in My Books should not silently change Search or Discover.

## Target information architecture

### Listen

Primary job: get the user listening quickly.

Recommended order:

1. Continue listening card with a large `Resume` action.
2. Recently played / Jump Back In.
3. Recommended for You.
4. Listening stats below the listening content, or in Profile/Settings.

Keep the persistent mini-player above the tab bar. Keep Settings accessible from the header, but do not let supporter status or statistics compete with Resume.

### My Books

Primary job: find, resume, download, and manage saved books.

Default surface:

- Search icon or compact inline search labeled `Search My Books`.
- Simple progress control: `All`, `In Progress`, `Finished`.
- Rows with artwork, title, author, progress, and a visible `Resume`/`Play` action.
- A clear add/import action.

Move into one Filter or More control:

- Favorites.
- Downloaded books (fully cached for offline listening).
- Solo Narration.
- My Narration / Created by me.
- Sort order.
- Edit/reorder.
- Apple Watch and storage actions when needed.

Do not merge My Books search with catalog search. The user intent is different and the result state should make that clear.

### Discover

Primary job: help the user find something new.

Default surface:

- Prominent search field: `Search books, authors, or narrators`.
- Featured collections.
- Recommended categories or editorial shelves.
- Optional recent searches.

After a collection is selected, represent it as a collection detail state or filter chip. Do not show a second unrelated search field. Hide sort, collection descriptions, narration-type filters, and `Download All` under a contextual Filter/More control.

### Narration

Keep Narration as a separate destination because it is a distinct creation workflow with different goals, terminology, and state. Its entry screen should explain the next step and keep production complexity inside the project flow rather than in the global consumer shell.

## Result interaction model

Unify catalog results from Discover and recommendations:

- Tapping the row opens a lightweight book preview/detail page.
- Primary action: `Play` or `Resume`.
- Secondary action: `Add to My Books`.
- Optional action: `Download`.
- Small trailing play button may provide immediate playback without hiding the detail page.
- Clear state labels: `In My Books`, `Downloaded`, `Previewing`.

This replaces the current pattern where tapping a catalog row immediately starts playback and the add action is only discoverable as a plus icon on the resulting book/player page.

## Implementation phases

### Phase 1 — Shell and routing

- Replace the five-item consumer navigation model with four destinations.
- Rename the internal `.home` case to `.listen` for consistency with the visible label.
- Remove the standalone Search tab.
- Route Discover to the existing catalog store and recommendation/catalog result components.
- Preserve per-tab navigation stacks and the mini-player.
- Remove the unused `selectLibrary` callback passed into `ListenView`.

Likely files:

- `Voxglass/App/RootView.swift`
- `Voxglass/Features/Chrome/GlassDock.swift`
- `Voxglass/Features/Listen/ListenView.swift`
- `Voxglass/Features/Discover/DiscoverView.swift`
- `Voxglass/Features/Search/SearchView.swift`

### Phase 2 — Unified Discover

- Move the global Search field into Discover.
- Keep one catalog result state for direct search and collection browsing.
- Replace collection search with a collection filter/detail state.
- Move sort, narration-type filtering, descriptions, and batch download into contextual controls.
- Preserve separation between Discover results and My Books.

### Phase 3 — Explicit book actions

- Create or adapt a shared catalog book preview component.
- Make `Play`, `Add to My Books`, and `Download` explicit.
- Keep pending preview books out of My Books until the user confirms Add.
- Add accessibility labels and identifiers for each action.
- Preserve current playback-position and pending-book semantics.

### Phase 4 — Simplified My Books

- Keep a simple default filter row.
- Move advanced filters into one sheet/menu.
- Keep local search explicitly scoped to My Books.
- Make resume/play visible in each row.
- Move Apple Watch and storage controls into the row menu or detail page.
- Replace the shared `soloOnlyEnabled` behavior with contextual state unless a global preference is deliberately retained.

### Phase 5 — Listen refinement and chrome QA

- Promote Continue Listening above stats and recommendations.
- Move stats lower in the page or into Settings/History.
- Verify selected tab state has both color and shape/background differentiation.
- Verify the mini-player and custom tab bar maintain 44-point interaction targets.
- Audit bottom content clearance. The current root and shared screen both reserve 136 points, so confirm there is no unnecessary blank space below content.

## Acceptance criteria

### Navigation

- The consumer shell exposes exactly four primary destinations: Listen, My Books, Discover, Narration.
- Search is reachable immediately from Discover without a separate tab.
- Each tab preserves its navigation state when switching tabs.
- The mini-player remains available above the tab bar.

### Discover

- A user can search by title, author, or narrator without choosing between Explore and Search first.
- Featured collections remain available without requiring a search.
- Collection browsing and direct search use one coherent result presentation.
- Advanced controls are hidden until requested.

### My Books

- My Books search returns only saved/imported books.
- Catalog search does not silently add books to My Books.
- A user can resume or play a book from the row without opening a management menu.
- Storage, Watch, sorting, and edit actions remain available but do not dominate the default view. The More menu's Downloaded refinement shows fully cached saved books and explains when none are available offline.

### Book actions

- Every catalog result opens an obvious paused preview with Play and Add to My Books actions.
- Pending preview books remain hidden from My Books until Add is confirmed.
- Existing playback, download, watch, and history behavior continues to work.

### Accessibility and regression coverage

- Every primary navigation item exposes a stable accessibility label and selected state.
- Search fields state their scope: catalog search versus My Books search.
- The local iPhone smoke test visits all four tabs and verifies Discover search. Host/source contracts cover My Books search, paused preview actions, and mini-player presentation without requiring nondeterministic catalog or playback fixtures in the smoke path.
- Existing playback, CarPlay, Watch, and narration tests remain green.

## Mockup

Open [`mockup.html`](./mockup.html) for a single interactive mockup of the proposed shell. It demonstrates:

- Four-item navigation.
- Listen focused on Continue Listening.
- My Books with simple filters and explicit resume actions.
- Discover combining search and curated browse.
- A book preview with explicit Play and Add to My Books actions.
- Narration kept as a separate workflow.
