# Voxglass — Release Readiness: Final Competitive Analysis & Recommendation

*Date: 2026-07-17. Supersedes the pre-release framing in `RELEASE_PLAN.md`, whose engineering
phases are all verified complete in code (see "Implementation status" below).*

## Recommendation

**Ship now.** All four release criteria pass. Do not hold the release for Project Gutenberg
read-along — ship, then build read-along as the v1.1 moat (see "Post-launch roadmap"; a competitor
already ships text sync, so speed matters more than polish there).

## Implementation status (verified in code, not docs)

- **Resume reliability (RELEASE_PLAN Phases 1–4): done.** `play(book)` resolves resume via
  `resolveResume` + `latestPosition(forBookID:)` (`PlaybackCoordinator.swift:185–201`); per-book
  snapshot map (`LastPlaybackSnapshotStore.swift:11`); synchronous `willResignActive` save
  (`SystemPlaybackBridge.swift:160`); content-key migration + content-key-resolved cloud pull
  (`DatabaseMigrations.swift:220`, `VoxglassCloudSync.swift:258`); position sync free, bookmarks &
  favorites sync Pro; `fetchBookProgress` correct (`LibraryRepository.swift:670–694`).
- **CarPlay: done, free, standalone.** Entitlement present; scene wired in `project.yml:45`;
  `CarPlayMenuBuilder` + `CarPlayInterfaceController` + renderer/dispatcher; the only Pro touchpoint
  is the download upsell (`CarPlayMenuBuilder.swift:311`). Five CarPlay test suites + smoke target.
- **Phase 5 polish:** Restore Purchases row shipped (`SettingsView.swift:171`); skip-silence toggle
  wired (`SettingsView.swift:894`, `SilenceDetector.swift`) — device sign-off still pending;
  accessibility partial (~34 labels/values, concentrated in Now Playing).
- **Recommendations/Explore (RECO_EXPLORE_PLAN): shipped** — taste profile, playback-position
  backfill, curated collections, pure pipeline, bundled counts.
- **Health:** zero TODO/FIXME in non-test source; no paywall-truth drift (paywall's 6 bullets each
  map to an enforced `ProFeature`; `cachePresets`/`prefetchDepth` gated internally, unadvertised).

## Competitive landscape (researched 2026-07)

| Competitor | Model | They beat Voxglass on | Voxglass wins on |
|---|---|---|---|
| **LibriVox Audiobooks** (BookDesign LLC — the incumbent, 4.8★/32K) | Free w/ ads; **subscription**: $1.99/mo, $9.99/yr, $24.99 lifetime (ad removal only) | Ratings mass; 30+ language browsing; free downloads (with ads) | No ads ever; labeled 0.5–3.5× speed w/ per-book memory; per-chapter narrators; **free cross-device position sync (they have none)**; one-time $7.99 vs subscription. Their 2026 reviews: unnavigable redesign, unlabeled speed slider, deleted narrator names, ad volume spikes — each one a thing Voxglass fixes. |
| **Audiobooks HQ** (Cross Forward) | $1.99 up front / freemium | Unlimited downloads; Old Time Radio catalog | Modern UI, standalone CarPlay, position durability/sync, recommendations, privacy |
| **Lex Reader** (MWM, new 2026) | Free + **$9.99/mo** premium | **Free synchronized text+audio over LibriVox** ("narrate the text"); 6M ebooks; cross-platform | A real audiobook player: CarPlay, sleep timer, EQ, free offline tier, position durability; no account; no subscription |
| Libby / Hoopla / Spotify / Audible | Library card / subscription | Modern copyrighted titles | Different catalog — not head-to-head |

## The four release criteria

1. **No major competitive gaps — PASS.** CarPlay was the last table-stakes gap; it shipped.
   Missing Siri/Shortcuts, widgets, Watch, and localization are roadmap items no direct competitor
   uses as a wedge today.
2. **Best free tier on the market — PASS, one soft spot.** No ads + speed + sleep timer (incl.
   end-of-chapter, fade) + bookmarks w/ notes + playlists + favorites + CarPlay + free position sync
   beats every competitor's free tier. Soft spot: free downloads capped at 2
   (`OfflineDownloadManager.swift:72`) where BookDesign (with ads) and HQ allow more. Acceptable —
   streaming is unlimited and ad-free — but it is the one line a comparison review could ding.
3. **Pro tier with no peer — PASS.** One-time $7.99 for unlimited downloads, 10-band EQ, listening
   stats, folder watch, library backup, bookmarks & favorites sync. The incumbent's $24.99 lifetime
   buys only ad removal; their move to subscription strengthens Voxglass's one-time positioning.
4. **Better enough to induce switching — PASS.** Zero switching cost (same free catalog), free
   position sync as the trust hook, and an incumbent mid-backlash. Wedge line unchanged: *the same
   catalog in a player that respects you.*

**Strategic note — read-along is no longer uncontested.** Lex Reader already offers free text+audio
sync over LibriVox. But nobody combines read-along with a real player (CarPlay + offline + position
durability + no subscription). That combination is the post-launch moat; Lex closing the player gap
is the clock.

## Pre-release checklist (remaining work)

1. **README refresh** (`README.md`) — flip CarPlay from "Near-term ☐" to Shipped; update the
   competitive section (BookDesign subscription pricing; add Lex); name read-along as the next
   differentiator.
2. **Accessibility sweep** — extend labels/values beyond Now Playing to `LibraryView`,
   `SettingsView`, `SearchView`, `BookRowView`, playlist/favorites rows, following the
   `NowPlayingView.swift:159` pattern. App Review risk; audience skews older; on-brand.
3. **Sign off the two unadvertised Pro gates** (`cachePresets`, `prefetchDepth`) as intentional
   internal knobs — no code change expected.
4. **Device pass** (human, physical device): the 9 checks in `RELEASE_PLAN.md` §Verification —
   force-quit/crash resume, reinstall restore on a free build, skip-silence on a real LibriVox
   recording (E4), VoiceOver over Now Playing.
5. Gates: `scripts/guard_wiring.sh` + `scripts/test.sh` green; `xcodegen generate` diff clean.

## Post-launch roadmap

- **v1.1 — Project Gutenberg read-along (the moat):** paired Gutenberg text + LibriVox audio with a
  moving highlight; free basic tier, Pro extras TBD. Answers Lex from inside a real player.
- Then: Siri/App Shortcuts + widgets (needs app-group entitlement + relocated SQLite), localization
  (catalog already multi-language), Apple Watch, shake-to-extend sleep timer.
- Pricing lever held in reserve: raise the free download cap 2 → 3 if free-tier pressure appears.

## Sources

- [LibriVox Audiobooks — App Store listing](https://apps.apple.com/us/app/librivox-audiobooks/id596159212)
- [LibriVox Audiobooks — user reviews (justuseapp)](https://justuseapp.com/en/app/596159212/librivox-audio-books/reviews)
- [Lex](https://lex-books.com/) · [Lex Reader — App Store](https://apps.apple.com/us/app/lex-reader/id6757875402)
- [Audiobooks HQ — App Store](https://apps.apple.com/us/app/audiobooks-hq-audio-books/id632306630)
- [Top audiobook apps for iPhone 2026 (Eist)](https://eist.app/blog/top-audiobook-apps-for-iphone-2026)
