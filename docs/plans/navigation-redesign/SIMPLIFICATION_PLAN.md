# Voxglass interface simplification plan

Status: implemented in two commits, with this document recording the research-driven follow-up.

## Objective

Keep the app's full listening, importing, search, discovery, offline, Watch, narration, and settings functionality while making the main flow feel like one obvious loop:

1. Listen to something already in progress.
2. Keep saved books in My Books.
3. Find something new in Discover.
4. Open Narration only when creating or managing narration.

Everything else should appear at the point of need, in a menu, or on the book detail screen instead of competing for permanent navigation space.

## Audit follow-up

The implementation audit against `PLAN.md` closed the remaining chrome and
library-flow gaps:

- The dock now gives the selected destination both a brass color and a capsule
  background/outline, with the selected state exposed to accessibility.
- My Books defaults to the complete saved shelf. Solo narration is a local
  refinement instead of a shared preference that can silently hide books.
- Saved-book row actions expose Play or Resume semantics to VoiceOver while
  keeping the one-tap player flow.
- The root no longer adds a second fixed 136pt bottom reservation on top of
  the shared screen clearance and live dock safe-area inset.

## Research evidence

- Apple's [Tab Bars guidance](https://developer.apple.com/design/human-interface-guidelines/tab-bars?changes=l_1__4&language=objc) treats tabs as top-level destinations, recommends keeping them limited and labeled, and distinguishes them from action controls.
- Apple's [Menus and commands session](https://developer.apple.com/videos/play/wwdc2020/10205/) shows menus as the compact place for nearby secondary actions.
- Audible's current iOS structure is four destinations — Home, Library, Discover, and Profile — with search available from the content surfaces rather than promoted to a permanent tab. See this [Audible navigation guide](https://www.blindios.uk/audio-books/audible).
- Spotify places audiobooks inside Home, Search, and Library rather than creating an audiobook-only navigation tier. See its [audiobooks launch overview](https://newsroom.spotify.com/2022-09-20/with-audiobooks-launching-in-the-u-s-today/) and [audiobook access instructions](https://support.spotify.com/us/article/audiobooks-access-plan/).
- Apple Books separates Home, Library, Book Store, Audiobooks, and Search, which is useful as a comparison point but also shows how quickly a reading app can accumulate parallel catalog surfaces. See Apple's [Books user guide](https://support.apple.com/en-ca/guide/iphone/iphc1af7c57/ios).

The common pattern is not “remove capabilities”; it is “reserve navigation for changes in intent.” Search, sort, filters, download, Watch transfer, metadata, and sharing are contextual tools.

## Implemented information architecture

The main dock is now:

- **Listen** — current book, resume, recent listening, and one-tap playback.
- **My Books** — the personal shelf; filters and maintenance actions live behind local controls and More.
- **Discover** — one catalog search plus featured collections; advanced scope, sort, solo-only, description, and batch download are progressive disclosure.
- **Narration** — creation and management of user narration.

Search is no longer a top-level destination. Discover owns catalog search, while My Books owns shelf search. A catalog result opens a paused preview with explicit **Add to My Books** and **Play** actions; tapping a row never silently starts playback.

## Research-driven follow-up

The remaining high-value simplification is to make the saved shelf action-oriented: tapping a My Books row should resume or start playback immediately, while book details remain available from the row's context menu. This eliminates the most common extra step without removing detail, Watch, download, or deletion functionality.

Acceptance criteria:

- Every saved-book row has an obvious Play/Resume affordance.
- The primary row action starts playback and presents the player.
- **Open Details** remains available in the context menu for metadata, chapters, Watch, offline, and other secondary actions.
- Discover/catalog rows remain non-autoplaying and open a paused preview.
- The dock stays limited to the four intent-level destinations above.
- No search, filter, sort, batch action, or transfer control is promoted to the primary dock.

## Verification and release use

- `swift test` is the commit-time check and must remain simulator-free.
- CI continues to run the host logic tests, platform builds, and guarded checks.
- Before a release, run `scripts/test.sh --all` for the simulator smoke pass, then exercise the highest-value flows on physical iPhone and Watch hardware.
- Revisit this plan after user testing, especially whether the Listen screen is sufficient as the default landing surface and whether users discover the My Books context menu.
