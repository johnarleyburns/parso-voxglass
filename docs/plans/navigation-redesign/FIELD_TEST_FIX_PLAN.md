# Field-testing UI and Gutenberg fix plan

## Goal

Make the four primary surfaces feel direct in field use without removing capability:

- My Books keeps progress navigation obvious and stable while moving secondary actions into the header.
- Listen keeps the playback surface focused by removing non-actionable “Good listening” copy.
- Discover leads with search and useful collections instead of an inert catalog section.
- Narration opens on the user’s work, with explanations and community discovery available when needed.
- Project Gutenberg failures become reproducible, diagnosable, and safe to retry.

This plan is intentionally scoped to the field findings. It preserves the existing four-tab information architecture and the current underlying catalog, narration, download, and project models.

## 1. My Books header and filter behavior

### User-facing change

The My Books header will read and operate in this order:

`My Books        Search   +   More`

- Search moves from the filter row into the top header, before `+`.
- `+` keeps its current add/import behavior.
- More moves into the top header, after `+`.
- The filter row contains only the always-available `All / In Progress / Finished` segmented control.
- Opening More exposes the existing sort, edit-order, and refinement actions without changing the primary progress selection.

### State/model change

Separate the primary progress selection from secondary refinements. The progress control must always have exactly one selected value:

- `all`
- `inProgress`
- `finished`

Favorites, Downloaded, Solo Narration, and Created by me become independent refinements applied after the selected progress scope. Selecting or clearing one must never write an advanced value into the progress picker and must never leave the picker with no selected segment.

Keep repository compatibility where possible. If `LibraryBookFilter` is still needed by persistence or repository APIs, retain it as an internal/data-layer concern and add an explicit progress/refinement representation for the view/store instead of making the UI picker bind to the mixed enum.

The filtered list should be composed in a deterministic order:

1. repository-visible books for the selected progress scope;
2. downloaded/favorite/solo/created-by-me refinements;
3. search query and scope;
4. user sort/order.

Empty states must name the active constraint. For example, a downloaded refinement with no matches should say “No Downloads Yet,” while a solo refinement over an otherwise populated scope should say that no solo narrations match. Turning off a refinement must restore the previous list and progress selection.

### View/API change

Extend `VoxglassScreen` with a generic trailing-header actions slot, or an equivalent small header-action abstraction, rather than adding screen-specific positional exceptions. It must support the My Books sequence while preserving Discover’s history action and all other existing screens.

Use stable accessibility identifiers for the new header controls, retaining the existing identifiers where possible:

- `library.searchButton`
- `library.addButton` (new explicit identifier for `+`)
- `library.moreMenu`
- `library.booksSearch`
- the three progress segment labels/values

Remove the duplicate Search and More controls from `filterBar`; do not leave hidden duplicate hit targets in the view hierarchy.

## 2. Discover simplification and collection hierarchy

### Remove the inert catalog section

When there is no query, no selected collection, and no active catalog result state, Discover should show the search field and Featured Collections only. Remove the “Browse the catalog” section title and its empty-state copy because it does not perform an action.

Keep result content for the states that have a clear cause:

- query submitted: `Search Results`;
- collection selected: the selected collection title and results;
- in-flight search: progress state;
- failed search: the existing error/retry path.

Avoid replacing the removed section with another placeholder heading.

### Compact Featured Collections cards

Replace the current tall, horizontally scrolling card treatment with a compact stacked collection list. Each card should be a wide, tappable row with:

- a smaller artwork region occupying roughly the left half of the card;
- the collection name, description, and approximate book count in the right half;
- the curated badge, when applicable, kept within the artwork or metadata column;
- a single consistent card height that works for short and long descriptions;
- selection styling that does not change the card’s geometry.

Preserve resolved covers, approximate counts, collection selection, accessibility labels, and the existing collection sort/download behavior. Use a shared line limit and fixed artwork aspect ratio so cards do not become tall because of text wrapping.

### Selected collection controls

Normalize the selected-collection pill and `Filter & sort` control to the same height, vertical padding, corner radius, and baseline alignment. Put the selected collection name on its own control row with `About` right-justified on that same row. Keep `Filter & sort` in the adjacent controls row; it remains the direct place for search scope, solo narration, and collection sort.

The `About` control should reveal the existing collection description/curated status/download-all information in place. Its label can switch to `Less` while expanded, but it must remain right-aligned and must not compete with the collection title or change the height of the filter control.

Use identifiers for the selected collection control and the About action so the layout and expansion state can be tested without relying on text positions.

## 3. Listen surface density

Remove the Listen page’s “Good listening” section and its detail text. Keep the actionable playback/history/library content that follows it in the same order and preserve any stable accessibility identifiers for those actions. The initial Listen surface should open directly on useful listening content instead of a purely explanatory section.

## 4. Narration home and New Narration flow

### Narration home order and density

Reorder the Narration tab so that, once the user has started at least one narration, it reads:

1. My Narrations
2. Start a Narration

My Narrations must be conditionally hidden until `discovery.myNarrations` contains at least one project with recorded content (`recordedCount > 0`). A draft or imported project alone does not count as having started a narration. Do not show an empty My Narrations section or empty-state card to a first-time user; the Start a Narration experience should be the first meaningful content instead. Once the user has started recording, show My Narrations above Start a Narration, remove its explanatory detail line, and retain the section title, edit action, and project rows.

The Start a Narration section keeps its actions and rails, but remove the long explanatory detail text from the default surface. Add a right-justified `About` action on the same row as `Start a Narration`. About reveals the removed explanation in a compact in-place disclosure or sheet, using the existing copy and preserving the commercial-introduction dismissal behavior.

Remove the home-level `Browse community needs` button/card and the default card rendered below it. The Narration tab should not duplicate the full community-needs browser.

### Move community needs into New Narration

In the New Narration flow, change the existing `From a Narration Need` entry point to `Browse narration needs` (sentence case). That action should open the existing, more extensive `NarrationNeedsView` rather than the smaller/default view currently exposed from the Narration home.

Preserve the complete needs experience: freshness state, filters, rows, source metadata, and the Start action that carries the selected `NarrationNeed` into the recording flow. The new route should provide an obvious Back/Close path and should not create a second copy of the needs data or filters.

Remove obsolete `presentBrowse` plumbing from the Narration home once the flow is moved. Keep navigation state for a selected need separate from the New Narration presentation state so a selected need still opens `NarrationFlowRoot(startNeed:)` correctly.

## 5. Project Gutenberg reliability and regression coverage

The current `GutendexNeedsSource` has decode coverage for poetry, prose, missing copyright, author formatting, and Gutenberg URLs, but no test exercises the user-reported “Project Gutenberg” path through the source request/error boundary. Add coverage before changing behavior so the actual failure is fixed rather than masked.

### Required test cases

Add deterministic, fixture-driven tests in the existing Gutenberg test suite:

1. A representative Project Gutenberg response decodes into a narratable need, with:
   - title and `Project Gutenberg`/Gutenberg source URL preserved;
   - author normalized correctly;
   - public-domain eligibility retained;
   - usable HTML/text source and EPUB URL selection;
   - stable signal/provenance.
2. A fake HTTP fetcher verifies the production request for the Gutenberg source is a valid HTTPS Gutendex request with the required public-domain and English-language constraints, and that a successful 200 response reaches the decoder.
3. Non-200, malformed, and empty-result responses produce the expected source error/empty result behavior without crashing the discovery refresh. The UI-facing discovery state must retain cached/seed data or show a retryable error rather than collapsing to a generic unexplained “error.”
4. If the field path literally uses the text `project gutenberg`, add a request/normalization case for that exact phrase and document whether it is a search term, source label, or catalog URL. Do not silently treat a source label as a book title.

Prefer injected `HTTPFetching` fakes and local JSON fixtures; do not make the test suite depend on live Gutendex availability. If the test identifies a production bug in URL construction, response handling, or error mapping, fix that narrow layer and keep the contract test at the boundary that failed.

## 6. Test plan and acceptance criteria

### Unit and contract tests

- Library filtering tests prove that changing Solo Narration, Favorites, Downloaded, or Created by me leaves the selected progress filter unchanged and that clearing a refinement restores the prior result set.
- Listen view/source-contract tests verify the “Good listening” section and detail copy are absent while actionable listening content remains.
- Library view/source-contract tests verify header action order and absence of Search/More controls in the filter row.
- Discover view/source-contract tests verify no “Browse the catalog” fallback, compact collection-card structure, equal control heights, and About placement/expansion.
- Narration view/source-contract tests verify My Narrations is absent for a first-time user or draft-only project, appears above Start a Narration after recorded content exists, detail text is behind About, no home Browse Community Needs card exists, and New Narration exposes `Browse narration needs` to the full needs browser.
- Gutenberg tests cover the four cases above with injected networking and local fixtures.

### Manual field checks

- On a populated My Books shelf, tap each progress segment, open More, toggle every refinement, search, clear search, and confirm the progress segment always remains selected and no existing books disappear unexpectedly.
- Confirm My Books header hit targets read left-to-right as Search, `+`, More and that each opens the expected action.
- On Listen, confirm the page opens directly on useful listening content and no “Good listening” section/detail copy is visible.
- On Discover, confirm the initial screen has no dead catalog section; select a collection and verify the card is compact, the collection pill and Filter & sort match in height, and About aligns to the right of the collection-name row.
- On Narration, confirm a first-time user or draft-only project sees no My Narrations section, then after recording one narration My Narrations appears above Start a Narration; both explanatory detail blocks are hidden by default, the home needs card is gone, and New Narration → Browse narration needs opens the full browser and starts a selected need.
- Exercise Project Gutenberg while online and offline/with a forced source failure; verify useful cached/seed content and a retryable message rather than a bare error.

### Verification sequence

1. Run focused unit/contract tests for each changed feature.
2. Run the full host test suite.
3. Build the iOS target and run the existing UI/smoke coverage on a simulator as appropriate for release validation.
4. Inspect the diff against this plan, then commit the implementation as one cohesive change after all checks pass.

## Expected implementation files

Likely touch points (confirm during implementation):

- `Voxglass/DesignSystem/VoxglassTheme.swift` for the reusable header action slot/control metrics;
- `Voxglass/Features/Library/LibraryView.swift` and `Voxglass/Core/Library/LibraryStore.swift` for header placement and separated filtering state;
- `Voxglass/Features/Listen/ListenView.swift` for removing the non-actionable section;
- `Voxglass/Features/Discover/DiscoverView.swift` for result gating, collection cards, and control rows;
- `Voxglass/Features/Production/Discovery/NarrationTabView.swift`, `DiscoveryViews.swift`, and `NarrationFlow.swift` for the home/flow split;
- `Voxglass/Core/Production/Discovery/Sources/GutendexNeedsSource.swift` plus its test suite/fixtures for the Gutenberg boundary;
- corresponding test files under `VoxglassTests` and any existing UI/source-contract coverage.

## Non-goals

- No new top-level tab or replacement catalog service.
- No removal of sorting, collection descriptions, batch download, narration filters, project editing, or source provenance.
- No live-network dependency in tests.
- No broad visual redesign beyond the requested density, hierarchy, and action placement changes.
