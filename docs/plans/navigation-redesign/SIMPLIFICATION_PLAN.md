# Voxglass interface simplification plan

Status: implemented and audited, with this document recording the research-driven follow-up.

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
- Listen now puts a direct Continue Listening card above discovery shelves and
  stats, and My Books rows expose saved progress alongside their Play/Resume
  affordance.
- Catalog discovery defaults to the full catalog; Solo narration remains an
  advanced opt-in filter instead of silently narrowing first-run results.
- Advanced catalog filters now stay local to Discover, Search, and related
  catalog detail surfaces instead of sharing one app-wide Solo preference.
- Book previews now identify themselves as Previewing, saved books identify as
  In My Books, and the main search, preview, and mini-player controls have
  stable accessibility identifiers for UI regression coverage.
- Mini-player Play/Pause and Next Chapter controls now use explicit 44-point
  hit targets while remaining visually compact.
- My Books now exposes a local Downloaded refinement behind More, filters by
  fully cached books, and explains the empty state when nothing is available
  offline.
- Catalog result rows now show compact source/language recording details so
  similar public-domain recordings can be distinguished without opening every
  preview.
- Reopening a catalog result already present in My Books preserves its saved
  state; only newly imported previews are hidden until the user adds them.

## Research evidence

- Apple's [Tab Bars guidance](https://developer.apple.com/design/human-interface-guidelines/tab-bars?changes=l_1__4&language=objc) treats tabs as top-level destinations, recommends keeping them limited and labeled, and distinguishes them from action controls.
- Apple's [Menus and commands session](https://developer.apple.com/videos/play/wwdc2020/10205/) shows menus as the compact place for nearby secondary actions.
- Audible's current iOS structure is four destinations — Home, Library, Discover, and Profile — with search available from the content surfaces rather than promoted to a permanent tab. See this [Audible navigation guide](https://www.blindios.uk/audio-books/audible).
- Spotify places audiobooks inside Home, Search, and Library rather than creating an audiobook-only navigation tier. See its [audiobooks launch overview](https://newsroom.spotify.com/2022-09-20/with-audiobooks-launching-in-the-u-s-today/) and [audiobook access instructions](https://support.spotify.com/us/article/audiobooks-access-plan/).
- Apple Books separates Home, Library, Book Store, Audiobooks, and Search, which is useful as a comparison point but also shows how quickly a reading app can accumulate parallel catalog surfaces. See Apple's [Books user guide](https://support.apple.com/en-ca/guide/iphone/iphc1af7c57/ios).

The common pattern is not “remove capabilities”; it is “reserve navigation for changes in intent.” Search, sort, filters, download, Watch transfer, metadata, and sharing are contextual tools.

## Competitive feature audit and scope decisions

The current reference review covered the official product/support material for
Audible, Apple Books, Spotify Audiobooks, and LibriVox. The relevant comparison
is the listening journey, not feature parity with paid storefronts or general
ebook readers.

| Capability seen in references | Voxglass status | Decision |
| --- | --- | --- |
| Resume, chapter navigation, skip controls, playback speed, and sleep timer | Already present in the player and mini-player flow | Keep in the player; do not promote each control into the main shell. Apple Books and Spotify both keep these controls in the now-playing context. |
| Offline listening and download state | Downloading is supported and My Books exposes a local **Downloaded** refinement | Keep download actions contextual. The Downloaded refinement is the only competitive gap worth prioritizing for the main shelf; it is implemented behind More and does not become another permanent destination. |
| Bookmarks, progress, and listening continuity | Progress, bookmarks, history, iCloud/device continuity, Watch, and CarPlay paths already exist | Preserve the local/private-first model. Audible's clips, Apple Books' bookmarks, and cross-device sync validate the need, but not a new top-level destination. |
| Search by title/author/reader plus category and language browsing | Discover search, collections, narrator search, and advanced local filters exist | Keep one Discover entry point. LibriVox's reader, language, and solo/group facets should remain advanced filters because they are valuable for a catalog-oriented user but add friction to the first search. |
| Samples, ratings, reviews, sharing, and supplemental material | Preview, metadata, and book actions exist; public-domain recordings do not need commerce ratings | Consider lightweight “Why this recording” metadata and sharing later. Do not add ratings, reviews, purchases, credits, paid unlocks, or subscription limits: those solve Audible/Apple/Spotify marketplace problems, not Voxglass's public-domain, local-import, and narration workflow. |
| Custom collections, wish lists, and large-library management | My Books has simple progress filters, favorites, search, and contextual maintenance actions | Keep the default shelf simple. Defer custom collections until real library growth demonstrates the need; a Downloaded filter has higher immediate value and less organizational overhead. |
| Platform reach and device handoff | iPhone, Apple Watch, CarPlay, and local/private state are already first-class | Maintain this as a differentiator. Do not add account-dependent marketplace sync merely to match services whose catalogs and access rights require it. |

### Follow-up backlog from the audit

1. **Completed:** Add **Downloaded** as a local My Books refinement with an
   honest empty state when no saved title is available offline. It remains
   behind the existing More control rather than becoming another persistent tab
   or filter row.
2. **Completed:** Add compact source/language recording details to catalog
   result rows, where users compare recordings before opening a preview. The
   details clarify a choice without creating a review system or adding another
   navigation surface.
3. Defer custom collections, ratings/reviews, social sharing, purchases,
   subscriptions, and account-based cross-device catalog sync. They are either
   already covered by current contextual actions or are consequences of the
   reference apps' commercial/catalog business models.

Evidence reviewed: [Audible player and app controls](https://help.audible.com/s/article/listen-in-the-app?language=en_US), [Audible downloads and offline listening](https://help.audible.com/s/article/download-titles?language=en_US), [Apple Books audiobook player](https://support.apple.com/en-ie/guide/iphone/iphac1971248/ios), [Apple Books device sync](https://support.apple.com/guide/iphone/access-books-on-other-apple-devices-iphb886e1752/27/ios/27), [Spotify audiobook discovery and playback](https://support.spotify.com/us/article/audiobooks-unlock/), [Spotify offline listening](https://support.spotify.com/us/article/listen-offline/), [LibriVox catalog search](https://librivox.org/search), and [LibriVox download/listening options](https://librivox.org/pages/help/).

## Implemented information architecture

The main dock is now:

- **Listen** — current book, resume, recent listening, and one-tap playback.
- **My Books** — the personal shelf; filters and maintenance actions live behind local controls and More.
- **Discover** — one catalog search plus featured collections; advanced scope, sort, solo-only, description, and batch download are progressive disclosure.
- **Narration** — creation and management of user narration.

Search is no longer a top-level destination. Discover owns catalog search, while My Books owns shelf search. A catalog result opens a paused preview with explicit **Add to My Books** and **Play** actions; tapping a row never silently starts playback.

## Research-driven follow-up completed

The saved shelf is action-oriented: tapping a My Books row resumes or starts
playback immediately, while book details remain available from the row's
context menu. This eliminates the most common extra step without removing
detail, Watch, download, or deletion functionality. Catalog filters remain
surface-local, and preview state is explicit on the book page.

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
