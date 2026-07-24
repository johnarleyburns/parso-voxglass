# Mini-player Presentation Routing Fix Plan

**Mockup:** [`docs/mockups/miniplayer-routing-contract.html`](mockups/miniplayer-routing-contract.html)

**Scope:** documentation and implementation contract for the next coding pass. This pass does not change app code.

## Goal

Make the mini-player behave as the route to the current playback session, while a pushed book detail page remains the route to the book the user is viewing.

The desired behavior is:

- If the user is viewing book A and book B is the current session, show the mini-player for book B.
- If the user taps the mini-player, open Now Playing for book B.
- If the user taps Play on the book A detail page, start book A and stay on the book A detail page.
- If the visible pushed detail page already represents the current session, hide the mini-player to avoid duplicate playback surfaces.

Remote catalog imports are a separate flow and may continue to present a paused Now Playing sheet after import.

## External Research

- Apple Music documents two surfaces: the MiniPlayer shows the currently playing item, and tapping it opens Now Playing. It also places route/device controls inside Now Playing. Source: [Use the music player controls on iPhone](https://support.apple.com/guide/iphone/iph676daac9b/ios).
- Apple Books uses an audiobook player plus a mini-player. The support guide says the full audiobook player can be dismissed into the mini-player, and tapping the mini-player returns to full screen. It also keeps audiobook controls such as speed, sleep timer, AirPlay, and chapter list in the player. Source: [Listen to audiobooks in the Books app on iPhone](https://support.apple.com/guide/iphone/listen-to-audiobooks-iphac1971248/ios).
- Spotify places Now Playing above the tab bar on mobile and says tapping it opens the larger view; overflow actions remain in the full view. Source: [Now Playing view](https://support.spotify.com/us/article/now-playing/).
- Audible documents the mini player as a resume surface and also supports lock-screen resume. Source: [Listen in the app](https://help.audible.com/s/article/listen-in-the-app?language=en_US).

Product implication for Voxglass: the mini-player should be a persistent representation of the active session, not an automatic consequence of pressing Play on an unrelated detail page. Detail-page Play should change playback state in place; mini-player tap should be the explicit expansion gesture.

## Current Voxglass Root Cause

Line numbers below are from the current worktree on July 23, 2026.

1. `RootView` owns one global `@State private var showingNowPlaying = false` and presents `BookPageView(book: nil, ...)` as a sheet from that boolean (`Voxglass/App/RootView.swift:9`, `:73-78`).
2. The dock mini-player toggles that same boolean when tapped (`Voxglass/Features/Chrome/GlassDock.swift:11-13`).
3. `BookPageView(book: nil)` resolves to `playback.currentSession`; `BookPageView(book: someBook)` resolves to the pushed detail book (`Voxglass/Features/Player/BookPageView.swift:25-29`).
4. Every top-level screen gets its own implicit `NavigationStack` from `VoxglassScreen` (`Voxglass/DesignSystem/VoxglassTheme.swift:59-81`). There is no shared route model that knows which pushed book detail page is currently visible.
5. `BookPageView` starts playback from a non-active detail page and immediately sets `showingNowPlaying = true` (`BookPageView.swift:498-502`). Chapter rows do the same when starting a chapter from a non-active book (`BookPageView.swift:617-620`).
6. The dock only checks `playback.currentSession != nil` before showing a mini-player (`GlassDock.swift:11`). It does not suppress the mini-player when the visible pushed page is already the current session's book.
7. The dimmed side transport controls in the browsing state are still live buttons (`BookPageView.swift:457-549`). When the detail book differs from the active session, those buttons can accidentally skip or seek the old mini-player book instead of the visible detail book.

The bug is not in playback persistence. It is a presentation-routing bug: the same `showingNowPlaying` binding is used for both explicit mini-player expansion and detail-page playback side effects, while the dock has no same-book visibility guard.

## Routing Contract

Define these routes:

| State | Visible pushed book page | Current session | Mini-player | Tap mini-player | Tap detail Play |
|---|---:|---:|---|---|---|
| No session | any | none | hidden | no-op | play visible book, stay on page |
| Different-book detail | A | B | visible for B | present Now Playing sheet for B | play A, stay on page, then hide mini-player |
| Same-book detail | A | A | hidden | no mini-player to tap | toggle/play A in place |
| Non-book screen | none | B | visible for B | present Now Playing sheet for B | n/a |
| Now Playing sheet | sheet resolves current session | B | covered/irrelevant | n/a | control B in sheet |

Important rules:

- The mini-player target is always `playback.currentSession`.
- A pushed detail page target is always its `book` argument.
- Opening Now Playing must be triggered only by mini-player tap or flows that deliberately call `playback.present(imported)` for a just-imported remote catalog item.
- Pressing Play, a chapter row, previous/next, or skip controls on a pushed book detail must not set the Now Playing sheet boolean.
- Same-book guard wins over "there is a current session": do not render the dock mini-player when the visible pushed book page is the current session's book.

## Implementation Plan

### 1. Add a small presentation router

Create `Voxglass/Features/Player/MiniPlayerPresentationRouter.swift`.

Recommended shape:

```swift
@MainActor
final class MiniPlayerPresentationRouter: ObservableObject {
    @Published var isNowPlayingPresented = false
    @Published private(set) var visiblePushedBookID: UUID?

    func bindNowPlaying() -> Binding<Bool> {
        Binding(
            get: { self.isNowPlayingPresented },
            set: { self.isNowPlayingPresented = $0 }
        )
    }

    func registerPushedBookPage(_ id: UUID) {
        visiblePushedBookID = id
    }

    func unregisterPushedBookPage(_ id: UUID) {
        if visiblePushedBookID == id {
            visiblePushedBookID = nil
        }
    }

    func shouldShowMiniPlayer(currentBookID: UUID?) -> Bool {
        guard let currentBookID, !isNowPlayingPresented else { return false }
        return visiblePushedBookID != currentBookID
    }

    func presentNowPlayingFromMiniPlayer(currentBookID: UUID?) {
        guard shouldShowMiniPlayer(currentBookID: currentBookID) else { return }
        isNowPlayingPresented = true
    }
}
```

Keep this as presentation state only. Do not put playback state, navigation destinations, imports, or library lookup inside it.

### 2. Own the router at the root

In `RootView`:

- Replace `@State private var showingNowPlaying = false` with `@StateObject private var miniPlayerRouter = MiniPlayerPresentationRouter()`.
- Pass `miniPlayerRouter.bindNowPlaying()` to existing views that still accept `@Binding var showingNowPlaying`.
- Inject `.environmentObject(miniPlayerRouter)` into the tab subtree and the Now Playing sheet.
- Bind the sheet to `miniPlayerRouter.bindNowPlaying()`.
- Present `BookPageView(book: nil, showingNowPlaying: miniPlayerRouter.bindNowPlaying(), presentationContext: .nowPlayingSheet)`.

No shared `NavigationPath` is required for this fix. The mini-player should not push into whichever tab stack happens to be selected; it should continue to use the global sheet.

### 3. Route mini-player visibility through the router

In `GlassDock`:

- Read `@EnvironmentObject private var miniPlayerRouter: MiniPlayerPresentationRouter`.
- Replace `if playback.currentSession != nil` with:

```swift
if let session = playback.currentSession,
   miniPlayerRouter.shouldShowMiniPlayer(currentBookID: session.book.id) {
    GlassMiniPlayer(showingNowPlaying: $showingNowPlaying)
        .onTapGesture {
            miniPlayerRouter.presentNowPlayingFromMiniPlayer(currentBookID: session.book.id)
        }
}
```

If keeping the binding in `GlassMiniPlayer`, ensure the row tap and any explicit row button route through the router method. The small Play and Next buttons inside the mini-player should continue to control `playback.currentSession`; they should not register or unregister visible book pages.

### 4. Register only pushed book pages

Add a context to `BookPageView`:

```swift
enum BookPagePresentationContext {
    case pushedDetail
    case nowPlayingSheet
}
```

Add `let presentationContext: BookPagePresentationContext`, defaulting call sites with concrete books to `.pushedDetail` and the root sheet to `.nowPlayingSheet`.

In `BookPageView`, read the router:

```swift
@EnvironmentObject private var miniPlayerRouter: MiniPlayerPresentationRouter
```

For `.pushedDetail` only:

- On appear, call `miniPlayerRouter.registerPushedBookPage(resolved.book.id)`.
- On disappear, call `miniPlayerRouter.unregisterPushedBookPage(resolved.book.id)`.
- Use `.task(id: resolved.book.id)` or `.onChange(of: resolved.book.id)` to handle a detail page whose resolved library copy changes.

Do not register the Now Playing sheet. It is already represented by `isNowPlayingPresented`.

### 5. Remove detail-origin sheet presentation

In `BookPageView.transportControls`:

- For the non-active center Play button, keep `await playback.play(resolved)`.
- Delete `showingNowPlaying = true`.
- This keeps the user on the visible book detail page and allows the same-book guard to hide the mini-player after `currentSession` switches to that book.

In chapter rows:

- For a chapter on a non-active book, keep `await playback.play(resolved, chapter: chapter)`.
- Delete `showingNowPlaying = true`.

Remote import flows in `DiscoverView`, `SearchView`, `ListenView`, `CatalogDiscoveryView`, and `SettingsView` can keep `await playback.present(imported); showingNowPlaying = true`. Those flows do not have a visible local detail page yet, and presenting the paused player is the existing discovery contract.

### 6. Fix browsing-state transport controls

The current browsing-state side transport buttons are dimmed but still act on the previous active session. Update each control to route by state:

- If `isActiveSession`, keep current behavior.
- If not active, first start the visible book with `await playback.play(resolved)`, keep the sheet hidden, then perform the intended action only if it still makes sense.

Recommended outcomes:

- Center Play: `await playback.play(resolved)`.
- Chapter row: `await playback.play(resolved, chapter: chapter)`.
- Previous/Next chapter while browsing: either disabled with `.allowsHitTesting(false)` until the book is active, or `await playback.play(resolved)` followed by previous/next only after the coordinator has switched. Prefer disabled if there is no clear resume target.
- Back/Forward skip while browsing: either disabled, or start the visible book and then skip relative to its resolved resume point. Prefer disabled unless product explicitly wants one-tap "start then skip".

Do not leave any dimmed browsing control that can mutate the old current session.

### 7. Tests

Follow the repo's existing source-guard style in `VoxglassTests/ArtworkPresentationTests.swift`, and add pure tests if the router is placed in a testable target.

Add `VoxglassTests/MiniPlayerPresentationRoutingTests.swift` with these checks:

- `testMiniPlayerVisibleForDifferentVisibleBook` - given current book B and visible pushed book A, `shouldShowMiniPlayer` is true.
- `testMiniPlayerHiddenForSameVisibleBook` - given current book A and visible pushed book A, `shouldShowMiniPlayer` is false.
- `testMiniPlayerHiddenWhileSheetPresented` - when `isNowPlayingPresented` is true, mini-player visibility is false.
- `testUnregisterDoesNotClearNewerVisibleBook` - unregistering A after B registered does not clear B.
- `testBookPagePlayDoesNotPresentNowPlaying` - `BookPageView.swift` does not contain `showingNowPlaying = true` inside `transportControls` or `chapterList`.
- `testRemoteCatalogImportsStillPresentPausedNowPlaying` - the existing remote import files still contain `await playback.present(imported)` followed by `showingNowPlaying = true`, and do not call `await playback.play(imported)`.
- `testDockUsesRouterForMiniPlayerVisibility` - `GlassDock.swift` contains `shouldShowMiniPlayer` and `presentNowPlayingFromMiniPlayer`.

If source slicing is needed, use simple substring ranges from `private func transportControls` to `private func actionRow`, and from `private func chapterList` to `private func discoveryLinks`.

### 8. Verification

Run:

```sh
swift test
xcodegen generate
xcodebuild -project Voxglass.xcodeproj -scheme Voxglass -destination 'platform=iOS Simulator,name=iPhone 16' build
```

Manual matrix:

- Start book B. Navigate to book A detail. Mini-player for B is visible.
- Tap the mini-player. Now Playing sheet opens for B.
- Dismiss sheet. Tap Play on book A detail. Playback switches to A, the sheet does not open, and the mini-player disappears because the visible detail page is now A.
- Navigate back to a non-book screen. Mini-player for A appears.
- Open book A detail while A is playing. Mini-player stays hidden.
- Open book C detail while A is playing. Mini-player for A appears.
- From book C detail, dimmed or disabled side transport controls do not skip/seek book A.
- Remote catalog result import still opens a paused Now Playing sheet.

## Acceptance Criteria

- Mini-player tap is the only generic mini-player expansion path.
- Detail-page Play and chapter taps never auto-present Now Playing.
- Mini-player is visible on different-book detail pages and hidden on same-book detail pages.
- The mini-player always expands to the active session, not the pushed detail book.
- Browsing-state transport controls cannot mutate an unrelated active session.
- Existing remote catalog import presentation remains unchanged.
- No app source changes are made by this docs-only pass.
