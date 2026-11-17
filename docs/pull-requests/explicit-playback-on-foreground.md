# Require explicit playback and reorganize Book controls

Foregrounding previously invoked route recovery, which called Play when a session still reported playing after the OS had stopped audio. Interruption completion also resumed automatically. Remove foreground recovery and automatic Play calls from route/interruption completion. Restoring a session remains paused; explicit in-app and remote Play still resume it. Existing audio can continue playing in the background.

The Book page fills its available viewport, placing flexible space above the progress bar so the lower controls finish at a 20-point margin inside the bottom safe area. Content remains scrollable when it exceeds the viewport.

Info and Chapters share the leading toolbar group, with Chapters immediately to the right. Chapters opens its own full-list sheet with Done. Book Details no longer includes chapters or “This book”; Share and Add to Playlist now appear at the bottom of Audio.

## Validation

- All seven changed Swift files pass parser validation; `git diff --check` passes.
- Regression tests cover a stopped engine with stale session state, interruption completion followed by route change, explicit Play afterward, and absence of foreground recovery registration.
- Updated UI coverage checks toolbar order, chapter-sheet navigation, and the placement of Share/Add to Playlist.
- Full `swift test` attempted on the updated branch; compilation fails before project tests run because the dependency's bundled Vorbis C sources call undeclared `alloca` on Linux. The earlier before/after focused attempts had the same limitation. No runtime test pass is claimed.
- Apple-platform builds and physical-device tests remain unverified on this Linux host. CI must validate compilation and host tests before merge.

## Physical-device checks

1. Play, pause, force quit, and relaunch: restore the book/position silently.
2. Pause, background, and foreground repeatedly: no audio until Play.
3. Interrupt playing audio with Siri/a call, return, and change routes: remain silent until Play. Verify in-app and lock-screen Play resume at the saved position.
4. Keep audio playing while backgrounding/foregrounding: continuous playback should continue without a restart or seek.
5. Check the 20-point bottom margin on a tall phone. On a small phone, in landscape, and with accessibility text sizes, verify all content remains reachable by scrolling.
6. Open Chapters beside Info, select a chapter, and verify the correct chapter plays. Verify Book Details excludes the chapter list and Share/playlist actions; open Share and Add to Playlist from Audio.
