# Voxglass — Narration Needs (On-Device Discovery) — Feature Specification

*A robust, multi-source, on-device system that answers "what should I narrate?" on **iPhone and Mac at runtime**, with a fallback ladder deep enough that the user never sees a sign-in wall, a copyright failure, or a parse error. Short works are narratable on iPhone (multiple of them); longer works are surfaced everywhere but narratable only on Mac.*

**Relationship to other documents.** This spec extends `docs/voxglass-mvp/VOXGLASS_STUDIO_SPEC.md` (the "Studio Spec") and **supersedes** the on-ramp/weekly/scrape planning notes (`NARRATION_ONRAMP_PLAN.md`, `IOS_PD_TASTER_WEEKLY_REFRESH.md`, `LIBRIVOX_WEEKLY_SCRAPE.md`), folding them into one coherent design. It inherits the Studio Spec's conventions verbatim (§0.2 normative language, §0.6 repo conventions, the protocol-seam/DI model, the determinism seams, `@Observable`-only, no GRDB, XcodeGen, `guru.parso`). Suggested home: `docs/voxglass-mvp/NARRATION_NEEDS_SPEC.md`. Mockups: `docs/voxglass-mvp/mockups/needs/n01…n06.html`.

---

## 0. Preliminaries

### 0.1 Normative language
Same as Studio Spec §0.2: **MUST / MUST NOT** (a CI gate, test, or reviewer rejects violations), **SHOULD** (deviate only with a code comment), **MAY** (optional; do the simplest thing), **DEFERRED** (out of MVP; do not stub toward it).

### 0.2 Corrections to the prior on-ramp notes
| # | Prior note said | This spec says |
|---|---|---|
| D-1 | Parse the LibriVox forum in J's pipeline only (`LIBRIVOX_WEEKLY_SCRAPE.md` §1). | The forum parser runs **on-device as the lowest-priority ladder rung (L3)** *and* J's pipeline may still publish a hosted snapshot (L1). The two are independent rungs of one ladder; **neither is required for the feature to work** (§2). The on-device forum parse exists because the user asked for a system that runs entirely at runtime — it is made safe by the ladder, not by moving it off-device. |
| D-2 | iPhone narrates a single "taster" short work (base plan §16). | iPhone narrates **multiple** short works (a real "My Narrations" library), still short-only (§10). Longer works are Mac-only for the *action*, but are *surfaced* on iPhone as aspirational handoff cards. |
| D-3 | "This Week's Poem" comes from the forum. | The featured slot is **always** a deterministic on-device pick (`FeaturedSelector`, §8), optionally *pinned* by a fresher rung (snapshot or forum). It can never be empty or stale-blocking, because the seed guarantees a pool. |
| D-4 | (A late suggestion floated deferring the on-device LibriVox forum rung, L3, to a later release.) | **L3 ships in v1 (MUST).** The live connection to real LibriVox activity — this week's actual poem, projects open for readers *right now*, and classics still unrecorded *today* — is the feature's engagement engine and its most direct tie to LibriVox narration (§1.6). Its fragility is fully absorbed by the ladder (§2), so shipping the most fragile rung adds **no correctness risk**: when it can't deliver, the surface is already full from L0–L2. |
| D-5 | Short work ceiling = 20 min ("one phone session"). | **Short work ceiling = 1 hour**, matching LibriVox's own definition of short works ("less than 1 hour read by individuals"). So every work the app calls "short" is exactly what LibriVox's Short Works / Weekly Poetry program accepts from a solo reader (§5). |
| D-6 | The base plan deferred FLAC on iPhone ("WAV suffices for IA; libFLAC deferred"). | **FLAC export ships on iPhone.** The Internet Archive lane produces a **FLAC lossless master + an MP3 derivative**; the LibriVox lane produces **128 kbps CBR mono MP3**. `libFLAC` is BSD-3 (no license issue, cf. Studio Spec C-3), so the iPhone build adds a `libFLAC` slice alongside `libmp3lame`; the `VoxTranscoder` wrappers are reused unchanged. See §11.4 / p07. |

### 0.3 Definition of done (this feature)
Done when: (a) `NeedsAggregatorTests` proves a non-empty, PD-safe, ranked list is returned **when every network source fails**; (b) the iPhone and Mac discovery smoke tests pass with all live sources stubbed to fail (§12); (c) CI gates G-13…G-18 pass; (d) a human, in airplane mode, opens both apps and sees a full, usable Narration Needs surface with no error, no spinner-stuck, and no sign-in prompt; **(e) the on-device LibriVox forum rung (L3) is wired and, in a live-network test, contributes real current needs — the actual Weekly Poem and at least one open project — while the sign-in-wall fixture proves it still yields nothing invisibly (§12.1).**

### 0.4 Glossary additions (Studio Spec §0.5 style)
| Term | Meaning | User-facing string |
|---|---|---|
| **Narration need** | A discovered opportunity to narrate a public-domain work, carrying why it's a "need" and where it may be narrated. | (surfaced as a card) |
| **Ladder** | The ordered set of sources (L0–L3); each rung is a fallback for the ones above and fails invisibly. | (invisible) |
| **Floor** | The bundled seed (L0). Guarantees a non-empty, PD-safe result offline, forever. | (invisible) |
| **Featured slot** | The single rotating highlight — "This Week's Poem" (iPhone/short) / "Book of the Month" (Mac/long). | "This Week's Poem" / "Book of the Month" |
| **Narratable-on** | The platforms where the *record action* is offered for a need. Discovery shows all needs everywhere; only the action is gated. | (Start narrating / Record on Mac) |
| **Grade** | `.submittable` (LibriVox-eligible: PD-verified + citable source) vs `.practice` (record for personal/IA, not surfaced as LibriVox-ready). | (a small badge) |

### 0.5 Repo conventions inherited
Studio Spec §0.6. New code lives in `Voxglass/Core/Production/Discovery/` (pure Core), `Voxglass/Features/Production/Discovery/` (iPhone), `VoxglassStudio/Features/Discovery/` (Mac). Tests in `VoxglassTests/Production/Discovery/`. Seed resource at `Voxglass/Resources/needs-seed.json`. Persistence follows the hand-rolled `AppDatabase`-style actor pattern (no GRDB). `ObservableObject` banned; `@Observable` only. `Date()`/`UUID()` only via the `Clock`/`IDGenerator` seams (Studio Spec §4.2).

---

## 1. Product definition

### 1.1 One sentence
Narration Needs is an on-device discovery surface that always shows the user public-domain works worth narrating — assembled from a ladder of sources that degrade invisibly — and routes short works to on-device recording (iPhone or Mac) and longer works to the Mac.

### 1.2 The job
"I have a few spare minutes and a voice; give me something worth recording, right now, that I can actually publish — and never make me think about logins, copyright, or whether a website is down." On iPhone the answer is a short poem or short work the user records and packages in minutes; on Mac it can additionally be a whole book.

### 1.3 What it is not
- **Not** a LibriVox client. It never signs the user in, never posts on their behalf, never claims copyright status (Studio Spec §3.6, C-7). It *prepares and links*.
- **Not** dependent on any network source. Every live rung is a progressive enhancement over the bundled floor.
- **Not** a place that surfaces errors. Failures degrade to the next rung; the UI stays full and calm.

### 1.4 Platform surfaces and the short/long split
| Surface | Discovery shows | Record action offered for |
|---|---|---|
| **Voxglass (iPhone)** | short **and** long needs | `.short` needs → "Start narrating"; `.long` needs → "Record on Mac" (handoff card, **no record CTA**) |
| **VoxglassStudio (Mac)** | short **and** long needs | both → "Start narrating" (short = single-work; long = multi-chapter via Source Import) |

The split is a rule on the **action**, not on discovery: `NarrationNeed.narratableOn == {.iOS, .mac}` iff `lengthClass == .short`, else `{.mac}` (§10). This is CI-gated (G-15).

### 1.5 Principles (resolve ambiguity with these, in order)
1. **The floor never fails.** Given the bundled seed, `NeedsAggregator` MUST always return a non-empty, PD-safe, ranked list — synchronously fast, before any network call resolves.
2. **Failures are invisible.** A source that throws, times out, rate-limits, redirects to a login, or returns garbage MUST contribute nothing and surface nothing. It is a diagnostics event, never UI.
3. **Optimistic then enriched.** Paint from cache+seed instantly; refine as live rungs resolve. Never block the surface on a fragile rung.
4. **PD-safe by construction.** No work is offered as LibriVox-`.submittable` unless its public-domain basis is verified; unverifiable works degrade to `.practice` or drop — never an error.
5. **The tool prepares; the human submits.** No auto-upload, no login, no acceptance claims (Studio Spec C-7).
6. **Short is the phone's job; books are the Mac's.** Enforce on the action, invite on discovery.
7. **Stay connected to living LibriVox.** Prefer real, current LibriVox activity over static curation where it's available — it is what turns a listener into a contributor (§1.6).

### 1.6 The living LibriVox connection (why L3 ships)
A core goal of this feature is to make Voxglass feel **directly and currently connected to LibriVox narration**, because that connection is what converts a listener into a contributor and keeps them coming back. Three of the L3 signals exist *only* because the app reads LibriVox's **live** state:
- **`weeklyFeatured`** — the poem LibriVox actually chose this week (not merely a rotating classic), so "This Week's Poem" matches what the community is recording right now.
- **`openProjectNeedsReader` / `proofListenerNeeded`** — projects that are open **at this moment** and need a voice or a proof-listener, so a user's contribution lands somewhere real and welcome.
- **`catalogGap`, live-confirmed** — classics with no LibriVox recording **today**, re-checked against LibriVox rather than trusting a static list.

This liveness is the difference between "here are some public-domain poems" and "here is what LibriVox needs from you this week" — and the latter is what drives usage. The MVP therefore ships the on-device LibriVox forum rung (**L3 MUST ship**, D-4). Shipping the most fragile rung is safe precisely because the ladder (§2) makes every rung's failure invisible: when L3 is unavailable, unreachable, sign-in-walled, or unparseable, the surface is already full from L0–L2 and the user notices nothing; when L3 *is* available, it adds a genuine, motivating link to the community that no static source can.

---

## 2. The source ladder

The core of the design. Sources are ordered L0 (most guaranteed) → L3 (most fragile). The aggregator composes them; **each rung is optional and independently failable.**

| Rung | Source | Role | Guaranteed? | On failure |
|---|---|---|---|---|
| **L0** | `SeededNeedsSource` (bundled `needs-seed.json`) | The floor: ~150 short + ~40 long PD works, pre-verified. | **Always** (ships in app). | cannot fail |
| **L1** | `SnapshotNeedsSource` (`https://parso.guru/voxglass/needs.json`) | J's pipeline output: current open LibriVox projects, the weekly pin, great-books gaps — all PD-verified. | No | last-good cache → else nothing |
| **L2** | `PoetryDBNeedsSource`, `GutendexNeedsSource`, `InternetArchiveNeedsSource`, `WikisourceNeedsSource` | Fresh PD works from clean, key-less public APIs. Each independent. | No | that one source contributes nothing |
| **L3** | `LibriVoxForumNeedsSource` | The most authentic *live* "needs" (open projects + the weekly poem), parsed on-device. Most fragile. | No | contributes nothing (incl. on a sign-in wall) |

### 2.1 The invisible-failure contract (MUST)
1. `NeedsAggregator.stream(for:platform:) -> AsyncStream<NeedsSnapshot>` MUST emit its **first element synchronously-fast** from L0 ∪ last-good cache (no awaiting any network). Subsequent elements enrich as rungs resolve.
2. Every rung call MUST be isolated: wrapped in `try?`, bounded by a per-rung timeout (default 4 s), and guarded by a per-rung circuit breaker (after K consecutive failures, skip the rung for a cooldown). A throw/timeout/redirect/parse-failure maps to an **empty contribution**, logged to diagnostics only.
3. The aggregator MUST never return empty while the seed loads (build-time guarantee, G-18).
4. No rung may present UI. In particular, L3 MUST NOT ever show a LibriVox login screen (G-14). If the forum requires auth, L3 yields nothing.
5. Freshness, not correctness, degrades: an offline user gets slightly staler needs, never an error.

### 2.2 Merge, dedupe, rank
The aggregator unions rung outputs, dedupes by `NeedID = SHA256Hex(normalize(author) | normalize(title) | normalizedSourceHost)`, merges provenance (a work seen in both snapshot and forum keeps both `sources` and the **stronger** `signal`), verifies PD (§6), then ranks (§7). Pure and deterministic given inputs.

---

## 3. Sources — normative profiles

Modeled as a data table `NeedsSourceDescriptor` in `Discovery/NeedsSourceDescriptors.swift` (all magic values centralized, cf. G-10). Each source implements `NeedsSource` (§4.2) and depends only on the `HTTPFetching` seam.

### 3.0 Summary matrix
| ID | Endpoint | Auth | Yields | PD basis | Cache TTL | Trust |
|---|---|---|---|---|---|---|
| `.seed` | bundled | — | short+long | `curatorVerified` | ∞ | highest |
| `.snapshot` | `parso.guru/voxglass/needs.json` | none | short+long + pins | inherited (pipeline-verified) | 24 h | high |
| `.poetryDB` | `poetrydb.org` | none (key-less) | short poems | `curatorVerified` (classic corpus) → `.practice` unless a Gutenberg source is attached | 7 d | medium (`.practice` by default) |
| `.gutendex` | `gutendex.com/books?copyright=false` | none | short+long texts | `gutenbergSourced` | 7 d | high (`.submittable`) |
| `.internetArchive` | `archive.org/advancedsearch.php?output=json` | none | short+long texts; `librivoxaudio` for gap signal | `iaVerifiedEdition` (date ≤ rolling line) | 7 d | high |
| `.wikisource` | `<lang>.wikisource.org/w/api.php?action=query&format=json` | none | short works; monthly featured text | `curatorVerified` + proofread flag → prefer Gutenberg source for `.submittable` | 7 d | medium |
| `.libriVoxForum` | `forum.librivox.org` (Atom `feed.php` first, HTML fallback) | none (read) | live open projects + weekly poem | must pass §6; else `.practice` | 6 h | low (fragile) |

### 3.1 `.gutendex` (primary text source)
Query `GET gutendex.com/books?copyright=false&languages=en&topic=<poetry|fiction|...>&sort=popular`. `copyright=false` MUST be present (guarantees US-PD). `formats` map → the citable `sourcePageURL` + EPUB URL (fetched via base-plan `GutenbergSource`). Classify `lengthClass` from `estSeconds` (§10). Grade `.submittable`. Cache aggressively; IA/Gutenberg community services request caching.

### 3.2 `.poetryDB` (short-poem appetite)
`GET poetrydb.org/linecount/<N>` and `/author/<name>` (key-less JSON). Filter to `linecount ≤ shortPoemLineCeiling` (default 40). Its corpus is classic long-dead poets, but it carries no citable per-poem edition → grade `.practice` unless the pipeline/Gutendex attaches a matching Gutenberg source, then `.submittable`. Cache; the maintainers advise picking from a stored copy rather than polling.

### 3.3 `.internetArchive` (texts + gap signal)
`GET archive.org/advancedsearch.php?q=collection:(gutenbergbooks)+AND+mediatype:(texts)&fl[]=identifier&fl[]=title&fl[]=creator&fl[]=year&output=json&rows=…`. Also `collection:(librivoxaudio)` to build a **recorded-set** used to raise `NeedSignal.catalogGap` for texts absent from it (approximate, per-author; the authoritative gap list comes from L1/the great-books audit). Grade from edition `year ≤ currentYear − 96` → `iaVerifiedEdition`. IA requests caching.

### 3.4 `.wikisource` (short works + featured alt)
`GET en.wikisource.org/w/api.php?action=query&format=json&list=categorymembers&cmtitle=Category:<short-works cat>&cmlimit=…`, then `prop=revisions&rvprop=content` for text (the `<poem>` extension gives structured verse). Also the **monthly featured text** — a clean-API alternative pin for the featured slot when L3 is unavailable. Prefer a Gutenberg source for `.submittable`; else `.practice`.

### 3.5 `.libriVoxForum` (live needs; lowest rung)
Two paths, tried in order, both dependency-free:
1. **Atom** — `GET forum.librivox.org/feed.php?f=28` and `?f=19`; parse with Foundation `XMLParser`. Entries give `<title>`, `<link>`, `<updated>`, first-post `<content>`.
2. **HTML fallback** — `GET viewforum.php?f=28` and `?f=19`; a **dependency-free lenient scanner** (no third-party HTML parser, per the Studio Spec's ZIP-reader precedent) extracts topic-title anchors and, for the chosen thread, the first post.
Parse the **thread title** for identity + status + jurisdiction (observed live conventions): `[WEEKLY POETRY] - <Title> by <Author>`, tags `OPEN`/`[SOLO]`/`[GROUP]`/`[DR]`/`COMPLETE`/`[FULL]`, `~` (proof-listener needed), `[OPEN - US ONLY]` (US-PD only → tag `usOnly`, valid for the US-PD lane). Skip `COMPLETE`/`FULL`. Emit `openProjectNeedsReader` / `proofListenerNeeded` / `weeklyFeatured`. **PD gate (§6) is mandatory** — the forum is not a copyright authority (a coordinator once posted a source published 1994). Unverifiable → `.practice`. Any failure (feed gone, markup drift, **sign-in wall**, PD-unverified) → the rung yields nothing, silently.

---

## 4. Architecture

### 4.1 Module topology (extends Studio Spec §4.1)
```
Voxglass/Core/Production/Discovery/    ← ALL new discovery logic (pure; depends only on HTTPFetching + Clock + IDGenerator)
  Domain/            NarrationNeed, NeedSignal, LengthClass, WorkGrade, PDBasis, NeedProvenance
  Sources/           NeedsSource protocol; Seeded/Snapshot/PoetryDB/Gutendex/InternetArchive/Wikisource/LibriVoxForum sources
  Aggregate/         NeedsAggregator (LadderNeedsAggregator), NeedsRanker, NeedDeduplicator
  PD/                PDVerifier (SourceInheritancePDVerifier), rolling-year ceiling
  Featured/          FeaturedSelector (deterministic; weekly/monthly)
  Cache/             NeedsCache (FileNeedsCache actor, JSON last-good) + CircuitBreaker
  Parse/             AtomFeedParser (XMLParser), ForumTitleParser + LenientHTMLScanner (dependency-free)
Voxglass/Resources/needs-seed.json     ← the floor (build-checked)
Voxglass/Features/Production/Discovery/    ← iPhone surfaces
VoxglassStudio/Features/Discovery/         ← Mac surfaces
VoxglassTests/Production/Discovery/        ← Swift Testing suites + fixtures
```
Dependency rule (Studio Spec §4.1): `Discovery/**` MUST NOT import `URLSession`-bearing modules, `CloudKit`, `StoreKit`, `SwiftUI`, `AppKit`, `UIKit`, or any third-party HTML parser (G-17). All HTTP crosses the `HTTPFetching` seam.

### 4.2 Protocol boundary catalogue (additions to Studio Spec §4.2)
| Protocol | Core file | Concrete (target) | Fake |
|---|---|---|---|
| `HTTPFetching` | `Discovery/HTTPFetching.swift` | `URLSessionFetcher` (Voxglass, VoxglassStudio) | `StubFetcher` (fixtures) |
| `NeedsSource` | `Discovery/Sources/NeedsSource.swift` | 7 sources (Core; net via `HTTPFetching`) | `FakeNeedsSource` |
| `NeedsCaching` | `Discovery/Cache/NeedsCache.swift` | `FileNeedsCache` actor (Core) | `InMemoryNeedsCache` |
| `NeedsRefreshing` | `Discovery/NeedsRefreshing.swift` | `RuntimeNeedsRefresher` (apps; foreground + `BGAppRefreshTask` on iOS) | `FakeRefresher` |
| `TasteRanking` | `Discovery/TasteRanking.swift` | adapter over the existing on-device reco signal (apps) | `FakeTaste` |

`NeedsAggregator`, `NeedsRanker`, `NeedDeduplicator`, `PDVerifier`, `FeaturedSelector`, `AtomFeedParser`, `ForumTitleParser` are **pure Core types** (no protocol needed; injected `HTTPFetching`/`Clock`/`IDGenerator`), fully tested with fixtures.

### 4.3 Concurrency & error model
- The aggregator runs rungs concurrently in a `TaskGroup`, each child bounded by `Task`-level timeout + circuit breaker; children return `Result`-like "contribution or empty" — **a child never rethrows into the group**. This is the mechanical enforcement of Principle 2.
- All discovery errors are `DiscoveryError` values written to the existing diagnostics log (Studio Spec §4.6), never returned to a view model.
- `NeedsCache` is an `actor` (AppDatabase-style); refresh writes last-good atomically.

---

## 5. Domain model (complete source)

```swift
public struct NarrationNeed: Sendable, Codable, Identifiable, Equatable {
    public let id: String                      // NeedID (SHA256Hex, §2.2)
    public let work: NarratableWork            // Studio-adjacent value type (base plan), extended below
    public let signal: NeedSignal
    public let strength: Int                    // 0…100 rank input (source-assigned, §7)
    public let provenance: NeedProvenance
    public let expiresAt: Date?                 // open-project needs expire; evergreen = nil
    public var narratableOn: Set<Platform> {    // DERIVED, never stored (§10)
        work.lengthClass == .short ? [.iOS, .mac] : [.mac]
    }
}

public enum NeedSignal: String, Sendable, Codable, CaseIterable {
    case openProjectNeedsReader   // live, highest
    case proofListenerNeeded
    case weeklyFeatured
    case catalogGap
    case evergreen                // lowest
}
public enum Platform: String, Sendable, Codable { case iOS, mac }
public enum LengthClass: String, Sendable, Codable { case short, long }
public enum WorkGrade: String, Sendable, Codable { case practice, submittable }
public enum PDBasis: String, Sendable, Codable {
    case gutenbergSourced, iaVerifiedEdition, curatorVerified, usOnly, unverified
}
public struct NeedProvenance: Sendable, Codable, Equatable {
    public var sources: [NeedSourceID]          // .seed … .libriVoxForum
    public var firstSeen: Date
    public var lastConfirmed: Date
    public var pdBasis: PDBasis
    public var libriVoxThreadURL: URL?          // for the "how to submit" deep link
}

// NarratableWork (base plan) gains these fields for discovery:
//   lengthClass: LengthClass; grade: WorkGrade; estSeconds: Int
//   sourcePageURL: URL; sourceEPUBURL: URL?; text: String?
//   pinnedWeekOf: Date?; pinnedMonthOf: Date?

public struct NeedsSnapshot: Sendable, Equatable {   // what the aggregator streams
    public var needs: [NarrationNeed]           // ranked, deduped, PD-safe, non-empty
    public var featured: NarrationNeed?          // the featured slot for this platform (§8)
    public var freshness: Freshness             // .liveEnriched | .cached | .seedOnly (drives at most a subtle caption)
}
```

`LengthClass` derivation (centralized, G-10): `.short` iff `estSeconds <= shortWorkCeilingSeconds` (default **3600** = 1 hour). This matches LibriVox's own definition — short works are "short pieces of less than 1 hour read by individuals" — so anything the app labels a short work is exactly what LibriVox's Short Works / Weekly Poetry program accepts from a solo reader. Anything longer is `.long`. Because a work approaching the hour bound is a long sitting on a phone, the iPhone record flow **MUST** support pausing and resuming a recording across sessions (the project is paragraph-addressable, so this falls out of the base-plan model; §10), and the short rail **SHOULD** still lead with the shortest works first (§7) so the fastest first win is always one tap away.

---

## 6. PD verification (the gate with a soft landing)

`PDVerifier.verify(_ work:) -> PDBasis` runs on **every** candidate before a `.submittable` grade may be assigned (G-16). It never throws and never blocks UI; it downgrades.

Rules (MUST):
- `sourcePageURL` host is `gutenberg.org` → `.gutenbergSourced` (US-PD by PG policy).
- host is `archive.org` with a resolvable edition `year ≤ currentYear − 96` (rolling US line; **1930 in 2026**, computed, never hard-coded) → `.iaVerifiedEdition`.
- source is the bundled seed or the pipeline snapshot → `.curatorVerified`.
- title tagged `usOnly` → keep, tag `.usOnly` (valid for the US-PD lane; never presented as globally PD).
- otherwise → `.unverified` → the work MUST NOT be `.submittable`; it is either dropped (L2/L3 default) or offered as `.practice` (records to personal/IA only). The user sees no error — just a clean set where every LibriVox-ready item is genuinely ready.

Because L0 and L1 are pre-verified, a `.submittable` set is always available. `LegalStrings.noCopyrightDetermination` (Studio Spec §22.2) is shown wherever a need's rights are described.

---

## 7. Ranking & dedupe (pure, deterministic)

`NeedsRanker.rank(_ needs:, for platform:, taste:) -> [NarrationNeed]`, stable and deterministic:
1. **Signal priority** — `openProjectNeedsReader > proofListenerNeeded > weeklyFeatured > catalogGap > evergreen`.
2. **Actionability for this platform** — needs whose `narratableOn` includes the current platform rank above handoff-only needs *within the same rail* (but long needs still appear on iPhone in a dedicated "on your Mac" rail, §11).
3. **Taste** — the existing on-device reco signal (poetry listeners → poems first; favorited PD author → their works). No history → neutral.
4. **Shortest-first** within the short rail (fastest first win).
5. **Deterministic tie-break** — by `id`.

Dedupe by `NeedID` before ranking; provenance unions and the **strongest** signal wins (a poem that is both a live weekly and a seed evergreen ranks as `weeklyFeatured`).

---

## 8. Featured selection (folds in the weekly-refresh spec)

The featured slot is **always present and correct on-device**, independent of the network:

```swift
public enum FeaturedCadence: Sendable { case weekly, monthly }
public struct FeaturedSelector: Sendable {
    public func featured(from pool: [NarrationNeed], cadence: FeaturedCadence, on date: Date) -> NarrationNeed?
    // 1. If any need carries a pin for this period (pinnedWeekOf/pinnedMonthOf set by L1/L3), prefer it.
    // 2. Else deterministically rotate: SplitMix64 seeded by (sorted ids, year) → index by ISO week / month (UTC).
    //    Same pool + same period → same pick on every device. Cycles the whole pool before repeating.
    //    NOT Swift.Hasher (reseeds per launch); NOT a fetched value.
}
```
iPhone uses `.weekly` over the short pool → "This Week's Poem". Mac uses `.monthly` over the long pool → "Book of the Month". If a fresher rung supplied a pin (the live LibriVox weekly, or a Wikisource monthly featured text), it wins; otherwise deterministic rotation fills the slot. The slot can never be empty (seed) or stale-blocking (a pin older than one period is ignored, falling back to rotation).

---

## 9. Caching & runtime refresh (both platforms)

- **Cache:** `FileNeedsCache` stores the last-good merged `NeedsSnapshot` and per-source last-fetch + circuit-breaker state. On launch, the aggregator's first stream element is `seed ∪ cache` — instant.
- **Refresh triggers (`RuntimeNeedsRefresher`):**
  - **Foreground on discovery-surface appear** — the workhorse on both platforms; a debounced ladder run that enriches the cache.
  - **iOS `BGAppRefreshTask`** — bonus pre-warm (register at launch, reschedule each run; SwiftUI `.backgroundTask(.appRefresh("guru.parso.voxglass.needs"))`). Discretionary and **not relied upon** — the deterministic featured pick and the seed make correctness independent of it.
  - **macOS** — foreground + a low-frequency timer while the app is open (Mac sessions are long); no background task needed.
- **Politeness (MUST):** each live rung honors the source's caching guidance, sends a descriptive `User-Agent` identifying Voxglass with a contact, respects `robots.txt`, and backs off via the circuit breaker. This is per-launch, low-frequency; never a tight loop.

---

## 10. The iPhone↔Mac narration split

- **Discovery is symmetric:** both platforms show short and long needs.
- **The action is gated** by `narratableOn` (derived from `lengthClass`, §5):
  - **iPhone `.short`** → "Start narrating" opens the base-plan single-work record flow. iPhone supports **multiple** short-work projects via a "My Narrations" library (§11) — this lifts the base plan's single-work taster scope (D-2).
  - **iPhone `.long`** → the card's action is **"Record on Mac"**: a handoff explaining the work is a book best recorded on the Mac, with the phone→Mac continuity note (same `.voxproject` format). **No record CTA is rendered** (G-15).
  - **Mac** → both narratable; short = single-work, long = multi-chapter project built through the existing Source Import → Dashboard flow (Studio Spec §9, §8.2).
- Rationale: recording a book on a phone is ergonomically wrong and the Mac already owns the multi-chapter toolset; the split sharpens the phone→Mac upgrade and keeps each surface honest.

---

## 11. UI specification (Studio Spec §18 style)

### 11.1 iPhone (`Voxglass/Features/Production/Discovery/`)
- **Home shelf** `n01` — "Start a Narration" appended to the listening home below `Recommended for You`, reusing the `.section-head` + card-row pattern. Rails, in order: **This Week's Poem** (featured, weekly), **Short Works to Narrate** (`.short`, shortest-first), **More on Your Mac** (`.long`, aspirational handoff cards — a book cover + "Record on Mac", no record CTA).
- **Narration Needs** screen `n02` — "See all": a browsable, filterable (by signal/subject/length) list; `.short` rows offer "Start narrating"; `.long` rows show "Record on Mac".
- **My Narrations** library `n03` — the user's multiple short-work projects (in-progress + finished), each resumable; entry point to the base-plan record/review/export flow.
- **Long-work handoff** sheet `n04` — what "Record on Mac" opens: a short explainer + the continuity note; no login, no error.

### 11.2 Mac (`VoxglassStudio/Features/Discovery/`)
- **Library section** `n05` — "Start a Narration" in the project Library (Studio `01-project-library`), beside "Start another audiobook". Rails: **Book of the Month** (featured, monthly, `.long`), **Short Works** (`.short`), **Needs a Narrator** (`catalogGap` + live `openProjectNeedsReader` long works — the great-books gaps + open projects). Tapping short → single-work; long → multi-chapter via Source Import.
- **Needs browser** `n06` — a fuller list with filters and the same actions.

### 11.3 Empty, loading, and error copy (normative — the feature's thesis)
The defining property: **almost every failure row is "(nothing shown)".**
| Situation | Copy |
|---|---|
| All live sources failing (offline) | *(no error)* — rails render from cache/seed; **at most** a subtle caption "Offline · showing saved works". |
| Forum needs sign-in / L3 down | *(nothing shown)* — L0–L2 fill the rails; no login prompt ever. |
| A work's PD status unverifiable | *(not shown as LibriVox-ready)* — it either drops or appears with a "Practice" badge; no copyright error. |
| No taste history | rails show shortest evergreen classics first. |
| Featured pool empty | *(cannot happen — the seed guarantees a pick)*. |
| First launch, never fetched | full rails from the bundled seed, instantly. |
| iPhone taps a `.long` need | the handoff sheet `n04` — "This is a book. Record it on your Mac with Voxglass Studio." (never a spinner, never an error). |
| Loading (enrichment in flight) | rails are **already populated** from seed/cache; enrichment updates in place with no spinner over content. |

### 11.4 iPhone narration production flow (post–"Start narrating")

Tapping "Start narrating" on a `.short` need — or choosing an import source — enters an eight-step guided flow that reuses `VoxglassCore` (the base plan's pipeline) end to end. The flow is single-work and short-only on iPhone (`.long` never reaches it; §10). Mockups: `mockups/needs/p01…p08.html`. Each step is a full screen with a bottom action bar; a project may be left and resumed at any step (paragraph-addressable, §5), which is what makes hour-long short works viable on a phone (D-5).

| # | Screen | Mockup | Core reuse | Normative behavior |
|---|---|---|---|---|
| P1 | **Import** | `p01` | `EPUBImporter`, `GutenbergSource`, paste | Four sources: **from a Need** (text pre-filled), **paste text**, **Import EPUB from Files** (the iOS document picker over on-device/iCloud storage — an `.epub` on disk), **Gutenberg** (URL/ID). MUST accept an EPUB chosen from Files via `UIDocumentPickerViewController`; the file is **copied into the project** (Studio Spec §6). Public-domain only; `LegalStrings.noCopyrightDetermination` shown. |
| P2 | **Source review** | `p02` | `Segmenter`, `LibriVoxScriptGenerator` | Shows parsed title/author, the segmented lines (verse preserved), and the **auto-inserted LibriVox disclaimer** as intro/outro paragraphs (visibly marked). For a multi-work EPUB, a piece picker precedes this. `import.chapterCount` a11y id present. |
| P3 | **Record** | `p03` | `AudioSessionCapture` (iOS), metering-isolation | Teleprompter + live input meter + waveform + transport (record / play take / play-in-context) + **Accept & Next / Re-record / Flag** + takes + per-paragraph status dots. MUST finalize and preserve a take on interruption (call/route change; Studio Spec §11). Multiple takes per paragraph; exactly one selected. |
| P4 | **Review** | `p04` | `ReviewQueueResolver`, review fold | Paragraph list with status (approved / flagged / not recorded), filter, per-paragraph play / re-record / note. Re-record routes back to P3 for that paragraph only. Ready-to-assemble when no `needsPickup` remains. |
| P5 | **Assemble** | `p05` | `SegmentQueueBuilder`, `AssemblySettings`, render cache | Non-destructive spacing (paragraph gap default 0.45 s, head/tail room-tone) + a full-piece render preview the user can play. Nothing is re-encoded until export. |
| P6 | **Metadata & rights** | `p06` | `RightsEvidence`, `DestinationProfile` metadata sets | Fields for **both** LibriVox and Internet Archive, each chip-labeled by destination: title, author, narrator/reader, language, description, subjects, date, source URL. The **rights attestation is deferred to here** (base plan refinement) — pre-filled for catalog works, a single confirm. `LegalStrings.noCopyrightDetermination` shown. |
| P7 | **Validate & export** | `p07` | `ValidationRuleEngine`, `VoxTranscoder` (LAME + FLAC) | The validation subset runs and is shown (metadata/rights/**disclaimer present**/**human-only**/clipping/level), warnings non-blocking. Destinations: **LibriVox** → 128 kbps **CBR mono 44.1 kHz MP3** + ID3 + filename (`FilenameSanitizer`) + checklist; **Internet Archive** → **FLAC lossless master + MP3 derivative** + `metadata.json` + checksums (`opensource_audio`). Export MUST NOT begin with any blocking issue (Studio Spec §18.5 copy). |
| P8 | **Submit & hand off** | `p08` | package builders | Completion surface: the produced files, **Share / Save to Files**, **Submit to LibriVox** (checklist + deep link to the current Weekly Poetry/Short Works thread), **Prepare Internet Archive upload**. The tool prepares; **the user submits** — no auto-upload, no login (Studio Spec C-7, G-12). |

Rules: the flow MUST NOT reference `LicenseGate` anywhere (the PD lane is free; G-2). AI narration is never offered on this path (human-only lane; G-1). FLAC/MP3 encoding uses the linked-library transcoder (no subprocesses on iOS); if the encoder can't load, the affected destination is unavailable with the Studio Spec §18.5 "Encoder unavailable" copy — the other destination still works.

---

## 12. Testing, fixtures, and CI gates

### 12.1 Core suites (Swift Testing; Studio Spec §19.3 style — no simulator)
- `NeedsAggregatorTests` — merge/dedupe by `NeedID`; provenance union; **`allSourcesFail_seedFloorReturnedNonEmpty`** (every rung throws/times-out → result is the seed, non-empty, ranked, PD-safe); **`firstStreamElementIsInstantFloor`** (no network awaited before the first emission); circuit-breaker skips a flapping rung.
- `PDVerifierTests` — Gutenberg → `.gutenbergSourced`; too-recent IA edition → `.unverified` → not `.submittable`; `usOnly` tagged; seed → `.curatorVerified`; rolling-year ceiling computed (1930 in 2026, 1931 in 2027).
- `NeedsRankerTests` — signal priority; platform actionability; shortest-first; deterministic tie-break.
- `LengthClassTests` — boundary at `shortWorkCeilingSeconds == 3600` (a 59-minute work is `.short`; a 61-minute work is `.long`); `.long.narratableOn == {.mac}`; `.short.narratableOn == {.iOS,.mac}`.
- `FeaturedSelectorTests` — deterministic weekly/monthly; flips at ISO-week / month boundary (`FixedClock`, UTC); pin honored; stale pin ignored; empty-pool guard.
- Source parse suites with **fixtures of real payloads**: `GutendexSourceTests`, `PoetryDBSourceTests`, `IASourceTests`, `WikisourceSourceTests`, `LibriVoxForumSourceTests` — the last including the observed title corpus (`[WEEKLY POETRY] - X by Y`, `[SOLO] …`, `[OPEN - US ONLY] [DR] …`, `~[GROUP] …`, `COMPLETE …`) and a **sign-in-redirect fixture that yields nothing**.
- `NeedsCacheTests` — last-good persistence; per-source breaker state; stale expiry.

### 12.2 Device smoke tests (Studio Spec §19.6 style; local only)
- **iPhone — discovery + full production flow** (`VoxglassUITests`, `-uiTestSeed needsOffline` — **all live rungs stubbed to fail**, `FakeAudioCapture`, a bundled fixture `.epub`): home → "Start a Narration" shows populated rails (proving the floor) → `import.files` → the Files picker selects the fixture `.epub` (`import.files.selected`) → Source review shows `import.chapterCount` + the auto-disclaimer (`record.disclaimerParagraph`) → `import.acceptStructure` → Record (`record.teleprompter`, `record.transport.record`, `record.acceptAndNext` through all paragraphs via fake capture) → Review (`review.toAssemble`) → Assemble (`assemble.playChapter`, `assemble.toMetadata`) → Metadata (`metadata.attest`, `metadata.toExport`) → Validate & export with **both** `export.destination.librivox` and `export.destination.internetArchive` on → `export.run` → `export.packageReady` with `export.submitToLibriVox` present. Then tap a seeded `.long` need → assert the **handoff** `n04` appears with **no record CTA**. (Asserts the p01–p08 path end-to-end, incl. EPUB-from-Files and FLAC+MP3 export, with no network or mic.)
- **Mac** (`VoxglassStudioUITests`, `-uiTestSeed needsLong`): Library → "Start a Narration" → "Needs a Narrator" card → multi-chapter Source Import → Dashboard ready. (Added to the existing Studio smoke set.)

### 12.3 CI gates (additions to Studio Spec §19.9)
| # | Gate | Rule |
|---|---|---|
| **G-13** | Discovery never fails visibly | `Discovery/**` aggregator's public API is total; the Core test target MUST contain a test named matching `allSourcesFail_seedFloor`. |
| **G-14** | No sign-in UI in discovery | Files under `**/Discovery/**` MUST NOT reference `login`, `signIn`, `ASWebAuthenticationSession`, `credential`, `password`, or present any auth view; the forum source MUST NOT import UI. |
| **G-15** | iPhone never records long works | `Voxglass/Features/Production/Discovery/**` MUST NOT render a start-narrating CTA for a need whose `narratableOn` excludes `.iOS`; the smoke test asserts the handoff for a `.long` need. |
| **G-16** | PD gate before submittable | `NeedsAggregator` MUST reference `PDVerifier`; no code path assigns `.submittable` without a non-`.unverified` `PDBasis` (test-enforced). |
| **G-17** | Discovery is dependency-free & I/O-seamed | `Discovery/**` MUST NOT `import` a URLSession-bearing module directly (only `HTTPFetching`) and MUST NOT import any third-party HTML parser. |
| **G-18** | The floor exists | Build-time: `needs-seed.json` parses and contains ≥ 100 `.short` and ≥ 20 `.long` entries, each with a non-`.unverified` PD basis. |
| (reuse **G-12**) | No auto-upload | Discovery reads only; no `librivox.org`/`archive.org` URL reaches an upload/data-task. |

---

## 13. Stage plan (Studio Spec §20 style)

- **N1 — Discovery core.** Domain (§5), `SeededNeedsSource` + `needs-seed.json`, `NeedsAggregator` + `NeedsRanker` + `NeedDeduplicator`, `PDVerifier`, `FeaturedSelector`, `NeedsCache`, all pure with fixtures. **Ships when `allSourcesFail_seedFloor` and `firstStreamElementIsInstantFloor` pass.**
- **N2 — Clean rungs.** `HTTPFetching` + `URLSessionFetcher`; L1 snapshot; L2 sources (Gutendex, PoetryDB, IA, Wikisource), each independent behind the circuit breaker; foreground refresh; last-good cache.
- **N3 — Live forum rung (ships in v1; MUST, D-4).** `LibriVoxForumNeedsSource` (Atom `feed.php` → lenient-HTML fallback), title-corpus parse, PD gate, sign-in-invisible behavior; iOS `BGAppRefreshTask`. This rung is the app's live LibriVox tie-in (§1.6) and is **not deferrable** — but it MUST land behind the same ladder contract, so N3 is not "done" until the `allSourcesFail_seedFloor` and sign-in-wall tests still pass with L3 wired.
- **N4 — iPhone surfaces + production flow.** Home shelf `n01`, Needs screen `n02`, **My Narrations (multiple short works)** `n03`, long-work handoff `n04`; and the full eight-step production flow `p01…p08` (§11.4): Import (incl. **EPUB from Files**), Source review + auto-disclaimer, Record, Review, Assemble, Metadata & rights, Validate & export (**FLAC + MP3**), Submit/hand off. Wire `.short` needs and imports → this flow; `.long` → handoff. Requires the iOS `AudioSessionCapture` concrete and the iOS `libmp3lame` + `libFLAC` slices (base plan P0/P1; D-6).
- **N5 — Mac surfaces.** Library "Start a Narration" `n05` (Book of the Month + Short Works + Needs a Narrator), Needs browser `n06`; long → multi-chapter Source Import.
- **N6 — Hardening.** Smoke tests (§12.2), airplane-mode pass, VoiceOver, circuit-breaker/timeout tuning, diagnostics.

---

## 14. Appendices

### 14.1 Accessibility identifier registry (additions to Studio Spec §22.1)
```
iPhone:
  home.startNarrationShelf · needs.rail.<case> · needs.card.<slug>
  needs.featured · needs.seeAll · needs.filter.<case>
  need.startNarrating.<slug> · need.recordOnMac.<slug> · need.grade.<case>
  myNarrations.list · myNarrations.project.<slug> · myNarrations.newFromNeed
  handoff.title · handoff.continueOnMac · handoff.dismiss
iPhone — narration production flow (§11.4, p01–p08):
  import.fromNeed · import.paste · import.files · import.filesPicker · import.files.selected · import.gutenberg
  import.chapterCount · import.resegment · import.acceptStructure
  record.teleprompter · record.disclaimerParagraph · record.inputLevel
  record.transport.record · record.transport.playTake · record.transport.playInContext
  record.acceptAndNext · record.flagAndNext · record.previousParagraph · record.take.<n> · record.importWAV
  paragraphList.filter.<case> · paragraphList.playSelected · review.toAssemble
  assemble.renderPreview · assemble.playChapter · assemble.paragraphGap · assemble.headSilence · assemble.tailSilence · assemble.toMetadata
  metadata.title · metadata.author · metadata.narrator · metadata.language · metadata.description · metadata.subjects · metadata.sourceURL · metadata.attest · metadata.toExport
  validate.report · export.destination.librivox · export.destination.internetArchive · export.filename · export.run
  export.packageReady · export.share · export.submitToLibriVox · export.uploadToArchive
Mac (Studio):
  library.startNarrationSection · library.bookOfMonth · library.needsARarrator.<slug>
  library.shortWork.<slug> · needsBrowser.open · needsBrowser.filter.<case>
  need.startNarrating.<slug> · need.grade.<case>
```

### 14.2 Legal strings
Reuse Studio Spec §22.2 `LegalStrings` (`noCopyrightDetermination`, `noAcceptanceGuarantee`, `userSubmits`). Discovery adds none; it MUST show `noCopyrightDetermination` wherever a need's rights appear and MUST NOT claim acceptance.

### 14.3 Error/issue codes
Discovery diagnostics only (never issues): `DISC.sourceTimeout`, `DISC.sourceParse`, `DISC.sourceAuthWall`, `DISC.pdUnverified`, `DISC.cacheMiss`, `DISC.breakerOpen`. None surface to the user.

### 14.4 Risk register
| Risk | Mitigation |
|---|---|
| A live source (esp. the forum) becomes unreliable or blocks the app's IP | Ladder + circuit breaker + last-good cache + seed floor; forum is the lowest rung and never load-bearing; polite, low-frequency, cached fetches. |
| Sign-in requirement spreads to reads | L3 yields nothing; no login UI (G-14); L0–L2 carry the feature. |
| A non-PD work slips into `.submittable` | PD gate (G-16) before submittable; L2/L3 default to `.practice`/drop when unverifiable; seed/snapshot pre-verified; disclaimer always shown. |
| iPhone users try to record books | Action gate (G-15) + handoff; discovery still shows them to seed the upsell. |
| Featured slot stale/empty | Deterministic on-device rotation over the seed; stale pins ignored. |
| Curation/seed drift | The seed is build-checked (G-18); the pipeline (L1) re-verifies and re-runs the LibriVox-API gap dedupe per publish. |

### 14.5 Deferred (post-MVP)
On-device **authenticated** forum reads (a signed-in session for richer live data — pursue only if LibriVox blesses it; note the **anonymous** L3 rung ships in v1 per §1.6 / D-4 and is *not* deferred); direct submission integrations; multi-language discovery beyond English; a "narration streak" habit loop; sharing a completed short work directly to the relevant LibriVox thread via the system share sheet.
