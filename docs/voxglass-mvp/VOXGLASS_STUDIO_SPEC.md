# Voxglass Audiobook Studio — MVP v1 Complete Specification & Implementation Guide

**Status:** Build-ready specification. Supersedes nothing; *expands* `VOXGLASS_STUDIO_IMPLEMENTATION_PLAN.md` (2026-07-29) in the same directory into an implementation-complete document.
**Repository:** `johnarleyburns/parso-voxglass` (GPLv3 + App Store additional permission).
**Date:** 2026-07-30.
**Audience:** an agentic coding system implementing the MVP end to end, plus the human reviewing its commits.
**Scope thesis:** *Voxglass Studio is a complete audiobook creation and distribution pipeline for a solo human narrator — free and unlimited for LibriVox and Internet Archive contribution, with a one-time $149 Pro unlock for commercial/retail deliverables. No subscription. No speech synthesis anywhere in the product.*

---

---

## Table of contents

| § | Section | What it settles |
|---|---|---|
| 0 | How to use this document | reading order, normative language, corrections to the source plan, glossary, repo conventions |
| 1 | Product definition | user, jobs, platform surfaces, the three distribution lanes, principles |
| 2 | The free / Pro boundary | exactly what $149 buys and what must stay free forever |
| 3 | Distribution targets | LibriVox, Internet Archive, ACX/Audible, Apple Books/aggregators — every constant, with sources |
| 4 | Architecture | modules, protocol seams, concurrency, errors, package layout, entitlements, CloudKit container |
| 5 | Domain model | complete Swift source for every persisted type |
| 6 | Package & asset store | `.voxproject` on disk, content addressing, manifest, storage accounting |
| 7 | Persistence | SQLite schema, migrations, store API, hot queries, autosave and crash recovery |
| 8 | Document lifecycle | library, creation, multi-window, undo |
| 9 | Text pipeline | EPUB/DOCX/MD/TXT import, segmentation, stable paragraph identity, drift, split/merge |
| 10 | Generated scripts | LibriVox disclaimers and retail credits as recordable paragraphs |
| 11 | Audio | capture, metering isolation, import & silence segmentation, the metrics algorithms |
| 12 | Assembly & playback | segments, gaps, render plans, cache keys, gapless player |
| 13 | Sync | CloudKit projection, proxies, publish policy, watch relay, error recovery |
| 14 | Review | events, fold semantics, queues, cross-device flows |
| 15 | Validation | 53 rules with thresholds and severities per destination |
| 16 | Packaging & export | encoders and licensing, mastering chain, the three builders, artifacts, wizard |
| 17 | Licensing & StoreKit | product, provider, gate, caching, placement rules |
| 18 | UI specification | every screen on Mac, iPhone, CarPlay, and Watch |
| 19 | Testing & CI | suites, fixtures, smoke tests, budgets, eighteen grep gates |
| 20 | Stage plan | S1–S12 with acceptance criteria and the three human walkthroughs |
| 21 | Release & operations | versioning, App Store, re-verification, checklist |
| 22 | Appendices | a11y registry, legal strings, deviations, backlog, risks, quickstart, anti-patterns |

## 0. How to use this document

### 0.1 Reading order for an implementing agent

This document is written so that a coding agent can implement the product **without re-deriving decisions**. Every section that describes behavior also states the *test* that proves the behavior and the *file* that should contain it.

1. Read §1 (product definition) and §2 (free/Pro boundary) once. These constrain everything downstream; getting the economic boundary wrong is the single most expensive mistake in the codebase because it leaks `isPro` checks into recording and review code that must stay free forever.
2. Read §3 (distribution targets). This is the research dossier. All numeric constants in the validation engine and export profiles trace back to §3; do not invent thresholds elsewhere.
3. Read §4 (architecture) and §5 (domain model). These are the shape of the code.
4. Implement stage by stage from §20. Each stage is a single reviewable commit with a stated acceptance test. Do not skip ahead: later stages assume earlier fixtures exist.
5. Consult §6–§19 as reference while implementing a stage. They are written as normative specification, not narrative.

### 0.2 Normative language

- **MUST / MUST NOT** — a CI gate, a test, or a reviewer will reject the change if violated.
- **SHOULD** — deviate only with a comment in the code explaining why.
- **MAY** — genuinely optional; implement the simplest thing.
- **DEFERRED** — explicitly out of MVP v1. Do not build it, do not stub toward it, do not add a protocol method "for later."

### 0.3 Corrections to the source plan

The source implementation plan is broadly correct and this document adopts its structure. Five decisions in it are **wrong or under-specified against the actual repository state**, and this specification overrides them. An implementing agent MUST follow the corrections below, not the original.

| # | Source plan said | Reality | This spec says |
|---|---|---|---|
| C-1 | "GRDB over SQLite … *matches existing stack*" | The repo has **no GRDB dependency**. Persistence is a hand-rolled `public actor AppDatabase` over `SQLite3` (`Voxglass/Core/Database/AppDatabase.swift`) with an integer-keyed migration list in `DatabaseMigrations.swift`. | **Do not add GRDB.** Extend the existing `AppDatabase` actor pattern into a new `ProjectDatabase` actor scoped to one `.voxproject`. Rationale in §7.1. This keeps `VoxglassCore` dependency-free, keeps the GPL dependency surface at zero, and avoids a second ORM in one binary. |
| C-2 | "Swift 6, strict concurrency on" | `Package.swift` is `swift-tools-version: 5.9`; `project.yml` sets `SWIFT_VERSION: "5.0"`. Flipping the whole repo to Swift 6 is a multi-day migration of 146 existing Swift files and is not MVP work. | Bump `Package.swift` to `swift-tools-version: 6.0`. Set `swiftLanguageMode(.v6)` **per-target on the new Studio/production targets only**; leave the existing `VoxglassCore` target at `.v5` with `.enableUpcomingFeature("StrictConcurrency")` warnings-only. §4.4. |
| C-3 | "bundle ffmpeg … Voxglass is GPL-3.0, so ffmpeg/LAME/libFLAC are license-compatible" | GPL-compatibility is only half the problem. A **GPL-configured** ffmpeg cannot be shipped through the Mac App Store, because the App Store additional permission in `LICENSE-APPSTORE-EXCEPTION.md` is granted by *this repository's* copyright holder and cannot bind ffmpeg's authors. | Ship **LGPL-only** encoders: `libmp3lame` (LGPL-2.1), `libFLAC` (BSD-3), and AVFoundation for AAC/ALAC. Link them **dynamically** from an embedded framework, or build ffmpeg with `--disable-gpl --disable-nonfree`. Detailed recipe, sandbox entitlements, and the written-offer obligation in §16.3. |
| C-4 | Export presets list "ACX 192 kbps" as `retailACX` | ACX/Audible is *one* commercial destination among several, and its file rules (per-chapter files, ≤120 min, opening/closing credit files, retail sample) are as important as its bitrate. | Model commercial output as a **family** of destination profiles (ACX/Audible, Findaway-style aggregator, Apple Books, generic M4B, lossless archive master), driven by a data table (§3.4) rather than two hard-coded constants. |
| C-5 | Watch smoke test "may need hosted-logic fallback" | Prior work in this repo already resolved this: watchOS UI smoke tests do run locally via `scripts/test.sh`, with known gotchas (row taps need `.contentShape`, sheets are not `NavigationPath` destinations, the simulator must be pre-booted, and seeders must be idempotent). | Keep the **XCUITest** watch smoke test. Follow the gotcha list in §19.6. CI does not run simulators (see `scripts/test.sh` header: "Does NOT run in CI"); the simulator suite is a **local pre-commit gate** (the pre-push hook runs `swift test` only). |

Two further clarifications the source plan left implicit:

- **C-6 — "Non-AI" is a product policy, not merely a code-absence policy.** The MVP contains no synthesis. But the *reason* it matters commercially is that LibriVox categorically bans machine-generated audio (§3.2.6), and retail distributors increasingly require disclosure of synthetic narration. The `AudioOrigin.aiImported` label therefore has to survive round-trips through SQLite, CloudKit, packaging manifests, and the validation report — it is compliance metadata, not a UI nicety. §5.6.
- **C-7 — "Distribution" in this product means *prepare and hand off*, never *auto-publish*.** Voxglass MUST NOT upload to LibriVox, archive.org, ACX, or any retailer in MVP v1. It produces a directory of correctly named, correctly encoded, correctly tagged files plus a human-readable submission checklist. Rationale and the exact wording of the disclaimers in §3.6 and §16.9.

### 0.4 Definition of "done" for the whole MVP

The MVP is done when all of the following hold simultaneously:

1. All Swift Testing suites (`VoxglassCoreTests`, `VoxglassStudioTests`) pass via `swift test` on the macOS host.
2. All five UI smoke tests pass locally via `scripts/test.sh --all` (iPhone, Watch, and the three macOS Studio destination smoke tests). These are the only UI tests in the repository.
3. All CI gates in §19.9 pass (grep gates + compile-only builds for iOS/watchOS/macOS).
4. The three end-to-end acceptance walkthroughs in §20.13 have been executed by a human on real hardware with a real microphone: a LibriVox package, an Internet Archive package, and a Pro retail package, each produced from the same project and each validated by the rule engine.
5. `docs/voxglass-mvp/` contains a filled-in `RELEASE_CHECKLIST.md` (template in §21.4).

### 0.5 Glossary

Terms are used with these exact meanings throughout. Where the mockups use a different word, the mockup wording is the *user-facing* string and the term here is the *code* term.

| Term | Meaning | User-facing string |
|---|---|---|
| **Project** | One audiobook in production. Persisted as a `.voxproject` package. | "Audiobook", "Project" |
| **Chapter** | An ordered division of a project that maps 1:1 to one delivered audio file in every destination profile. | "Chapter" |
| **Paragraph (¶)** | The atomic recordable and reviewable unit. Has stable identity across re-imports. | "Paragraph", "¶" |
| **Take** | One recorded or imported audio capture of exactly one paragraph. A paragraph may have many; exactly zero or one is *selected*. | "Take" |
| **Selected take** | The take that participates in assembly, playback, projection, and export. | "Selected" |
| **Accepted paragraph** | A paragraph with a selected take. Note: acceptance ≠ approval. | "Recorded" |
| **Approved paragraph** | A paragraph whose review state is `.approved`. | "Approved" |
| **Needs pickup** | Review state meaning "must be re-recorded". Blocking for export. | "Needs pickup" |
| **Assembly** | The non-destructive plan that turns selected takes + spacing settings into a continuous chapter. | "Assembly" |
| **Render** | Materializing an assembly into a single audio file (cached, content-addressed). | "Render" |
| **Projection** | The reduced, read-only copy of a project published to CloudKit for phone/watch/CarPlay review. Contains only selected takes as compressed proxies. | "Preview" |
| **Review event** | An append-only, idempotent fact emitted by any device: flag, approve, pickup, note. | (invisible) |
| **Destination profile** | A data record describing one delivery target's audio format, naming rule, metadata requirements, and validation thresholds. | "Destination" |
| **Package / bundle** | The output directory an export produces. | "Export package" |
| **Eligibility** | Whether a project may be packaged for a given destination, primarily gated by narration origin and rights attestation. | "Eligible" |
| **Pro** | The one-time $149 unlock covering commercial/retail output only. | "Voxglass Studio Pro" |

### 0.6 Repository conventions this document inherits

Observed from the existing repo; new code MUST match.

- **Project generation:** XcodeGen from `project.yml`. Never hand-edit `Voxglass.xcodeproj`. After changing `project.yml`, run `xcodegen generate`.
- **Bundle ID prefix:** `guru.parso`. The Studio app is `guru.parso.voxglass.studio`.
- **Package layout:** `VoxglassCore` is an SwiftPM target whose `path` is `Voxglass/Core` — i.e. Core source lives *inside* the app directory. New Core code goes in `Voxglass/Core/<Area>/`.
- **Existing test target:** `VoxglassCoreTests` has `path: VoxglassTests`. That means Core unit tests and app-level tests share a directory today; new production code tests go in `VoxglassTests/Production/` to keep them separable.
- **Style:** 4-space indent, `public` on Core API, `internal` default, no force-unwraps outside tests, `// MARK: -` section headers in files over ~150 lines, doc comments (`///`) on every `public` symbol.
- **Persistence style:** hand-rolled SQLite via `AppDatabase`-style actors, `DatabaseValue` binding enum, integer-numbered append-only migrations (`DatabaseMigration.all`).
- **Async style:** `actor` for stateful I/O, `async throws` protocol methods, `AsyncStream` for event feeds, `@Observable` for view models. `ObservableObject` is banned in new code.
- **Commits:** one per stage, imperative subject, body listing the acceptance criterion satisfied.

---

## 1. Product definition

### 1.1 One-sentence definition

Voxglass Studio is a macOS audiobook production environment for a single human narrator, in which the entire book is addressed **by paragraph** rather than by waveform, and which finishes the job by emitting submission-ready packages for LibriVox, the Internet Archive, and commercial retail.

### 1.2 The user and the job

The target user is a **solo narrator** — a LibriVox volunteer, an indie author narrating their own book, or a semi-professional narrator producing for ACX/Findaway. They are not an audio engineer. They own a USB interface and a decent microphone. They record in a spare room. Their real problems, in the order they hit them:

1. **Keeping their place.** A 10-hour book is 3,000+ paragraphs. Tracking which are recorded, which were flubbed, and which were re-recorded is the dominant cost. DAWs address audio by time; narrators think in text.
2. **Proofing.** Listening to your own recording is the least pleasant, most necessary step. It is also the step most amenable to being done away from the desk — walking, driving, doing dishes. Nothing on the market lets a narrator proof a *work in progress* on a phone or a watch without exporting and sideloading.
3. **Retake bookkeeping.** "I flagged paragraph 218 on my walk" must become "paragraph 218 is queued for re-record when I sit down," with the note attached, automatically.
4. **The submission wall.** LibriVox rejects files for bitrate, naming, volume, and disclaimer errors. ACX rejects for RMS, peak, noise floor, and structure. Both feedback loops are days long. A narrator learns these rules by having their work bounced.
5. **Rights anxiety.** "Is this public domain?" and "can I put this on Audible?" are questions the tool must *organize evidence for* without pretending to answer.

Voxglass's product answer, in order: paragraph-addressed production (1), cross-device preview and review without publishing (2, 3), a validation engine that encodes the destinations' actual rules (4), and a rights-evidence record plus a narration-origin audit (5).

### 1.3 What the MVP is not

**DEFERRED — do not build, do not stub toward:**

- Any speech synthesis, TTS, voice cloning, voice conversion, on-device model inference, model download, or cloud AI call. There is a CI gate (§19.9 gate G-1).
- Forced alignment / automatic speech-to-text alignment of takes to text. Paragraph boundaries come from *how the take was recorded* (one take per paragraph) or from *manual* split markers on import.
- Multi-narrator collaboration, role assignment, or dramatic-reading coordination. Solo only.
- Noise reduction, de-essing, de-clicking, EQ, or compression as *editing* features. The MVP measures audio quality and reports it; the Pro tier applies a fixed, documented mastering chain (§16.7) and nothing more.
- Waveform-level destructive editing. Trims are non-destructive instructions; the original take file is never mutated.
- Automatic upload to any destination.
- iPad-optimized Studio, Vision Pro, Windows/Linux.
- Team/organization licensing, subscriptions, consumables.

### 1.4 Platform surfaces and their jobs

| Surface | Target | Job | May create audio? |
|---|---|---|---|
| **VoxglassStudio** (macOS 14+) | New app target | Everything: import, record, assemble, validate, package. The only place audio is captured. | Yes |
| **Voxglass** (iOS 17+) | Existing app | Consumer audiobook listening (existing) **plus** production preview and review. | No |
| **CarPlay scene** (in Voxglass) | Existing scene | Hands-free review of a flagged queue while driving. | No |
| **VoxglassWatch** (watchOS 10+) | Existing app | Wrist review of a downloaded queue, including offline; dictated notes. | No |

The asymmetry is deliberate and load-bearing: **capture is Mac-only** and **CloudKit is Mac+phone-only**. The watch speaks only to the phone (§13.6). This is what keeps the watch target small, the sync model single-writer, and the review flow conflict-free.

### 1.5 The three distribution lanes

Everything in the product funnels into exactly three lanes. The lane is chosen at project creation (mockup `02-new-project`, "Project purpose") and may be changed later in Metadata & Rights.

| Lane | Purpose value | Price | Narration origin | Primary output |
|---|---|---|---|---|
| **Community / LibriVox** | `.publicDomainCommunity` | Free | Human only (enforced, blocking) | 128 kbps CBR mono MP3 per chapter + submission checklist |
| **Archive / Internet Archive** | `.publicDomainCommunity` or `.personal` | Free | Any (AI must be disclosed in metadata) | Lossless masters + optional MP3 derivatives + metadata manifest + checksums |
| **Commercial / Retail** | `.commercial` | **Pro, $149 one-time** | Any (disclosure required for synthetic) | Mastered per-chapter MP3/WAV/FLAC, chapterized M4B, retail sample, validation report |

A fourth *implicit* lane, **Personal**, produces nothing but local playback and preview; it is free and always available.

### 1.6 Product principles (resolve ambiguity with these)

When the specification is silent, decide in this order:

1. **Never lose a take.** Recording is sacred. Any crash, interruption, disk-full, or device-change must leave the just-recorded audio recoverable. This mirrors the standing project constraint that playback position is never lost; the production analogue is that captured audio is never lost.
2. **The text is the index.** If a feature can be expressed as an operation on paragraphs, express it that way rather than on time offsets.
3. **Non-destructive by default.** Original captures are immutable; everything else is a plan that can be recomputed.
4. **Free must be complete.** A LibriVox volunteer must be able to produce and submit an entire book without ever seeing a paywall, an upsell interstitial, or a watermark.
5. **The tool prepares; the human submits.** No auto-upload, no claims about copyright status, no guarantee of acceptance.
6. **Offline is the normal case.** Recording, review, assembly, validation, and export all work with no network. Sync is an accelerant, not a dependency.

---

## 2. The free / Pro boundary

### 2.1 Economic model

- **One product. One purchase. $149 USD, non-consumable, one-time.** No subscription, no tiers above it, no consumables, no per-book unlocks.
- StoreKit 2, product identifier `guru.parso.voxglass.studio.pro`.
- Family Sharing: **enabled**. A single household purchase covers the household.
- The purchase is per-Apple-ID and syncs across the user's Macs automatically via StoreKit's transaction history. There is no server, no account, no license key.
- Refunds are Apple's; the app MUST handle a revoked transaction by reverting to free (§17.5).

### 2.2 The boundary, stated exactly

**Free forever (MUST NOT reference `LicenseGate`, `isPro`, or `ProFeature` anywhere in their implementation):**

- Project creation, unlimited projects, unlimited length.
- Source import (EPUB/TXT/Markdown/DOCX), segmentation, script editing, split/merge, direction and pronunciation notes.
- Recording, unlimited takes, take comparison, import of external audio.
- Quality metrics, per-take and per-project.
- Assembly, spacing, render, local playback.
- CloudKit preview, iPhone review, Watch review, CarPlay review, dictated notes, offline queues.
- The validation engine in full, for every target — including retail targets. *A free user can see exactly what would fail an ACX submission.* They simply cannot produce the deliverable.
- **LibriVox package export**, complete and unlimited.
- **Internet Archive package export**, complete and unlimited.
- Lossless personal export of chapter WAVs for the user's own listening. (Rationale: this is not "economic output"; it is the user's own recording of their own voice, and blocking it would be hostile. It is deliberately *not* the same thing as the mastered retail master.)

**Pro ($149), gated in exactly one place:**

| `ProFeature` | What it unlocks | Why it is the economic boundary |
|---|---|---|
| `.retailPresets` | ACX/Audible, Apple Books, aggregator, and generic-retail destination profiles in the Export wizard | These exist only to earn money on a retail platform. |
| `.mastering` | The documented master chain: loudness normalization to target RMS, true-peak limiting, head/tail room-tone normalization, optional high-pass | The difference between "my recording" and "a sellable deliverable." |
| `.m4bExport` | Chapterized M4B with embedded chapters, cover, and metadata | Primary commercial container. |
| `.flacExport` | FLAC masters | Requested almost exclusively for commercial archival/aggregator delivery. |
| `.batchExport` | Export all chapters unattended, with resume | Scales with book count; the professional's time-saver. |
| `.commercialMetadata` | ISBN/ASIN/UPC fields, rights-holder and publisher records, retail sample generation, copyright/production-year statements | Commercial-only metadata. |
| `.validationReportExport` | Writing the validation report to disk as JSON/HTML for a client or QA | Free users see the report on screen; Pro exports it. |

**Deliberately NOT gated** (tempting but forbidden — each of these would violate principle 4):

- Number of projects, chapters, paragraphs, takes, or minutes.
- Recording quality or sample rate.
- Cloud preview or device count.
- Any part of review.
- The rule engine's analysis.
- LibriVox or Internet Archive output in any respect.

### 2.3 How the gate is implemented (summary; full spec §17)

There is exactly one type that may consult entitlement:

```swift
public struct LicenseGate: Sendable {
    public let provider: any LicenseProvider
    public func require(_ feature: ProFeature) async throws  // throws LicenseError.proRequired(feature)
    public func isUnlocked(_ feature: ProFeature) async -> Bool  // for UI affordances only
}
```

`LicenseGate` MUST be referenced only from files matching `Export*`, `Packaging*`, `RetailMaster*`, `Master*`, `License*`, `Settings*`. CI gate G-2 (§19.9) enforces this by grep. Any recording, review, sync, assembly, or preview file that references it fails the build.

The UI shows Pro affordances as **labeled but visible**: the retail card in the Export wizard is always present, always describes what it does, and carries the "Pro · $149" chip with an "Unlock Pro" button (mockup `14-export-wizard`). It is never hidden, never a nag, and never interrupts a free workflow.

### 2.4 Purchase UX rules

- Purchase is reachable from exactly two places: the Export wizard's retail card, and Settings → License.
- Purchase never blocks an in-progress action mid-flight. If a user starts a retail export while unlicensed, the wizard stops at destination selection *before* any work is done.
- After purchase, the export continues from where it stopped without re-entering data.
- Restore Purchases is always visible in Settings → License, even when already Pro.
- If the user is offline and previously purchased, the cached entitlement (§17.4) keeps Pro active. Entitlement caching is a *convenience*, never a lock: on cache miss and no network, the app resolves to **free**, shows "Verifying purchase…" and retries; it never shows a purchase prompt to a known-Pro user because the network is down.
---

## 3. Distribution targets — research dossier and normative profiles

This section is the **single source of truth for every numeric constant** used by the validation engine (§15) and the packaging builders (§16). Constants are repeated nowhere else in this document and MUST be defined exactly once in code, in `DestinationProfile` / `ValidationThresholds` (§5.9).

Each subsection ends with a **Profile** block: the literal data the implementation encodes.

> **Verification obligation.** External platform requirements change. The implementation MUST keep the human-readable citation next to each constant in `DestinationProfiles.swift` as a `///` comment with the date it was last verified (`// verified 2026-07-30`). §21.3 defines the re-verification checklist for each release.

### 3.1 Summary matrix

| | LibriVox | Internet Archive (community audio) | ACX / Audible | Apple Books (direct/aggregator) | Aggregator generic (Findaway-style) | Personal / archive master |
|---|---|---|---|---|---|---|
| Tier | Free | Free | **Pro** | **Pro** | **Pro** | Free |
| Container/codec | MP3 | FLAC or WAV master (+ optional MP3) | MP3 | M4B (AAC) or MP3 chapter files | MP3 or WAV | WAV or FLAC |
| Sample rate | 44.1 kHz | 44.1 or 48 kHz (preserve master) | 44.1 kHz | 44.1 kHz | 44.1 kHz | native (48 kHz default) |
| Bit depth | n/a (lossy) | 16- or 24-bit | n/a | n/a | n/a | 24-bit |
| Channels | Mono | Mono (preserve) | Mono strongly preferred | Mono or stereo, consistent | Mono | Mono |
| Bitrate | 128 kbps **CBR** | n/a for master; 128–192 kbps derivative | **192 kbps CBR minimum** | ≥128 kbps AAC | 192 kbps CBR | n/a |
| One file per | Chapter/section | Chapter (originals) | Chapter/section | Whole book (M4B) or chapter | Chapter | Chapter |
| Max file length | ~1 hour recommended per section | none | **120 minutes** | none practical | 120 minutes typical | none |
| Loudness rule | ~89 dB perceived (86–92 range) | none | **−23 to −18 dBFS RMS** | −23 to −18 dBFS RMS (follows ACX practice) | −23 to −18 dBFS RMS | none |
| Peak rule | avoid clipping | avoid clipping | **≤ −3 dBFS** | ≤ −3 dBFS | ≤ −3 dBFS | ≤ −1 dBFS |
| Noise floor | "clean"; no numeric rule | none | **≤ −60 dBFS RMS** | ≤ −60 dBFS RMS | ≤ −60 dBFS RMS | reported only |
| Head/tail silence | short, tidy | none | **0.5–1 s head, 1–5 s tail** room tone | same as ACX | same as ACX | preserved |
| Opening/closing credits | LibriVox disclaimer (mandatory, scripted) | none | Mandatory, as separate files | Mandatory | Mandatory | none |
| Retail sample | no | no | **1–5 min, required** | recommended | required | no |
| AI/synthetic narration | **Prohibited outright** | Allowed (disclose) | Allowed with disclosure/approval | Allowed with disclosure | Allowed with disclosure | Allowed |
| Cover art | project-level, 1:1 | 1:1 recommended | 2400×2400 px min, 1:1, RGB JPG | 1:1, high-res | 1:1 ≥2400 px | optional |
| Upload by Voxglass | **Never** | **Never** | **Never** | **Never** | **Never** | n/a |

Sources for the numbers in this matrix are listed in §3.7. The two rows that carry the most product weight are the **AI row** (which drives `EligibilityProfile`) and the **loudness/peak/noise row** (which drives the mastering chain and the bulk of the validation rules).

### 3.2 LibriVox

LibriVox is a volunteer project that produces public-domain audiobooks and hosts them on the Internet Archive. It is the free lane's primary destination and the one with the most *procedural* rules — which is exactly why encoding them in software is valuable.

#### 3.2.1 Audio format

- **MP3, 128 kbps, constant bit rate.** VBR is not acceptable for submitted files.
- **44.1 kHz** sample rate.
- **Mono.** (Solo spoken word is mono; stereo doubles file size for no benefit and is called out as a mistake.)
- Perceived volume normalized to roughly **89 dB** on the scale reported by ReplayGain-style tools such as MP3Gain/Checker, with an accepted band of **86–92 dB**. This is a *perceived-loudness* measure, not dBFS, and the mapping is not exact; §15.6 defines how Voxglass approximates it and why the corresponding rule is a **warning**, not a blocking error.

**Implementation note.** The 86–92 dB figure comes from LibriVox's proof-listening tooling, which historically used MP3Gain's ReplayGain analysis with an 89 dB reference. Voxglass computes ReplayGain-equivalent loudness (§11.6) and maps it to that scale; because the mapping depends on the analyzer, Voxglass reports the value, warns outside the band, and **never blocks** on it.

#### 3.2.2 Structure

- One MP3 per **section**, where a section is normally a chapter. Sections should generally be kept to a reasonable length (roughly an hour or less); very long single files are discouraged.
- Every section carries a **spoken intro and outro** (§3.2.3).
- Sections are numbered in reading order, matching the project's catalogue listing.

#### 3.2.3 The disclaimer — mandatory scripted text

Every section MUST begin with the LibriVox disclaimer, spoken by the narrator. The canonical long form, used at minimum for the first section:

> "Chapter *N* of *Title*. This is a LibriVox recording. All LibriVox recordings are in the public domain. For more information, or to volunteer, please visit librivox dot org."
>
> [optional] "Recording by *NarratorName*."
>
> "*Title*, by *Author*. [Translated by *Translator*.] *Chapter title*."

For second and subsequent sections a shortened form is permitted:

> "Chapter *N* of *Title*. This LibriVox recording is in the public domain."

At the end of each section:

> "End of *Chapter title*." [optionally followed by "Recording by *NarratorName*, *city / site*."]

And at the end of the final section:

> "End of *Title*, by *Author*."

**Product requirement.** Voxglass MUST NOT synthesize this text (that would be TTS and would also violate LibriVox policy). Instead:

1. `LibriVoxScriptGenerator` (§16.4) generates the exact intro/outro **text** for every section from project metadata.
2. The generated text is inserted into the project as **synthetic paragraphs** at the head and tail of each chapter, with `ParagraphRole.libriVoxIntro` / `.libriVoxOutro`, so the narrator simply records them like any other paragraph in the normal recording workflow.
3. The validation engine emits a **blocking** issue for a LibriVox target if any chapter lacks a recorded intro or outro paragraph.
4. Regenerating the script when metadata changes MUST preserve any existing recordings whose text is unchanged, and mark drifted ones `needsPickup` (same machinery as §9.5 text drift).

This is the single highest-leverage feature in the free lane: it converts LibriVox's most common rejection cause into a checklist item that cannot be forgotten.

#### 3.2.4 File naming

LibriVox project pages specify a per-project filename template in the project's first forum post, and the volunteer MUST follow it exactly. The near-universal convention is:

```
<shorttitle>_<NN>_<authorlastname>.mp3
```

- all **lowercase**
- **no spaces** (use `_`)
- ASCII only; strip diacritics and punctuation
- `<NN>` is the zero-padded section number, padded to the width needed for the largest section number (2 digits up to 99, 3 digits at 100+)
- `<shorttitle>` is an abbreviated, unpunctuated form of the title, typically ≤ 20 characters
- `<authorlastname>` is the author's surname, lowercased and de-accented

Files hosted on archive.org additionally acquire a bitrate suffix in the *derivative* filenames (e.g. `..._128kb.mp3`, historically `..._64kb.mp3`). **Voxglass MUST NOT add a bitrate suffix**; that is applied by the archive's derivation pipeline, not the contributor.

`FilenameSanitizer` (§16.5) implements this rule and is exhaustively unit-tested (§19.3), because it is pure, high-risk, and cheap to test.

#### 3.2.5 ID3 tags

LibriVox uses ID3v2 tags; the uploader normalizes them, but contributors are expected to supply sane values:

| Frame | Value |
|---|---|
| `TIT2` (Title) | Section title, e.g. "01 - Breakfast Table" |
| `TPE1` (Artist) | Author |
| `TALB` (Album) | Book title |
| `TRCK` (Track) | Section number |
| `TYER`/`TDRC` (Year) | Year of the LibriVox recording |
| `TCON` (Genre) | "Speech" |
| `COMM` (Comment) | Optional; project URL |
| `TPE2`/`TPE3` | Narrator (as performer) |

Voxglass writes these via the tagging layer in §16.6 and includes them in the submission checklist so the volunteer can confirm against the project's first post.

#### 3.2.6 AI policy — the hard rule

LibriVox **does not allow** audio recordings, project summaries, or cover images made with artificial (nonhuman) intelligence technology: computer-generated content, machine learning, language models, and similar. LibriVox recordings are made by volunteers using their own voices. Detected machine-generated content is removed from the project or the catalogue and the responsible member is notified; repeated violations lead to formal warnings and ultimately a ban.

**Product consequence (normative):**

- If **any selected take** in the project has `AudioOrigin.aiImported`, the LibriVox destination is **ineligible**. The Export wizard shows the LibriVox card disabled with the reason; the validation engine emits `IssueCode.aiOriginInLibriVoxProject` at severity `.blocking`; `LibriVoxPackageBuilder.build` throws `PackagingError.ineligible(.librivox, reason:)` **before** transcoding anything.
- Unselected AI takes do **not** taint the project. Eligibility is evaluated over *selected* takes only, because unselected takes are not part of the delivered work. This is asserted by `EligibilityProfileTests`.
- The Metadata & Rights screen shows a **Narration Origin Audit** (mockup `11-metadata-rights`): counts of human-origin vs AI-origin paragraphs, with a link to a filtered paragraph list. This is the user's self-audit surface and must remain accurate at all times.
- Voxglass MUST NOT attempt to *detect* AI narration in imported audio. It records what the user declared at import time. The import sheet (mockup `07-import-audio`) forces an explicit choice among *External human recording* / *AI-generated or AI-processed* / *Unknown*, with `.unknown` treated as AI-tainted for LibriVox purposes (fail closed).

#### 3.2.7 Rights

LibriVox publishes only works in the **public domain in the United States**, and recordings are released into the public domain. Contributors must identify the source text and its public-domain basis. Voxglass captures this as `RightsEvidence` (§5.7): basis, source URL (e.g. a Project Gutenberg or archive.org edition page), edition year, and free-text evidence notes, plus a required **attestation checkbox**: *"I attest this information is accurate."* The validation engine emits a blocking issue for a LibriVox target when the source URL or attestation is missing.

Voxglass MUST display, adjacent to any rights UI: **"Voxglass does not determine copyright status."** (Exact string in §22.2.)

#### 3.2.8 Submission workflow (what the package must support)

A LibriVox contributor's real workflow is: claim/start a project on the forum → record sections → post each finished MP3 to a file host or the LibriVox uploader → a proof-listener checks it → the MC catalogues it. Voxglass therefore produces:

1. `Exports/LibriVox/<projectslug>/` containing the correctly named, tagged MP3s.
2. `section-durations.txt` — a plain list of `filename  MM:SS` lines, because section durations are a standard part of the forum post.
3. `librivox-checklist.md` — a generated, human-readable checklist (§16.4.3) covering: 128 kbps CBR confirmed, 44.1 kHz mono confirmed, disclaimer present in every section, filenames matching the project template, ID3 tags set, perceived volume in band, total run time, and the reminder that the contributor must post to the forum themselves.
4. `metadata.json` — machine-readable mirror of the same facts, for future tooling.

#### 3.2.9 Profile

```swift
static let librivox = DestinationProfile(
    id: .librivox,
    displayName: "LibriVox Contribution",
    tier: .free,
    audio: .init(container: .mp3, codec: .mp3, sampleRate: 44_100, channels: 1,
                 bitrateKbps: 128, isCBR: true, bitDepth: nil),
    fileGranularity: .perChapter,
    maxFileDuration: nil,                     // recommended ≤ ~1 h; warning only
    filenameRule: .librivoxLowercaseNoSpace,
    requiredMetadata: [.title, .author, .narrator, .language, .sourceURL, .rightsBasis, .rightsAttestation],
    requiresHumanNarration: true,             // ← the hard rule
    requiresScriptedDisclaimer: true,
    loudness: .replayGainBand(low: 86, high: 92, target: 89),   // warning-only
    peakCeilingDBFS: -0.3,                    // clipping guard only
    noiseFloorCeilingDBFS: nil,
    headroomSilence: nil,
    retailSample: nil,
    artwork: .optionalSquare(minPx: 1000),
    emitsChecksums: true,
    autoUpload: false                          // always false; there is no other value
)
```

### 3.3 Internet Archive

The Internet Archive is where LibriVox files ultimately live, and it is also a first-class destination in its own right for public-domain and personal recordings that are not LibriVox projects (translations, modern PD works, non-English readings, community collections).

#### 3.3.1 Item model

An archive.org **item** is a directory with an **identifier** and a set of files plus metadata. Key facts that shape the package:

- The **identifier** is globally unique, immutable after creation, and constrained: ASCII alphanumerics, `-`, `_`, `.`; typically 5–80 characters; conventionally lowercase; must not collide with an existing item. Voxglass generates a **suggested** identifier (`IdentifierSuggester`, §16.5.3) as `<titleslug>_<authorslug>_<narratorslug>` truncated, and clearly labels it as a suggestion the user must confirm on the archive.
- `mediatype` is set **at upload time and cannot be changed afterwards**. For audiobooks it MUST be `audio`.
- `collection` determines where the item appears. Community audio uploads default to `opensource_audio`. Items may be uploaded to `test_collection` first, which is automatically purged after roughly 30 days — the ideal **dry-run** path, and Voxglass exposes it as a checkbox ("Community/test collection profile" in mockup `14-export-wizard`).
- Uploaded files are **originals**; the archive derives additional formats itself. Contributors therefore upload the **best available master** and let derivation produce streaming formats.

#### 3.3.2 Metadata fields Voxglass emits

| Field | Source | Notes |
|---|---|---|
| `identifier` | suggested, user-confirmed | immutable |
| `mediatype` | constant `audio` | immutable after upload |
| `collection` | `opensource_audio` or `test_collection` | user choice |
| `title` | project title | |
| `creator` | author | repeated field allowed |
| `performer` / `narrator` | narrator | custom field; archive tolerates arbitrary keys |
| `date` | recording year | ISO 8601 preferred |
| `language` | project language | ISO 639 code plus display name |
| `description` | project description + provenance paragraph | HTML permitted |
| `subject` | subjects list | repeated |
| `licenseurl` | e.g. `https://creativecommons.org/publicdomain/mark/1.0/` for PD works, or a CC URL when the narrator chooses one | |
| `rights` | free-text rights statement generated from `RightsEvidence` | |
| `source` | source edition URL | |
| `notes` | narration-origin disclosure line (see below) | |
| `runtime` | total duration `H:MM:SS` | |
| `scanner` / `uploader-software` | `Voxglass Studio <version>` | provenance |

**Narration-origin disclosure.** If the project contains any AI-origin selected take, the manifest MUST include a `notes` line: *"Contains narration generated or processed with AI voice technology."* This is not required by the archive but is required by this product's integrity rules, and it is what makes the "any origin allowed here" position defensible.

#### 3.3.3 Files in the package

```
Exports/InternetArchive/<identifier>/
  <identifier>_01_<chapterslug>.flac        # or .wav — lossless masters (originals)
  <identifier>_02_<chapterslug>.flac
  ...
  <identifier>_01_<chapterslug>.mp3         # optional derivative set (user opt-in)
  <identifier>.jpg                          # cover art
  <identifier>_meta.json                    # metadata manifest (Voxglass format)
  <identifier>_meta.xml                     # archive-style metadata XML (convenience)
  <identifier>_files.sha256                 # checksum manifest
  submission-checklist.md
```

The archive itself generates `*_meta.xml` and `*_files.xml` server-side; the copies Voxglass writes are for the contributor's own verification and for a future upload integration. They MUST be clearly named and documented as local artifacts.

#### 3.3.4 Upload

**Voxglass does not upload.** The checklist explains the two supported manual paths: the web upload form at archive.org, or the `ia` command-line tool (`ia upload <identifier> <files> --metadata=...`). The checklist MUST include a ready-to-paste `ia upload` command generated from the manifest — this is genuinely useful, costs nothing, and keeps the human in control of the actual publish action. Generating a command is not uploading; the app never executes it.

#### 3.3.5 Profile

```swift
static let internetArchive = DestinationProfile(
    id: .internetArchive,
    displayName: "Internet Archive",
    tier: .free,
    audio: .init(container: .flac, codec: .flac, sampleRate: nil /* preserve master */,
                 channels: nil /* preserve */, bitrateKbps: nil, isCBR: false, bitDepth: nil /* preserve */),
    secondaryAudio: .init(container: .mp3, codec: .mp3, sampleRate: 44_100, channels: 1,
                          bitrateKbps: 192, isCBR: true, bitDepth: nil),   // optional derivative
    fileGranularity: .perChapter,
    maxFileDuration: nil,
    filenameRule: .archiveIdentifierPrefixed,
    requiredMetadata: [.title, .author, .narrator, .language, .date, .identifier, .licenseURL],
    requiresHumanNarration: false,
    requiresScriptedDisclaimer: false,
    loudness: nil,
    peakCeilingDBFS: -0.1,
    noiseFloorCeilingDBFS: nil,
    headroomSilence: nil,
    retailSample: nil,
    artwork: .optionalSquare(minPx: 1000),
    emitsChecksums: true,
    autoUpload: false
)
```

### 3.4 Commercial / retail (Pro)

The commercial lane is a family of profiles sharing one mastering chain and one structural model, differing in container and packaging.

#### 3.4.1 ACX / Audible — the reference standard

ACX's requirements are the de-facto industry baseline; most other retailers accept ACX-compliant files. All of the following are enforced by the validation engine at **blocking** severity for retail targets.

| Requirement | Value | Voxglass rule code |
|---|---|---|
| Measured **RMS** per file | between **−23 dBFS and −18 dBFS** | `rmsOutOfRange` |
| **Peak** per file | **no peak above −3 dBFS** | `peakTooHot` |
| **Noise floor** (RMS measured in silent passages) | **−60 dBFS or lower** | `noiseFloorTooHigh` |
| Format | **MP3, 192 kbps or higher, CBR, 44.1 kHz** | `formatMismatch` |
| Channels | mono strongly preferred; must be consistent across all files | `channelInconsistency` |
| File structure | **one file per section/chapter**; the whole book may not be a single file | `fileGranularity` |
| Max file length | **120 minutes** | `fileTooLong` |
| Section header | each file announces its section ("Chapter One") where the manuscript has one | `missingSectionHeader` (warning) |
| Opening credits | separate file: title, subtitle, author, narrator | `missingOpeningCredits` |
| Closing credits | separate file: "The end", copyright/production statement | `missingClosingCredits` |
| Room tone | **0.5–1 s at head, 1–5 s at tail** of each file | `headTailRoomTone` |
| Retail sample | **1–5 minutes**, starting with narration (not credits or music) | `missingRetailSample` |
| Consistency | all files from the same session/voice/setup; no audible mismatch | reported via `loudnessDiscontinuity` |
| Cover | square, ≥ 2400 × 2400 px, RGB JPG | `artworkTooSmall` |

**Target, not just range.** The mastering chain targets **−20 dBFS RMS** (mid-band) and a **−3.5 dBFS** true-peak ceiling (0.5 dB inside the limit, because MP3 encoding can raise inter-sample peaks above the PCM peak). §16.7 specifies the chain exactly.

**Noise floor measurement.** ACX measures noise floor as the RMS of the *silent* portions of the file. Voxglass's implementation (§11.6.4) must therefore measure noise floor over detected silence windows, not over the whole file — a whole-file "minimum RMS" is a different and wrong number. This is the most commonly mis-implemented metric in this category of tool and is worth a dedicated test fixture.

#### 3.4.2 Opening and closing credits as project structure

Like the LibriVox disclaimer, credits are handled as **generated text the narrator records**, not as synthesized audio:

- `RetailScriptGenerator` produces an *opening credits* paragraph (`ParagraphRole.retailOpeningCredits`) and a *closing credits* paragraph (`.retailClosingCredits`) from metadata:
  - Opening: "*Title*. [*Subtitle*.] Written by *Author*. Narrated by *Narrator*."
  - Closing: "This has been *Title*, written by *Author*, narrated by *Narrator*. [Copyright *Year* *RightsHolder*. Production copyright *Year* *Producer*.] The end."
- These live in synthetic chapters `__opening_credits__` and `__closing_credits__` that sort first and last and export as their own files.
- A retail export with an unrecorded credits paragraph is blocked.

#### 3.4.3 Retail sample

The retail sample is a 1–5 minute excerpt starting with narration. Voxglass generates it as a **derived render** from a user-chosen paragraph range:

- Default selection: the first contiguous run of approved paragraphs, beginning after the opening credits, whose accumulated duration is ≥ 90 s, extended to the next paragraph boundary until ≥ 120 s or ≤ 300 s.
- The user can change the start paragraph and length in the Export wizard; the UI shows resulting duration live.
- The sample is mastered with the same chain and exported as `<slug>-retail-sample.mp3`.
- Validation: duration in [60 s, 300 s]; must not start inside credits; must be non-silent in the first 2 s.

#### 3.4.4 M4B (chapterized)

M4B is an MPEG-4 audio container (AAC) with embedded chapter markers, used by Apple Books, many aggregators, and every serious offline listener.

- Codec **AAC-LC**, 44.1 kHz, mono, **128 kbps** default (user-selectable 64/96/128/192).
- Chapters: one chapter marker per project chapter, with title and start time, embedded as a chapter track (`chpl`/QuickTime chapter track) — both the text track and the Nero-style `chpl` atom SHOULD be written for maximum player compatibility.
- Cover art embedded as `covr`.
- Metadata: `©nam` (title), `©ART` (author), `©wrt` (narrator/composer field is commonly used for narrator by convention — Voxglass writes narrator to both `©wrt` and a custom `----:com.apple.iTunes:NARRATOR` atom), `©alb`, `©day`, `©gen` = "Audiobook", `stik` = 2 (Audiobook), `pgap` = 1 (gapless).
- Because AVFoundation *can* encode AAC and write MPEG-4, M4B production does **not** require the bundled encoder — but chapter-atom writing does require either `AVAssetWriter` plus a chapter-metadata group (supported: `AVAssetWriterInputMetadataAdaptor` / timed metadata group with `AVMetadataIdentifier.quickTimeUserDataChapter`) or the ffmpeg path. §16.8 specifies the AVFoundation-first implementation with an ffmpeg fallback.

#### 3.4.5 Apple Books and aggregators

Apple Books ingests either a chapterized M4B or per-chapter files with a package manifest, depending on the delivery route (direct vs aggregator). Because direct Apple ingestion requires a publisher account and a delivery tool Voxglass will not integrate with, the product exposes an **"Apple Books / aggregator"** profile that produces:

- a chapterized M4B (§3.4.4), **and**
- a per-chapter MP3 set at 192 kbps CBR, **and**
- a metadata sidecar (`delivery-metadata.json`) with title, subtitle, series, author(s), narrator(s), publisher, publication date, ISBN/ASIN if supplied, language, categories, description, copyright and production-copyright lines, and the abridgement flag,

so the user can satisfy essentially any aggregator's intake form from one folder. This is deliberately generic; Voxglass does not claim compatibility with any specific retailer's automated ingestion.

#### 3.4.6 Retail profiles

```swift
static let acx = DestinationProfile(
    id: .acx, displayName: "ACX / Audible", tier: .pro,
    audio: .init(container: .mp3, codec: .mp3, sampleRate: 44_100, channels: 1,
                 bitrateKbps: 192, isCBR: true, bitDepth: nil),
    fileGranularity: .perChapter,
    maxFileDuration: 120 * 60,
    filenameRule: .freeformNumbered,
    requiredMetadata: [.title, .author, .narrator, .language, .cover, .copyrightYear, .rightsBasis, .rightsAttestation],
    requiresHumanNarration: false,
    requiresScriptedDisclaimer: false,          // but requires credits paragraphs
    requiresCredits: true,
    loudness: .rmsWindow(minDBFS: -23, maxDBFS: -18, targetDBFS: -20),
    peakCeilingDBFS: -3.0,
    noiseFloorCeilingDBFS: -60.0,
    headroomSilence: .init(headMin: 0.5, headMax: 1.0, tailMin: 1.0, tailMax: 5.0),
    retailSample: .init(minDuration: 60, maxDuration: 300, mustStartWithNarration: true),
    artwork: .requiredSquare(minPx: 2400, colorSpace: .rgb, format: .jpeg),
    emitsChecksums: true, autoUpload: false
)

static let appleBooksAggregator = DestinationProfile(
    id: .appleBooksAggregator, displayName: "Apple Books / Aggregator", tier: .pro,
    audio: .init(container: .m4b, codec: .aacLC, sampleRate: 44_100, channels: 1,
                 bitrateKbps: 128, isCBR: false, bitDepth: nil),
    secondaryAudio: .init(container: .mp3, codec: .mp3, sampleRate: 44_100, channels: 1,
                          bitrateKbps: 192, isCBR: true, bitDepth: nil),
    fileGranularity: .wholeBookChapterized,
    maxFileDuration: nil,
    filenameRule: .freeformNumbered,
    requiredMetadata: [.title, .author, .narrator, .language, .cover, .publisher, .copyrightYear, .description],
    requiresHumanNarration: false, requiresScriptedDisclaimer: false, requiresCredits: true,
    loudness: .rmsWindow(minDBFS: -23, maxDBFS: -18, targetDBFS: -20),
    peakCeilingDBFS: -3.0, noiseFloorCeilingDBFS: -60.0,
    headroomSilence: .init(headMin: 0.5, headMax: 1.0, tailMin: 1.0, tailMax: 5.0),
    retailSample: .init(minDuration: 60, maxDuration: 300, mustStartWithNarration: true),
    artwork: .requiredSquare(minPx: 2400, colorSpace: .rgb, format: .jpeg),
    emitsChecksums: true, autoUpload: false
)

static let losslessMaster = DestinationProfile(              // FREE personal master
    id: .personalMaster, displayName: "Lossless Chapter Masters", tier: .free,
    audio: .init(container: .wav, codec: .pcm, sampleRate: nil, channels: nil,
                 bitrateKbps: nil, isCBR: false, bitDepth: nil),   // preserve capture format
    fileGranularity: .perChapter, maxFileDuration: nil,
    filenameRule: .freeformNumbered,
    requiredMetadata: [.title],
    requiresHumanNarration: false, requiresScriptedDisclaimer: false, requiresCredits: false,
    loudness: nil, peakCeilingDBFS: -0.1, noiseFloorCeilingDBFS: nil,
    headroomSilence: nil, retailSample: nil, artwork: .none,
    emitsChecksums: true, autoUpload: false
)
```

`.flac` masters (`ProFeature.flacExport`) are the same as `losslessMaster` with `container: .flac`. FLAC is gated because in practice it is requested for commercial archival delivery; WAV masters remain free so no one is ever locked out of their own audio.

### 3.5 What the destination model must *not* encode

- **No retailer account state.** Voxglass has no notion of the user's ACX account, royalty share, or rights territory.
- **No pricing or royalty math.**
- **No ISBN purchase or registration.** ISBN/ASIN are optional free-text metadata fields.
- **No claim of certification.** The UI must never say "ACX approved" or "LibriVox compliant". Permitted phrasing: "Checked against ACX's published requirements" / "Prepared for LibriVox submission."

### 3.6 Legal-safety strings (normative, exact text)

These strings appear verbatim in the UI and in generated checklists. They are the product's liability boundary and MUST NOT be reworded without review.

| Key | String | Where |
|---|---|---|
| `legal.noCopyrightDetermination` | "Voxglass does not determine copyright status." | New Project wizard (rights step), Metadata & Rights, every export checklist |
| `legal.noAcceptanceGuarantee` | "Voxglass prepares files; it does not guarantee acceptance or determine copyright." | Export wizard footer (matches mockup `14-export-wizard`) |
| `legal.librivoxHumanOnly` | "LibriVox accepts only recordings made by human volunteers using their own voices. This project contains imported AI-generated audio and is not eligible." | LibriVox card when ineligible; validation issue detail |
| `legal.userSubmits` | "You submit these files yourself. Voxglass never uploads on your behalf." | Every export completion screen |
| `legal.aiDisclosure` | "Contains narration generated or processed with AI voice technology." | IA manifest `notes`; retail `delivery-metadata.json` |

### 3.7 Sources

Verified 2026-07-30. Re-verify per §21.3 before each release.

- LibriVox tech specs and recording guidance — https://wiki.librivox.org/index.php/Tech_Specs · https://librivox.org/pages/about-recording/ · https://wiki.librivox.org/index.php/Newbie_Guide_to_Recording
- LibriVox disclaimer wording — https://wiki.librivox.org/index.php/LibriVox_disclaimer
- LibriVox AI policy — https://wiki.librivox.org/index.php?title=LibriVox_and_Artificial_Intelligence_(AI) · https://wiki.librivox.org/index.php/Recording_%26_Text_Policies
- LibriVox M4B guidance — https://wiki.librivox.org/index.php/How_To_Make_M4B_Files
- Internet Archive metadata reference — https://archive.org/developers/internetarchive/cli.html · https://internetarchive.readthedocs.io/en/stable/metadata.html
- Internet Archive item structure and derivatives — https://blog.archive.org/2011/03/31/how-archive-org-items-are-structured/ · https://archive.org/help/derivatives.php · https://help.archive.org/help/audio-and-music-items-a-basic-guide/
- ACX audio submission requirements (RMS/peak/noise floor/format) — https://www.trevorohare.com/blog/understanding-the-acx-submission-requirements-for-audio · https://chapterpass.com/learn/acx-audio-requirements · https://www.homebrewaudio.com/27097/acx-audio-submission-requirements-what-the-heck-do-they-mean/
- ACX structural requirements (per-section files, 120-minute cap, credits, retail sample) — https://www.hanna-eng.com/guides/acx-audiobook-requirements/ · https://evolvesystemsgroup.com/knowledge-base/article/audio-book-tech-requirements
- RMS loudness normalization practice for ACX — https://us.auphonic.com/blog/2026/01/15/rms-loudness-normalization-for-audible-acx/
---

## 4. Architecture

### 4.1 Module topology

```
Voxglass/Core/                      → SwiftPM target "VoxglassCore" (existing, extended)
  ├── (existing consumer areas: Catalog, Library, Playback, Database, Services, CarPlay, Models)
  └── Production/                   ← ALL new MVP code lives here
        ├── Domain/                 AudiobookProject and friends; pure value types
        ├── Package/                .voxproject on disk; content-addressed asset store
        ├── Store/                  ProjectDatabase actor + schema + migrations + ProductionStore
        ├── Text/                   importers, segmenter, drift detection, script generators
        ├── Audio/                  protocols, metrics math, silence/segment analysis (NO AVFoundation session)
        ├── Assembly/               segment queues, render plans, cache keys
        ├── Review/                 events, fold, queues, predicates
        ├── Validation/             thresholds, rules, report
        ├── Destinations/           DestinationProfile literals + registry (Destinations/DestinationProfiles.swift), filename sanitizer, identifier suggester
        ├── Packaging/              builders, manifests, checklists, checksum writer
        ├── Sync/                   ProductionSyncEngine protocol, projection builder, record mappers
        ├── WatchLink/              WatchTransport protocol + payloads
        └── License/                LicenseProvider protocol, ProFeature, LicenseGate

VoxglassStudio/                     → NEW macOS app target
  ├── App/                          StudioApp, StudioRootView, DI container, launch-arg seeding
  ├── Services/                     AVAudioEngineCapture, AVMetricsCalculator, AVSegmentPlayer,
  │                                 Transcoder (LAME/FLAC/AVFoundation), CloudKitProductionSync,
  │                                 StoreKitLicenseProvider, WatchConnectivity? (no — Mac has none)
  └── Features/                     Library, NewProject, SourceImport, Script, Record, Import,
                                    TakeCompare, Review, Assembly, Metadata, DevicePreview,
                                    Validation, Export, Settings

> **Module topology note (§4.1):** the `DestinationProfile` **literals** (the five
> profiles and `profile(for:)`) live in `Destinations/DestinationProfiles.swift`;
> the **type** declaration stays in `Domain/DestinationTypes.swift`. CI gate G-10
> names the literals file, so the platform numbers have one defined home.

Voxglass/Features/Production/       → NEW iPhone feature folder
Voxglass/App/CarPlay/Production*    → CarPlay production templates (extends existing CarPlay layer)
VoxglassWatch/Production/           → NEW watch feature folder

VoxglassCoreTestSupport/            → NEW SwiftPM target, test-only: fakes + fixtures
```

**Dependency rule (CI-enforced):**

- `VoxglassCore/Production` MUST NOT import `AVFoundation`'s session APIs, `CloudKit`, `StoreKit`, `WatchConnectivity`, `SwiftUI`, `AppKit`, or `UIKit`. It MAY import `AVFoundation` **types only** where unavoidable — and the MVP avoids even that by expressing audio I/O through protocols and passing PCM as `[Float]`/`Data`.
- App targets depend on Core, never the reverse.
- Every platform capability crosses the boundary as a Core-defined protocol with (a) a concrete implementation in an app target and (b) a fake in `VoxglassCoreTestSupport`.

### 4.2 The protocol boundary catalogue

This is the complete list of seams. If an implementation needs a capability not on this list, that is a design change requiring a new row here.

| Protocol | Core file | Concrete (target) | Fake |
|---|---|---|---|
| `ContentAddressedStore` | `Package/ContentAddressedStore.swift` | `FileAssetStore` (Core; pure FS) | `InMemoryAssetStore` |
| `ProductionStore` | `Store/ProductionStore.swift` | `SQLiteProductionStore` (Core) | `InMemoryProductionStore` |
| `AudioCapturing` | `Audio/AudioCapturing.swift` | `AVAudioEngineCapture` (Studio) | `FakeAudioCapture` |
| `AudioMetricsCalculating` | `Audio/AudioMetrics.swift` | `AVMetricsCalculator` (Studio) | `FixtureMetricsCalculator` |
| `AudioDecoding` | `Audio/AudioDecoding.swift` | `AVAudioDecoder` (Studio/iOS) | `FixtureDecoder` |
| `AudioTranscoding` | `Packaging/AudioTranscoding.swift` | `VoxTranscoder` (Studio) | `FakeTranscoder` |
| `SegmentPlayer` | `Assembly/SegmentPlayer.swift` | `AVSegmentPlayer` (Studio, iOS, Watch) | `FakeSegmentPlayer` |
| `ProductionSyncEngine` | `Sync/ProductionSyncEngine.swift` | `CloudKitProductionSync` (Studio, iOS) | `FakeSyncEngine` |
| `WatchTransport` | `WatchLink/WatchTransport.swift` | `WatchConnectivityTransport` (iOS, watchOS) | `FakeWatchTransport` |
| `LicenseProvider` | `License/LicenseProvider.swift` | `StoreKitLicenseProvider` (Studio) | `FakeLicenseProvider` |
| `ArtworkStore` | `Package/ArtworkStore.swift` | `FileArtworkStore` (Core) | `InMemoryArtworkStore` |
| `Clock` | `Domain/Clock.swift` | `SystemClock` | `FixedClock` |
| `IDGenerator` | `Domain/IDGenerator.swift` | `UUIDGenerator` | `SequentialIDGenerator` |

`Clock` and `IDGenerator` exist because review events, render cache keys, and package manifests all embed timestamps and UUIDs, and deterministic tests are impossible otherwise. Every Core type that needs `Date()` or `UUID()` MUST take one of these; direct calls to `Date()`/`UUID()` in `Core/Production` are a review rejection (and grep gate G-7).

### 4.3 Dependency injection

No DI framework. A plain composition root per app:

```swift
// VoxglassStudio/App/StudioEnvironment.swift
@MainActor
final class StudioEnvironment {
    let store: any ProductionStore
    let assets: any ContentAddressedStore
    let capture: any AudioCapturing
    let metrics: any AudioMetricsCalculating
    let player: any SegmentPlayer
    let transcoder: any AudioTranscoding
    let sync: any ProductionSyncEngine
    let license: LicenseGate
    let clock: any Clock
    let ids: any IDGenerator

    static func live(package: ProjectPackage) throws -> StudioEnvironment
    static func test(seed: UITestSeed) -> StudioEnvironment      // chosen by -uiTestSeed
}
```

The environment is created once per open project window and handed to view models by initializer injection. SwiftUI `@Environment` is used only to pass the already-built `StudioEnvironment` down the view tree, never to construct services.

**Launch-argument override (required for smoke tests):**

```swift
if ProcessInfo.processInfo.arguments.contains("-useTemporaryStore") { /* temp dir package */ }
if let seed = UITestSeed(arguments: ProcessInfo.processInfo.arguments) { env = .test(seed: seed) }
```

When any `-uiTestSeed` is present, the environment MUST use fakes for `AudioCapturing`, `ProductionSyncEngine`, `LicenseProvider`, and `AudioTranscoding`. The microphone, CloudKit, StoreKit, and the encoder helper MUST NOT be touched in tests — this is CI gate G-8 (assert the fakes are wired by asserting a debug-only `env.isTestEnvironment` flag in each smoke test's first assertion).

### 4.4 Concurrency model

**Language mode.** Bump `Package.swift` to tools 6.0:

```swift
// swift-tools-version: 6.0
.target(name: "VoxglassCore", path: "Voxglass/Core",
        resources: [.process("Resources/CuratedLists")],
        swiftSettings: [.swiftLanguageMode(.v5), .enableUpcomingFeature("StrictConcurrency")],
        linkerSettings: [.linkedLibrary("sqlite3")]),
.target(name: "VoxglassCoreTestSupport", dependencies: ["VoxglassCore"],
        path: "VoxglassCoreTestSupport",
        swiftSettings: [.swiftLanguageMode(.v6)]),
```

New app targets set `SWIFT_VERSION: "6.0"` in `project.yml`; existing `Voxglass` and `VoxglassWatch` stay at 5.0 for MVP and are migrated separately (DEFERRED). New files added to those targets MUST still be written Swift-6-clean (no shared mutable global state, `Sendable` value types) so the later migration is mechanical.

**Rules:**

1. All domain types are `Sendable` value types (`struct`/`enum`). No classes in `Core/Production/Domain`.
2. Stateful I/O is an `actor`: `ProjectDatabase`, `FileAssetStore` (actor for write serialization), `RenderCacheActor`, `SyncCoordinator`.
3. View models are `@Observable` classes annotated `@MainActor`.
4. Audio callbacks (`AVAudioEngine` taps) run on a real-time thread. **Nothing** allocating, locking, or `async` may run in a tap. Taps write into a preallocated ring buffer and signal a consumer task. §11.3.
5. `AsyncStream` is the standard event feed (review events from transport, metering frames, capture level). Streams are single-consumer; a broadcast need is a design smell.
6. Cancellation: every long operation (render, transcode, export, projection publish) takes an implicit `Task` cancellation and checks `Task.checkCancellation()` between units of work (per paragraph / per chapter / per file).

### 4.5 Error model

One error enum per area, all `Error, Sendable, Equatable`, all with a `userMessage: String` and a stable `code: String` for logging and for the validation report.

```swift
public protocol VoxglassError: Error, Sendable {
    var code: String { get }            // e.g. "PKG.MISSING_ASSET"
    var userMessage: String { get }     // shown in UI, plain language, no jargon
    var isRecoverable: Bool { get }     // if true, UI offers a retry/fix action
    var underlying: (any Error)? { get }
}

public enum PackageError: VoxglassError { case notAPackage(URL), schemaTooNew(Int), missingAsset(AudioAssetReference), corruptManifest, autosaveConflict, diskFull(needBytes: Int64) }
public enum CaptureError: VoxglassError { case noInputDevice, deviceChanged(String), permissionDenied, formatUnsupported(String), engineFailed(String), diskFull }
public enum StoreError: VoxglassError { case migrationFailed(Int, String), constraintViolation(String), notFound(UUID), busy }
public enum TranscodeError: VoxglassError { case encoderUnavailable(String), unsupportedConversion(from: String, to: String), encoderFailed(status: Int32, stderr: String), cancelled }
public enum PackagingError: VoxglassError { case ineligible(DestinationID, reason: String), blockingValidationIssues([ValidationIssue]), proRequired(ProFeature), outputExists(URL), transcode(TranscodeError) }
public enum SyncError: VoxglassError { case notSignedIn, quotaExceeded, staleChangeToken, conflict(recordName: String), network(any Error), zoneMissing }
public enum LicenseError: VoxglassError { case proRequired(ProFeature), purchaseFailed(String), cancelled, pending, unverified }
```

**Error presentation rules.** Never show an error code to the user without a plain-language sentence and, where `isRecoverable`, a button that performs the fix. Codes appear in the copyable diagnostics panel (Settings → Storage → "Copy diagnostics") and in `os.Logger` output.

**`SyncError.staleChangeToken` is special.** Prior work in this repo established that a stale CloudKit change token must be recovered from automatically by discarding the token and refetching — not surfaced as a failure. The production sync engine MUST implement the same recovery (§13.7) and MUST have a regression test for it.

### 4.6 Logging and diagnostics

```swift
import OSLog
enum Log {
    static let capture   = Logger(subsystem: "guru.parso.voxglass.studio", category: "capture")
    static let store     = Logger(subsystem: "guru.parso.voxglass.studio", category: "store")
    static let assembly  = Logger(subsystem: "guru.parso.voxglass.studio", category: "assembly")
    static let sync      = Logger(subsystem: "guru.parso.voxglass.studio", category: "sync")
    static let packaging = Logger(subsystem: "guru.parso.voxglass.studio", category: "packaging")
    static let license   = Logger(subsystem: "guru.parso.voxglass.studio", category: "license")
}
```

- Never log paragraph text, project titles, or file paths containing the user's name at `.info` or above. Use IDs. (Privacy: the user's manuscript is confidential; on a commercial project it may be under NDA.)
- Log every state transition of a recording session, every render cache hit/miss, every sync push/fetch with counts, and every export step with durations.
- Ship a **diagnostics bundle** action: last 500 log lines, project integrity report, schema version, entitlement state, encoder availability, device list. No audio, no text.

### 4.7 File system layout — the `.voxproject` package

```
The Murder of Roger Ackroyd.voxproject/            (NSFileWrapper-style directory, package bit set)
├── manifest.json                 schema version, project id, created/modified, app version
├── project.sqlite                the metadata store (WAL)
├── project.sqlite-wal
├── project.sqlite-shm
├── Audio/
│   ├── Original/                 immutable captured & imported takes; content-addressed
│   │   └── <sha256[0..1]>/<sha256[2..3]>/<sha256>.wav
│   ├── Render/                   assembled chapter renders (cache; safe to delete)
│   │   └── <cacheKey>.caf
│   └── Proxy/                    compressed proxies for device preview (cache; safe to delete)
│       └── <sha256>.m4a
├── Text/
│   ├── source/<sha256>.<ext>     the original imported document, verbatim
│   └── extracted/<sha256>.json   normalized extracted text + source map
├── Artwork/
│   ├── cover-original.<ext>
│   └── cover-2400.jpg
├── Exports/                      export packages (user may move them out)
│   ├── LibriVox/<slug>/
│   ├── InternetArchive/<identifier>/
│   └── Retail/<slug>/
├── Autosave/
│   ├── session.json              crash-recovery marker for in-flight recording
│   └── takes/<uuid>.wav          in-flight capture file(s)
└── Trash/                        soft-deleted assets pending vacuum
```

Rules:

- `Audio/Original` is **append-only**. Nothing in the app may modify or delete a file there except the explicit "Vacuum unused assets" maintenance action, which moves to `Trash/` first.
- `Render/` and `Proxy/` are **derivable caches**. Deleting them must never lose user data; the app must regenerate on demand.
- The package directory carries `com.apple.package` (set `URLResourceValues.isPackage` / an exported UTType) so Finder treats it as one file.
- The package is a **document**, opened via `NSDocument`-style semantics or a light custom controller; either way, the app supports multiple open projects in multiple windows.
- Autosave: an in-flight recording writes directly into `Autosave/takes/<uuid>.wav`; on successful stop the file is hashed and *moved* into `Audio/Original`. If the app dies mid-take, `session.json` names the in-flight file and the target paragraph, and on next open the app offers recovery (§7.7).

### 4.8 UTType / document type registration

Add to `project.yml` for the Studio target:

```yaml
UTExportedTypeDeclarations:
  - UTTypeIdentifier: guru.parso.voxglass.project
    UTTypeDescription: Voxglass Audiobook Project
    UTTypeConformsTo: [com.apple.package]
    UTTypeTagSpecification:
      public.filename-extension: [voxproject]
CFBundleDocumentTypes:
  - CFBundleTypeName: Voxglass Audiobook Project
    LSItemContentTypes: [guru.parso.voxglass.project]
    CFBundleTypeRole: Editor
    LSHandlerRank: Owner
```

### 4.9 macOS entitlements and privacy

```
com.apple.security.app-sandbox                        = true
com.apple.security.device.audio-input                 = true      # microphone
com.apple.security.files.user-selected.read-write     = true      # open/save projects, import
com.apple.security.files.bookmarks.app-scope          = true      # remember open projects
com.apple.security.network.client                     = true      # CloudKit
com.apple.developer.icloud-services                   = [CloudKit]
com.apple.developer.icloud-container-identifiers      = [iCloud.guru.parso.voxglass]
com.apple.security.cs.disable-library-validation      = false     # keep ON; do not weaken
```

`NSMicrophoneUsageDescription`: **"Voxglass records your narration for the audiobook you are producing. Audio stays on your Mac unless you choose to preview it on your devices."**

The transcoder MUST work inside the sandbox. This is why §16.3 prefers **linked LGPL libraries** over spawning a `Process`: a spawned helper needs either an embedded signed helper tool with inherited sandbox or an XPC service, both of which add notarization complexity. If the `Process` path is used anyway, the helper binary must live in `Contents/Helpers/`, be signed with the app's team ID with the hardened runtime, and be invoked with absolute paths only.

### 4.10 CloudKit container design

- **Container:** the existing `iCloud.guru.parso.voxglass` (shared with the consumer app) — a *separate* custom zone keeps production records isolated.
- **Database:** private only. No public/shared database in MVP. (Sharing a project with a proof-listener is DEFERRED.)
- **Zone:** `VGProductionZone`, one per user, created on first publish.
- **Record types:** `VGProductionProject`, `VGProductionChapter`, `VGProductionParagraph`, `VGReviewEvent`. Full schema in §13.2.
- **Asset policy:** paragraph proxy audio is a `CKAsset`. Projections publish **only selected takes**, and only as compressed proxies (AAC mono 80 kbps by default — see mockup `12-device-preview`, "AAC mono · 80 kbps"). Originals never leave the Mac.
- **Quota discipline:** a 10-hour book at 80 kbps mono is roughly 360 MB, which is significant against a user's iCloud quota. The Device Preview screen therefore shows the full-project estimate and offers "Hide Project from Devices" (which deletes the projection). §13.5 defines the eviction policy.

### 4.11 Threading of the audio path (summary)

```
 [mic] → AVAudioInputNode (real-time thread)
             │ tap: copy frames into preallocated RingBuffer (lock-free), update atomic level meters
             ▼
        WriterTask (detached, .userInitiated)
             │ drains ring buffer → AVAudioFile.write (Autosave/takes/<uuid>.wav)
             ▼
        On stop: finalize file → SHA-256 → move to Audio/Original → compute metrics → insert Take row
             ▼
        @MainActor RecordingModel updates state; RecordingMeter (separate @Observable) is driven at
        display rate from the atomic meter values via a CADisplayLink-equivalent timer.
```

The separation of `RecordingMeter` from `RecordingModel` is not cosmetic: it is the fix for the app-wide invalidation storm previously encountered in this codebase's player, and it is asserted by a render-count probe test (§19.8).

---

## 5. Domain model — complete source

All types live in `Voxglass/Core/Production/Domain/`. Everything is `public`, `Sendable`, and `Codable` unless noted. This section is normative source, not pseudo-code: an implementer should be able to paste and compile it after adding imports.

### 5.1 Identity and primitives

```swift
import Foundation

/// Deterministic clock seam. Never call `Date()` directly in Core/Production.
public protocol Clock: Sendable { var now: Date { get } }
public struct SystemClock: Clock { public init() {} ; public var now: Date { Date() } }

/// Deterministic ID seam. Never call `UUID()` directly in Core/Production.
public protocol IDGenerator: Sendable { func next() -> UUID }
public struct UUIDGenerator: IDGenerator { public init() {} ; public func next() -> UUID { UUID() } }

/// Content address of any immutable blob in the package.
public struct AudioAssetReference: Codable, Sendable, Hashable {
    public let sha256: String        // lowercase hex, 64 chars
    public let relativePath: String  // e.g. "Audio/Original/ab/cd/abcd….wav"
    public let byteCount: Int
    public let contentType: String   // UTI-ish: "public.wav", "public.mp3", "public.json"
    public init(sha256: String, relativePath: String, byteCount: Int, contentType: String)
}

public enum SHA256Hex {
    /// CryptoKit SHA-256, lowercase hex. MUST be used for every content address and cache key.
    /// Swift.Hasher is FORBIDDEN for persistence — it reseeds per process launch.
    public static func hex(_ data: Data) -> String
    public static func hex(contentsOf url: URL) throws -> String   // streaming, 1 MiB chunks
    public static func hex(joining parts: [String]) -> String      // for composite cache keys
}
```

### 5.2 Project

```swift
public struct AudiobookProject: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var metadata: BookMetadata
    public var rights: RightsEvidence
    public var profile: ProductionProfile
    public var source: SourceDocument?
    public var chapters: [Chapter]            // ordinal-ordered; ordinals are contiguous from 0
    public var pronunciations: [PronunciationNote]
    public var createdAt: Date
    public var modifiedAt: Date
    public var schemaVersion: Int

    // Derived, never stored:
    public var allParagraphs: [Paragraph] { chapters.flatMap(\.paragraphs) }
    public var recordedCount: Int { allParagraphs.count { $0.selectedTakeID != nil } }
    public var totalCount: Int { allParagraphs.count }
    public var percentRecorded: Double { totalCount == 0 ? 0 : Double(recordedCount) / Double(totalCount) }
}

public struct BookMetadata: Codable, Sendable, Equatable {
    public var title: String
    public var subtitle: String?
    public var author: String
    public var translator: String?
    public var narrator: String
    public var language: String              // BCP-47, e.g. "en-US"
    public var description: String
    public var subjects: [String]
    public var seriesName: String?
    public var seriesIndex: Int?
    public var publisher: String?            // commercial
    public var copyrightYear: Int?
    public var productionYear: Int?
    public var rightsHolder: String?
    public var isbn: String?                 // commercial, optional
    public var asin: String?                 // commercial, optional
    public var isAbridged: Bool
    public var coverRef: AudioAssetReference?
    public var archiveIdentifier: String?    // Internet Archive suggested/confirmed identifier
}

public enum ProjectPurpose: String, Codable, Sendable, CaseIterable {
    case publicDomainCommunity   // "Public-domain community production"  (mockup 02)
    case personal                // "Personal listening"
    case commercial              // "Commercial / copyrighted (Pro)"
}

public struct ProductionProfile: Codable, Sendable, Equatable {
    public var purpose: ProjectPurpose
    public var recording: RecordingDefaults
    public var assembly: AssemblySettings
    public var intendedDestination: DestinationID
    public var isHiddenFromDevices: Bool     // Device Preview → "Hide Project from Devices"
    public var autoSyncAcceptedTakes: Bool
    public var includeSourceTextInProjection: Bool
    public var proxyBitrateKbps: Int         // default 80
}

public struct RecordingDefaults: Codable, Sendable, Equatable {
    public var sampleRate: Double = 48_000
    public var bitDepth: Int = 24
    public var channels: Int = 1
    public var preRollSeconds: TimeInterval = 1.0
    public var warnOnClipping: Bool = true
    public var autoComputeMetrics: Bool = true
    public var inputDeviceUID: String?
    public var monitoringDeviceUID: String?
    public var monitoringEnabled: Bool = false
}
```

### 5.3 Chapter and paragraph

> **Amended (S5 audit):** the Core implementation names this type `ProductionChapter`, not `Chapter`. This is deliberate — the Studio production domain is compiled into the same module namespace as the consumer app's existing `Chapter` type, so the production type carries the `Production` prefix to avoid a collision. §5.3's `Chapter` below is the production domain type regardless of name.

```swift
public struct Chapter: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var ordinal: Int                  // 0-based, contiguous, unique within project
    public var title: String
    public var role: ChapterRole
    public var paragraphs: [Paragraph]       // ordinal-ordered, contiguous from 0
    public var headSilenceOverride: TimeInterval?
    public var tailSilenceOverride: TimeInterval?
    public var notes: String?
}

public enum ChapterRole: String, Codable, Sendable {
    case body                  // ordinary chapter
    case frontMatter           // "Front Matter" (mockup 03)
    case backMatter
    case openingCredits        // synthetic, retail
    case closingCredits        // synthetic, retail
}

public struct Paragraph: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID                      // STABLE across re-import (§9.4)
    public var ordinal: Int
    public var text: String
    public var textHash: String              // SHA-256 of normalized text (§9.3)
    public var role: ParagraphRole
    public var directionNote: String?        // "Read more quietly."
    public var pronunciationRefs: [UUID]     // → PronunciationNote.id
    public var takes: [Take]
    public var selectedTakeID: UUID?
    public var reviewState: ReviewState
    public var sourceRange: SourceRange?     // offsets into extracted source text
    public var isSceneBreak: Bool            // ornamental break marker (mockup 03)
    public var updatedAt: Date
}

public enum ParagraphRole: String, Codable, Sendable {
    case body
    case chapterHeading            // "Chapter 2 · Who's Who in King's Abbot"
    case libriVoxIntro             // generated disclaimer text (§3.2.3)
    case libriVoxOutro
    case retailOpeningCredits      // §3.4.2
    case retailClosingCredits
}

public struct SourceRange: Codable, Sendable, Equatable {
    public var startOffset: Int; public var endOffset: Int; public var sourceFileHash: String
}

public struct PronunciationNote: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var term: String
    public var guidance: String              // free text; never IPA-validated
}
```

**Invariants (enforced by `ProjectIntegrity`, §5.10):**

- `chapters` ordinals are `0..<chapters.count`, unique.
- Within each chapter, paragraph ordinals are `0..<paragraphs.count`, unique.
- `selectedTakeID`, if non-nil, identifies a take present in `takes`.
- `textHash == SHA256Hex.hex(normalize(text))`.
- Paragraph IDs are unique **project-wide**, not just per chapter.
- `role == .openingCredits` chapter, if present, has `ordinal == 0`; `.closingCredits` has the maximum ordinal.

### 5.4 Take

```swift
public struct Take: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var paragraphID: UUID
    public var assetRef: AudioAssetReference       // immutable original
    public var origin: AudioOrigin
    public var recordedAt: Date
    public var duration: TimeInterval
    public var format: AudioFormatDescription
    public var processing: [AudioProcessingStep]   // NON-DESTRUCTIVE instructions
    public var metrics: AudioQualityMetrics?       // nil until computed
    public var label: String?                      // "Take 1", "Imported A"
    public var textHashAtRecording: String         // drift detection (§9.5)
    public var isArchived: Bool                    // hidden from the takes list, not deleted
}

public enum AudioOrigin: Sendable, Equatable, Hashable {
    case recorded                              // captured in Voxglass Studio
    case importedHuman(sourceFilename: String) // external human recording
    case aiImported(providerLabel: String)     // AI-generated / AI-processed — PROVENANCE ONLY
    case unknownImport(sourceFilename: String) // user declined to declare; treated as AI for eligibility

    public var isHumanNarration: Bool {
        switch self { case .recorded, .importedHuman: return true
                      case .aiImported, .unknownImport: return false }
    }
}

public struct AudioFormatDescription: Codable, Sendable, Equatable {
    public var sampleRate: Double; public var channels: Int; public var bitDepth: Int?
    public var codec: String            // "pcm_s24le", "mp3", "aac", "flac"
}

public struct AudioProcessingStep: Codable, Sendable, Equatable {
    public var kind: ProcessingKind
    public var parameters: [String: Double]
}
public enum ProcessingKind: String, Codable, Sendable {
    case trimStart, trimEnd, gainDB, fadeInSeconds, fadeOutSeconds
}

public struct AudioQualityMetrics: Codable, Sendable, Equatable {
    public var peakDBFS: Double
    public var truePeakDBFS: Double         // 4× oversampled estimate
    public var rmsDBFS: Double              // whole-file RMS excluding leading/trailing silence
    public var noiseFloorDBFS: Double       // RMS of detected silent windows (§11.6.4)
    public var replayGainDB: Double         // for the LibriVox perceived-loudness band
    public var clipCount: Int
    public var dcOffset: Double
    public var leadingSilence: TimeInterval
    public var trailingSilence: TimeInterval
    public var duration: TimeInterval
    public var sampleRate: Double
    public var channels: Int
    public var computedAt: Date
    public var analyzerVersion: Int         // bump to invalidate stored metrics on algorithm change
}
```

**`AudioOrigin` Codable.** Associated values mean the synthesized `Codable` produces a nested shape that is painful in SQLite and CloudKit. Provide an explicit discriminator encoding:

```swift
extension AudioOrigin: Codable {
    private enum CodingKeys: String, CodingKey { case kind, payload }
    private enum Kind: String, Codable { case recorded, importedHuman, aiImported, unknownImport }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .recorded:      self = .recorded
        case .importedHuman: self = .importedHuman(sourceFilename: try c.decode(String.self, forKey: .payload))
        case .aiImported:    self = .aiImported(providerLabel:  try c.decode(String.self, forKey: .payload))
        case .unknownImport: self = .unknownImport(sourceFilename: try c.decode(String.self, forKey: .payload))
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .recorded:                       try c.encode(Kind.recorded, forKey: .kind)
        case .importedHuman(let f):           try c.encode(Kind.importedHuman, forKey: .kind); try c.encode(f, forKey: .payload)
        case .aiImported(let p):              try c.encode(Kind.aiImported, forKey: .kind);    try c.encode(p, forKey: .payload)
        case .unknownImport(let f):           try c.encode(Kind.unknownImport, forKey: .kind); try c.encode(f, forKey: .payload)
        }
    }
    /// Flat SQLite/CloudKit representation: two columns.
    public var storageKind: String { … }
    public var storagePayload: String? { … }
    public init(storageKind: String, storagePayload: String?) throws { … }
}
```

`DomainCodingTests` MUST round-trip every case through JSON **and** through the flat storage pair.

### 5.5 Review state

```swift
public enum ReviewState: String, Codable, Sendable, CaseIterable {
    case unreviewed        // default
    case flagged           // ⚑ something is wrong, details in notes
    case needsPickup       // ↻ must be re-recorded — BLOCKING for export
    case approved          // ✓ done
}

public struct ReviewNote: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var paragraphID: UUID
    public var text: String
    public var tag: ReviewTag?
    public var device: DeviceKind
    public var timecode: TimeInterval?     // offset into the paragraph, e.g. 00:03.4
    public var createdAt: Date
    public var resolvedAt: Date?
}

public enum ReviewTag: String, Codable, Sendable, CaseIterable {
    case misread, pronunciation, pacing, noise, performance, edit
}

public enum DeviceKind: String, Codable, Sendable { case mac, iPhone, watch, carPlay }
```

The six tags are exactly the categories in the mockups (`06-review-note-sheet`, `07-dictation-category`). Do not add a seventh without updating both mockups and the CarPlay/watch pickers, which are grid-laid-out for six.

### 5.6 Narration origin and eligibility

```swift
public enum NarrationOrigin: String, Codable, Sendable { case humanOnly, containsImportedAI }

/// The one domain rule that cannot be constructed by accident.
public struct EligibilityProfile: Sendable, Equatable, Codable {
    public let narrationOrigin: NarrationOrigin
    public let librivoxEligible: Bool
    public let aiParagraphIDs: [UUID]          // for the Narration Origin Audit UI
    public let humanParagraphCount: Int
    public let aiParagraphCount: Int

    private init(origin: NarrationOrigin, aiIDs: [UUID], human: Int, ai: Int) {
        self.narrationOrigin = origin
        self.librivoxEligible = (origin == .humanOnly)
        self.aiParagraphIDs = aiIDs
        self.humanParagraphCount = human
        self.aiParagraphCount = ai
    }

    /// The ONLY way to build one: derived from the project's *selected* takes.
    public static func evaluate(_ project: AudiobookProject) -> EligibilityProfile {
        var aiIDs: [UUID] = []; var human = 0; var ai = 0
        for p in project.allParagraphs {
            guard let sel = p.selectedTakeID, let take = p.takes.first(where: { $0.id == sel }) else { continue }
            if take.origin.isHumanNarration { human += 1 } else { ai += 1; aiIDs.append(p.id) }
        }
        return EligibilityProfile(origin: ai > 0 ? .containsImportedAI : .humanOnly,
                                  aiIDs: aiIDs, human: human, ai: ai)
    }
}
```

**Why the private initializer matters.** Without it, a future contributor writes `EligibilityProfile(narrationOrigin: .humanOnly, librivoxEligible: true)` in a view model to "fix" a UI bug, and the app starts producing LibriVox packages from AI audio. The initializer being private, plus grep gate G-6 requiring `EligibilityProfile.evaluate` inside `LibriVoxPackageBuilder`, makes that mistake mechanically impossible.

### 5.7 Rights

```swift
public struct RightsEvidence: Codable, Sendable, Equatable {
    public var basis: RightsBasis
    public var sourceURL: URL?              // authorized source edition
    public var editionYear: Int?
    public var evidenceNotes: String        // free text, e.g. Gutenberg status page
    public var attestedAt: Date?            // nil = not attested
    public var attestedBy: String?          // free text name the user typed
    public var licenseURL: URL?             // for IA licenseurl field
    public var isAttested: Bool { attestedAt != nil }
}

public enum RightsBasis: String, Codable, Sendable, CaseIterable {
    case publicDomainUS      = "Public domain in the United States"
    case ownCopyright        = "I own the copyright"
    case productionLicense   = "I have a production license"
    case personalUseOnly     = "Personal use only"
}
```

The raw values are the exact strings from mockup `02-new-project`; keep them as raw values so the UI never diverges from the stored value.

### 5.8 Source document

```swift
public struct SourceDocument: Codable, Sendable, Equatable {
    public var format: SourceFormat
    public var originalFilename: String
    public var originalRef: AudioAssetReference        // the file as imported, verbatim
    public var extractedTextRef: AudioAssetReference   // normalized text + structure JSON
    public var sourceMapRef: AudioAssetReference?      // paragraph → source offsets
    public var textHash: String                        // hash of the extracted text (mockup 03: "Text hash 6f4d…ab91")
    public var importedAt: Date
    public var detectedSectionCount: Int
    public var importWarnings: [ImportWarning]
}

public enum SourceFormat: String, Codable, Sendable { case epub, txt, markdown, docx, manual }

public struct ImportWarning: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var kind: ImportWarningKind
    public var message: String
    public var paragraphIndex: Int?
}
public enum ImportWarningKind: String, Codable, Sendable {
    case possibleSceneBreak      // "Three asterisks may indicate a scene break"
    case veryLongParagraph
    case veryShortParagraph
    case unrecognizedHeading
    case emptySection
    case encodingFallback
    case imageOnlyContent
}
```

### 5.9 Destination profiles (types)

```swift
public enum DestinationID: String, Codable, Sendable, CaseIterable {
    case librivox, internetArchive, acx, appleBooksAggregator, personalMaster
}

public struct DestinationProfile: Sendable, Equatable {
    public let id: DestinationID
    public let displayName: String
    public let tier: Tier                              // .free | .pro
    public let audio: AudioSpec
    public let secondaryAudio: AudioSpec?
    public let fileGranularity: FileGranularity
    public let maxFileDuration: TimeInterval?
    public let filenameRule: FilenameRule
    public let requiredMetadata: Set<MetadataField>
    public let requiresHumanNarration: Bool
    public let requiresScriptedDisclaimer: Bool
    public let requiresCredits: Bool
    public let loudness: LoudnessRule?
    public let peakCeilingDBFS: Double?
    public let noiseFloorCeilingDBFS: Double?
    public let headroomSilence: SilenceRule?
    public let retailSample: RetailSampleRule?
    public let artwork: ArtworkRule
    public let emitsChecksums: Bool
    public let autoUpload: Bool                        // ALWAYS false — see C-7
}

public enum Tier: String, Sendable { case free, pro }
public enum FileGranularity: String, Sendable { case perChapter, wholeBookChapterized, perParagraph }
public enum Container: String, Sendable { case mp3, wav, flac, m4a, m4b, caf }
public enum Codec: String, Sendable { case mp3, pcm, flac, aacLC, alac }

public struct AudioSpec: Sendable, Equatable {
    public let container: Container
    public let codec: Codec
    public let sampleRate: Double?      // nil = preserve source
    public let channels: Int?           // nil = preserve
    public let bitrateKbps: Int?
    public let isCBR: Bool
    public let bitDepth: Int?
}

public enum LoudnessRule: Sendable, Equatable {
    case rmsWindow(minDBFS: Double, maxDBFS: Double, targetDBFS: Double)
    case replayGainBand(low: Double, high: Double, target: Double)
}
public struct SilenceRule: Sendable, Equatable { public let headMin, headMax, tailMin, tailMax: TimeInterval }
public struct RetailSampleRule: Sendable, Equatable { public let minDuration, maxDuration: TimeInterval; public let mustStartWithNarration: Bool }
public enum ArtworkRule: Sendable, Equatable { case none, optionalSquare(minPx: Int), requiredSquare(minPx: Int, colorSpace: ColorSpaceRule, format: ImageFormat) }
public enum ColorSpaceRule: String, Sendable { case rgb }
public enum ImageFormat: String, Sendable { case jpeg, png }

public enum MetadataField: String, Sendable, CaseIterable {
    case title, subtitle, author, narrator, language, description, subjects,
         sourceURL, rightsBasis, rightsAttestation, cover, publisher,
         copyrightYear, productionYear, identifier, licenseURL, date, isbn
}

public enum FilenameRule: String, Sendable {
    case librivoxLowercaseNoSpace       // §3.2.4
    case archiveIdentifierPrefixed      // <identifier>_NN_<slug>.<ext>
    case freeformNumbered               // NN - Chapter Title.<ext>
}
```

### 5.10 Integrity

```swift
public struct IntegrityFinding: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let severity: Severity            // .blocking | .warning | .passed
    public let code: IntegrityCode
    public let message: String
    public let chapterID: UUID?
    public let paragraphID: UUID?
    public let repair: RepairAction?
}

public enum IntegrityCode: String, Sendable {
    case duplicateChapterOrdinal, missingChapterOrdinal
    case duplicateParagraphOrdinal, missingParagraphOrdinal
    case duplicateParagraphID
    case selectedTakeMissing
    case takeAssetMissing
    case takeAssetHashMismatch
    case orphanAsset
    case textHashMismatch
    case creditsChapterMisplaced
    case autosaveOrphan
}

public enum RepairAction: Sendable, Equatable {
    case renumberOrdinals
    case clearSelectedTake(paragraphID: UUID)
    case removeTake(takeID: UUID)
    case moveAssetToTrash(AudioAssetReference)
    case recomputeTextHash(paragraphID: UUID)
    case recoverAutosave(URL)
}

public enum ProjectIntegrity {
    public static func check(_ project: AudiobookProject,
                             assets: any ContentAddressedStore,
                             deep: Bool) -> [IntegrityFinding]
    // deep == true re-hashes every asset file (slow; used by "Verify Project" and before export)
}
```

`ProjectIntegrity.check` is called: on package open (shallow), before any export (deep, for the assets that will be used), and from Settings → Storage → "Verify Project" (deep, all).
---

## 6. The `.voxproject` package and the content-addressed asset store

### 6.1 Why content addressing

Every immutable blob — captured take, imported audio, source document, extracted text, artwork, render — is stored under the lowercase hex SHA-256 of its bytes. This buys four properties the product depends on:

1. **Deduplication.** Importing the same WAV twice costs one file. Re-recording an identical silence does not.
2. **Verification.** `deep` integrity checking is just "re-hash and compare."
3. **Stable cache keys across launches.** The render cache and proxy cache key off content hashes; `Swift.Hasher` reseeds per process and would silently invalidate every cache on every launch (a defect class already hit in this codebase — hence CI gate G-4).
4. **Safe moves.** Copying or moving a `.voxproject` never breaks references, because references are relative paths derived from the hash.

### 6.2 `ContentAddressedStore`

```swift
public protocol ContentAddressedStore: Sendable {
    /// Writes `data` and returns its reference. Idempotent: writing identical bytes twice
    /// returns the same reference and performs no second write.
    func put(_ data: Data, ext: String, contentType: String, subdirectory: AssetSubdirectory) async throws -> AudioAssetReference
    /// Ingests a file already on disk by MOVING it (not copying) when `moving` is true.
    func ingest(fileAt url: URL, ext: String, contentType: String, subdirectory: AssetSubdirectory, moving: Bool) async throws -> AudioAssetReference
    func url(for ref: AudioAssetReference) -> URL
    func exists(_ ref: AudioAssetReference) -> Bool
    func data(for ref: AudioAssetReference) async throws -> Data
    /// Moves to Trash/ (soft delete). Never hard-deletes.
    func trash(_ ref: AudioAssetReference) async throws
    func allReferences(under subdirectory: AssetSubdirectory) async throws -> [AudioAssetReference]
    func totalBytes(under subdirectory: AssetSubdirectory) async throws -> Int64
}

public enum AssetSubdirectory: String, Sendable, CaseIterable {
    case original = "Audio/Original"
    case render   = "Audio/Render"
    case proxy    = "Audio/Proxy"
    case source   = "Text/source"
    case extracted = "Text/extracted"
    case text     = "Text"
    case artwork  = "Artwork"
}
```

`FileAssetStore` is an `actor` (write serialization) implementing this over the package root:

```swift
public actor FileAssetStore: ContentAddressedStore {
    public let root: URL
    private let fm = FileManager.default

    /// Fan-out path: Audio/Original/ab/cd/abcd…ef.wav — two 2-char levels keeps any one
    /// directory under a few thousand entries for a 10 000-paragraph project.
    private func relativePath(sha: String, subdirectory: AssetSubdirectory, ext: String) -> String {
        let a = String(sha.prefix(2)), b = String(sha.dropFirst(2).prefix(2))
        return "\(subdirectory.rawValue)/\(a)/\(b)/\(sha).\(ext)"
    }
}
```

Implementation requirements:

- `ingest(fileAt:moving:)` MUST hash by streaming (`SHA256Hex.hex(contentsOf:)`, 1 MiB chunks) so a 2-hour 24-bit WAV never loads into memory.
- Writes go to a temporary file in the same volume and are then `replaceItemAt`-ed / `moveItem`-ed into place — never a partial file at the final path.
- If the destination already exists with the same hash, `ingest(moving: true)` deletes the source and returns the existing reference.
- `put` sets `URLResourceValues.isExcludedFromBackup = false` (the project *should* be backed up by Time Machine) but sets it **true** for `Audio/Render` and `Audio/Proxy` (derivable caches).
- Disk-full: catch `NSFileWriteOutOfSpaceError` and rethrow as `PackageError.diskFull(needBytes:)` so the UI can show a specific message and a "Reveal in Finder" action.

### 6.3 Manifest

```swift
public struct PackageManifest: Codable, Sendable, Equatable {
    public var schemaVersion: Int          // matches the DB schema version
    public var packageFormatVersion: Int   // directory layout version; 1 for MVP
    public var projectID: UUID
    public var title: String               // denormalized for Finder/Quick Look and fast library listing
    public var author: String
    public var narrator: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var appVersion: String          // "1.2 (57)"
    public var lastOpenedByDeviceName: String?
}
```

`manifest.json` is written atomically on every save and is the **only** file the library screen reads when listing projects. Listing 200 projects must not open 200 SQLite databases. (Performance budget: library first render < 500 ms — §19.7.)

### 6.4 `ProjectPackage`

```swift
public struct ProjectPackage: Sendable, Equatable {
    public let root: URL
    public var manifestURL: URL { root.appendingPathComponent("manifest.json") }
    public var databaseURL: URL { root.appendingPathComponent("project.sqlite") }

    public static func create(title: String, author: String, narrator: String,
                              at directory: URL, clock: any Clock, ids: any IDGenerator) throws -> ProjectPackage
    public static func open(_ url: URL) throws -> ProjectPackage
    public static func readManifest(_ url: URL) throws -> PackageManifest    // cheap; for the library list
    public func move(to url: URL) throws
    public func copy(to url: URL) throws
    public func setPackageFlag() throws          // isPackage = true
}
```

`create` performs, in order: create directory tree (all of §4.7), write `manifest.json`, create `project.sqlite` and run migrations to current, set the package flag, `fsync` the directory. If any step throws, the partially created directory is removed.

`open` performs: read manifest → if `manifest.packageFormatVersion > current` throw `PackageError.schemaTooNew` → open DB and migrate → shallow `ProjectIntegrity.check` → check for `Autosave/session.json` and surface recovery (§8.4).

`copy(to:)` MUST exclude `Audio/Render`, `Audio/Proxy`, `Exports`, and `Trash` — a project copy is the source material, not the derived output. `move(to:)` moves everything.

### 6.5 Storage accounting

The Device Preview and Settings → Storage screens show real numbers (mockup `12-device-preview`: "Full project estimate: 412 MB", "On-demand cache: 18 MB"). Implement:

```swift
public struct StorageReport: Sendable {
    public var originalBytes: Int64
    public var renderBytes: Int64
    public var proxyBytes: Int64
    public var textBytes: Int64
    public var artworkBytes: Int64
    public var exportBytes: Int64
    public var trashBytes: Int64
    public var orphanBytes: Int64            // assets referenced by nothing
    public var estimatedProjectionBytes: Int64   // proxy bitrate × total recorded duration
}
public struct StorageAnalyzer { public func report(package: ProjectPackage, project: AudiobookProject) async throws -> StorageReport }
```

Maintenance actions: **Rebuild caches** (delete Render+Proxy), **Vacuum unused assets** (move orphans to Trash, then empty Trash on confirm), **Verify project** (deep integrity).

---

## 7. Persistence

### 7.1 Why not GRDB (decision C-1 in full)

The source plan proposed GRDB "to match the existing stack." The existing stack is a hand-rolled `actor AppDatabase` over the system `SQLite3` C API, with `DatabaseValue` for binding and an integer-numbered append-only migration list. Adopting GRDB would mean:

- adding the project's **first** third-party Swift dependency, into a GPLv3 app that is distributed through the App Store under a hand-written additional permission — every added dependency is a license question;
- running two persistence idioms in one binary (the consumer library DB stays hand-rolled), doubling the mental model;
- no material benefit for this workload, which is a few dozen simple tables with straightforward queries and one hot path (paragraph listing).

**Decision: extend the existing pattern.** Add `ProjectDatabase`, an actor with the same shape as `AppDatabase`, scoped to one `.voxproject`, with its own migration list.

If a later phase needs GRDB's observation or associations, that is a separate, isolated migration — the `ProductionStore` protocol makes it a drop-in replacement.

### 7.2 `ProjectDatabase`

```swift
public actor ProjectDatabase {
    private let url: URL
    private var handle: OpaquePointer?
    private var didMigrate = false

    public init(url: URL)
    public func prepare() throws                                   // open + PRAGMAs + migrate
    public func execute(_ sql: String, _ bindings: [DatabaseValue]) throws
    public func query(_ sql: String, _ bindings: [DatabaseValue]) throws -> [DatabaseRow]
    public func transaction<T>(_ body: (ProjectDatabase) throws -> T) throws -> T   // BEGIN IMMEDIATE
    public func vacuum() throws
    public func checkpoint() throws                                 // wal_checkpoint(TRUNCATE)
}
```

PRAGMAs applied at open, in this order:

```sql
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;      -- WAL + NORMAL is durable enough and much faster for take inserts
PRAGMA foreign_keys = ON;
PRAGMA busy_timeout = 5000;
PRAGMA temp_store = MEMORY;
PRAGMA cache_size = -20000;        -- ~20 MB page cache; a 10 000-¶ project's hot set fits
```

`checkpoint()` is called on window close and on app deactivation so a copied/moved package is never missing its WAL content.

### 7.3 Schema (migration 1)

Written in the existing `DatabaseMigration` style. `ProductionMigration.all` is a separate list from the consumer `DatabaseMigration.all` because it lives in a different database file.

```sql
-- 001_initial_production_schema
CREATE TABLE project (
    id                  TEXT PRIMARY KEY NOT NULL,
    title               TEXT NOT NULL,
    subtitle            TEXT,
    author              TEXT NOT NULL,
    translator          TEXT,
    narrator            TEXT NOT NULL,
    language            TEXT NOT NULL DEFAULT 'en-US',
    description         TEXT NOT NULL DEFAULT '',
    subjects_json       TEXT NOT NULL DEFAULT '[]',
    series_name         TEXT,
    series_index        INTEGER,
    publisher           TEXT,
    copyright_year      INTEGER,
    production_year     INTEGER,
    rights_holder       TEXT,
    isbn                TEXT,
    asin                TEXT,
    is_abridged         INTEGER NOT NULL DEFAULT 0,
    cover_sha256        TEXT,
    archive_identifier  TEXT,
    purpose             TEXT NOT NULL,
    intended_destination TEXT NOT NULL,
    rights_basis        TEXT NOT NULL,
    rights_source_url   TEXT,
    rights_edition_year INTEGER,
    rights_notes        TEXT NOT NULL DEFAULT '',
    rights_attested_at  REAL,
    rights_attested_by  TEXT,
    rights_license_url  TEXT,
    recording_json      TEXT NOT NULL,      -- RecordingDefaults
    assembly_json       TEXT NOT NULL,      -- AssemblySettings
    hidden_from_devices INTEGER NOT NULL DEFAULT 0,
    auto_sync_takes     INTEGER NOT NULL DEFAULT 1,
    include_source_text INTEGER NOT NULL DEFAULT 1,
    proxy_bitrate_kbps  INTEGER NOT NULL DEFAULT 80,
    source_json         TEXT,               -- SourceDocument
    created_at          REAL NOT NULL,
    modified_at         REAL NOT NULL,
    schema_version      INTEGER NOT NULL,
    projection_revision INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE chapter (
    id            TEXT PRIMARY KEY NOT NULL,
    project_id    TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
    ordinal       INTEGER NOT NULL,
    title         TEXT NOT NULL,
    role          TEXT NOT NULL DEFAULT 'body',
    head_silence  REAL,
    tail_silence  REAL,
    notes         TEXT,
    UNIQUE(project_id, ordinal)
);

CREATE TABLE paragraph (
    id                TEXT PRIMARY KEY NOT NULL,
    chapter_id        TEXT NOT NULL REFERENCES chapter(id) ON DELETE CASCADE,
    project_id        TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
    ordinal           INTEGER NOT NULL,
    text              TEXT NOT NULL,
    text_hash         TEXT NOT NULL,
    role              TEXT NOT NULL DEFAULT 'body',
    direction_note    TEXT,
    selected_take_id  TEXT,
    review_state      TEXT NOT NULL DEFAULT 'unreviewed',
    source_start      INTEGER,
    source_end        INTEGER,
    source_file_hash  TEXT,
    is_scene_break    INTEGER NOT NULL DEFAULT 0,
    updated_at        REAL NOT NULL,
    UNIQUE(chapter_id, ordinal)
);
CREATE INDEX idx_paragraph_project_state ON paragraph(project_id, review_state);
CREATE INDEX idx_paragraph_chapter_ordinal ON paragraph(chapter_id, ordinal);
CREATE INDEX idx_paragraph_selected ON paragraph(project_id, selected_take_id);

CREATE TABLE take (
    id                    TEXT PRIMARY KEY NOT NULL,
    paragraph_id          TEXT NOT NULL REFERENCES paragraph(id) ON DELETE CASCADE,
    project_id            TEXT NOT NULL,
    asset_sha256          TEXT NOT NULL,
    asset_path            TEXT NOT NULL,
    asset_bytes           INTEGER NOT NULL,
    asset_content_type    TEXT NOT NULL,
    origin_kind           TEXT NOT NULL,     -- recorded | importedHuman | aiImported | unknownImport
    origin_payload        TEXT,
    recorded_at           REAL NOT NULL,
    duration              REAL NOT NULL,
    sample_rate           REAL NOT NULL,
    channels              INTEGER NOT NULL,
    bit_depth             INTEGER,
    codec                 TEXT NOT NULL,
    processing_json       TEXT NOT NULL DEFAULT '[]',
    metrics_json          TEXT,
    label                 TEXT,
    text_hash_at_recording TEXT NOT NULL,
    is_archived           INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_take_paragraph ON take(paragraph_id);
CREATE INDEX idx_take_origin ON take(project_id, origin_kind);

CREATE TABLE pronunciation (
    id         TEXT PRIMARY KEY NOT NULL,
    project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
    term       TEXT NOT NULL,
    guidance   TEXT NOT NULL
);
CREATE TABLE paragraph_pronunciation (
    paragraph_id     TEXT NOT NULL REFERENCES paragraph(id) ON DELETE CASCADE,
    pronunciation_id TEXT NOT NULL REFERENCES pronunciation(id) ON DELETE CASCADE,
    PRIMARY KEY (paragraph_id, pronunciation_id)
);

CREATE TABLE review_note (
    id           TEXT PRIMARY KEY NOT NULL,
    project_id   TEXT NOT NULL,
    paragraph_id TEXT NOT NULL REFERENCES paragraph(id) ON DELETE CASCADE,
    text         TEXT NOT NULL,
    tag          TEXT,
    device       TEXT NOT NULL,
    timecode     REAL,
    created_at   REAL NOT NULL,
    resolved_at  REAL
);
CREATE INDEX idx_note_paragraph ON review_note(paragraph_id);

-- Append-only event log. NEVER updated, only inserted; folding derives paragraph.review_state.
CREATE TABLE review_event (
    id           TEXT PRIMARY KEY NOT NULL,     -- idempotency key
    project_id   TEXT NOT NULL,
    paragraph_id TEXT NOT NULL,
    type         TEXT NOT NULL,
    note_text    TEXT,
    tag          TEXT,
    device       TEXT NOT NULL,
    created_at   REAL NOT NULL,
    applied_at   REAL,                          -- when folded into paragraph.review_state
    origin       TEXT NOT NULL DEFAULT 'local'  -- local | cloud
);
CREATE INDEX idx_event_unapplied ON review_event(project_id, applied_at);
CREATE INDEX idx_event_paragraph_time ON review_event(paragraph_id, created_at);

CREATE TABLE render_cache (
    cache_key   TEXT PRIMARY KEY NOT NULL,
    chapter_id  TEXT NOT NULL,
    asset_sha256 TEXT NOT NULL,
    asset_path  TEXT NOT NULL,
    asset_bytes INTEGER NOT NULL,
    duration    REAL NOT NULL,
    created_at  REAL NOT NULL
);

CREATE TABLE proxy_cache (
    take_id      TEXT PRIMARY KEY NOT NULL,
    asset_sha256 TEXT NOT NULL,
    asset_path   TEXT NOT NULL,
    asset_bytes  INTEGER NOT NULL,
    bitrate_kbps INTEGER NOT NULL,
    created_at   REAL NOT NULL
);

CREATE TABLE sync_state (
    key   TEXT PRIMARY KEY NOT NULL,   -- 'changeToken', 'lastPublishedRevision', 'zoneCreated'
    value TEXT
);

CREATE TABLE export_run (
    id             TEXT PRIMARY KEY NOT NULL,
    project_id     TEXT NOT NULL,
    destination    TEXT NOT NULL,
    started_at     REAL NOT NULL,
    finished_at    REAL,
    output_path    TEXT,
    status         TEXT NOT NULL,      -- running | succeeded | failed | cancelled
    error_code     TEXT,
    file_count     INTEGER,
    total_bytes    INTEGER,
    report_json    TEXT                -- ValidationReport snapshot at export time
);
```

**Notes for the implementer.**

- Times are `REAL` Unix epoch seconds, matching the existing `AppDatabase` convention.
- Booleans are `INTEGER 0/1`.
- Structured leaf values (`processing_json`, `metrics_json`, `subjects_json`, `recording_json`, `assembly_json`, `source_json`) are JSON columns because they are read/written whole and never queried by field. Anything that is filtered or sorted gets a real column.
- `paragraph.review_state` is a **derived cache** of the event fold. It is written only by the folder (§14.3). Direct writes from UI code are forbidden; the UI emits an event and the folder updates state.
- There is no `FOREIGN KEY` from `paragraph.selected_take_id` to `take.id` on purpose: take deletion order during import/undo would fight it. `ProjectIntegrity` covers it instead (`selectedTakeMissing`).

### 7.4 Migration discipline

```swift
public struct ProductionMigration: Sendable {
    public let id: Int
    public let name: String
    public let statements: [String]
    public static let all: [ProductionMigration] = [ .init(id: 1, name: "initial_production_schema", statements: [...]) ]
}
```

Rules:

1. Migrations are **append-only and immutable** once merged. Never edit a shipped migration.
2. Every migration runs in `BEGIN IMMEDIATE` … `COMMIT` with rollback on error (existing pattern).
3. Adding a column: `ALTER TABLE … ADD COLUMN … DEFAULT …`. Never `NOT NULL` without a default.
4. Any migration that transforms data MUST have a test that builds the *old* schema from a captured DDL snapshot, inserts fixture rows, runs the migrator, and asserts the new shape. Snapshots live in `VoxglassCoreTestSupport/Fixtures/Schemas/v<N>.sql`.
5. `manifest.schemaVersion` is written on every save; opening a package whose `schemaVersion` exceeds the app's maximum throws `PackageError.schemaTooNew` with the message "This project was created by a newer version of Voxglass."

### 7.5 `ProductionStore`

```swift
public protocol ProductionStore: Sendable {
    // Whole-project
    func load() async throws -> AudiobookProject
    func save(_ project: AudiobookProject) async throws          // full upsert in one transaction
    func summary() async throws -> ProjectSummary

    // Granular (hot paths — must not rewrite the whole project)
    func upsertChapter(_ chapter: Chapter) async throws
    func upsertParagraph(_ paragraph: Paragraph) async throws
    func updateParagraphText(_ id: UUID, text: String, hash: String, at: Date) async throws
    func insertTake(_ take: Take) async throws
    func setSelectedTake(_ takeID: UUID?, forParagraph: UUID) async throws
    func setTakeMetrics(_ metrics: AudioQualityMetrics, forTake: UUID) async throws
    func archiveTake(_ id: UUID, archived: Bool) async throws

    // Review
    func appendEvents(_ events: [ReviewEvent]) async throws       // idempotent by event id
    func unappliedEvents() async throws -> [ReviewEvent]
    func markEventsApplied(_ ids: [UUID], at: Date) async throws
    func setReviewState(_ state: ReviewState, forParagraph: UUID) async throws   // folder-only
    func insertNote(_ note: ReviewNote) async throws
    func notes(forParagraph: UUID) async throws -> [ReviewNote]

    // Queries used by the UI
    func paragraphSummaries(chapterID: UUID?) async throws -> [ParagraphSummary]
    func paragraphIDs(matching predicate: ReviewPredicate, order: QueueOrder) async throws -> [UUID]
    func counts() async throws -> ProjectCounts

    // Caches
    func cachedRender(forKey: String) async throws -> AudioAssetReference?
    func storeRender(_ ref: AudioAssetReference, key: String, chapterID: UUID, duration: TimeInterval) async throws
    func cachedProxy(forTake: UUID, bitrateKbps: Int) async throws -> AudioAssetReference?
    func storeProxy(_ ref: AudioAssetReference, forTake: UUID, bitrateKbps: Int) async throws

    // Sync bookkeeping
    func syncValue(_ key: String) async throws -> String?
    func setSyncValue(_ key: String, _ value: String?) async throws
}

public struct ProjectSummary: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var title: String; public var author: String; public var narrator: String
    public var percentRecorded: Double
    public var recordedCount: Int; public var totalCount: Int
    public var flaggedCount: Int; public var needsPickupCount: Int; public var unapprovedCount: Int
    public var readyToExport: Bool
    public var purpose: ProjectPurpose
    public var modifiedAt: Date
    public var coverRef: AudioAssetReference?
    public var isHiddenFromDevices: Bool
    public var projectionRevision: Int
}

public struct ParagraphSummary: Sendable, Identifiable, Equatable {
    public var id: UUID; public var chapterID: UUID; public var ordinal: Int
    public var globalOrdinal: Int              // ¶ 218 across the whole book
    public var snippet: String                 // first ~90 chars, for list rows
    public var reviewState: ReviewState
    public var hasSelectedTake: Bool
    public var takeCount: Int
    public var duration: TimeInterval?
    public var latestNoteSnippet: String?
    public var latestNoteTag: ReviewTag?
    public var isTextDrifted: Bool
    public var role: ParagraphRole
}

public struct ProjectCounts: Sendable, Equatable {
    public var paragraphs, recorded, flagged, needsPickup, approved, unreviewed: Int
    public var chapters: Int
    public var totalRecordedDuration: TimeInterval
    public var aiOriginSelected: Int
}
```

**Performance requirement.** `paragraphSummaries` and `counts` MUST be single SQL statements with aggregation done in SQLite, not in Swift over a full project load. `load()` is for export/validation/projection, not for UI rendering. Rendering the script editor for a 10 000-paragraph project must not call `load()`.

Example (`counts`):

```sql
SELECT
  COUNT(*)                                                     AS paragraphs,
  SUM(selected_take_id IS NOT NULL)                            AS recorded,
  SUM(review_state = 'flagged')                                AS flagged,
  SUM(review_state = 'needsPickup')                            AS needs_pickup,
  SUM(review_state = 'approved')                               AS approved,
  SUM(review_state = 'unreviewed')                             AS unreviewed
FROM paragraph WHERE project_id = ?;
```

### 7.6 Save strategy

- The UI never holds the authoritative project. It holds view-model state derived from the store, and every mutation goes through a store method that writes immediately, inside a transaction.
- There is **no explicit Save** for project data. The "Save" button in the Script Editor mockup (`05-script-editor`) commits the currently edited paragraph's text (a debounce flush), nothing more.
- `save(_ project:)` (full upsert) is used only by import, script generation, and undo restore. It runs in one transaction and rewrites chapters/paragraphs by diffing IDs (insert new, update changed, delete missing) — never `DELETE FROM paragraph` then reinsert, because that would cascade takes away.

### 7.7 Autosave and crash recovery

Two independent mechanisms:

**A. In-flight recording (audio).** Before the engine starts, write `Autosave/session.json`:

```json
{ "takeID":"…", "paragraphID":"…", "chapterID":"…", "filePath":"Autosave/takes/….wav",
  "format":{"sampleRate":48000,"channels":1,"bitDepth":24},
  "startedAt":1753900000.0, "appVersion":"1.2 (57)" }
```

The writer task appends to that WAV continuously. On normal stop, the file is finalized, ingested, and `session.json` is deleted. If `session.json` exists at open time, the app:

1. Validates the WAV (readable header, non-zero frames). A WAV written by `AVAudioFile` that was never closed has a stale header length; the recovery path MUST repair the RIFF/data chunk sizes from the actual file length before decoding. Implement `WAVHeaderRepair.repairInPlace(url:)`.
2. Presents a recovery sheet: "Voxglass recovered a recording of ¶ 37 (8.4 s) from a previous session." with **Keep as take** / **Discard**.
3. On keep, ingests it as a take with `origin = .recorded` and a label of "Recovered".

Acceptance test: kill the app mid-record (`SIGKILL` in a test harness, or a debug menu "Simulate crash" action available only in DEBUG), reopen, assert the take is offered and, on accept, present in the paragraph.

**B. Project metadata.** SQLite WAL plus per-mutation transactions means metadata is already durable to the last committed statement. There is no separate autosave file for metadata. The only additional requirement is `checkpoint()` on window close and on `NSApplication.willTerminate`.

---

### 7.8 Hot queries, verbatim

These four queries carry the UI. Implement them exactly; do not replace them with Swift-side filtering over `load()`.

**Paragraph summaries for a chapter** (script editor, recording rail, paragraph list):

```sql
SELECT p.id, p.chapter_id, p.ordinal, p.review_state, p.role, p.is_scene_break,
       substr(p.text, 1, 90)                                   AS snippet,
       p.selected_take_id IS NOT NULL                          AS has_take,
       (SELECT COUNT(*) FROM take t WHERE t.paragraph_id = p.id AND t.is_archived = 0) AS take_count,
       (SELECT t.duration FROM take t WHERE t.id = p.selected_take_id)                 AS duration,
       (SELECT t.text_hash_at_recording FROM take t WHERE t.id = p.selected_take_id)   AS recorded_hash,
       p.text_hash,
       (SELECT n.text FROM review_note n WHERE n.paragraph_id = p.id
          ORDER BY n.created_at DESC LIMIT 1)                   AS latest_note,
       (SELECT n.tag  FROM review_note n WHERE n.paragraph_id = p.id
          ORDER BY n.created_at DESC LIMIT 1)                   AS latest_tag,
       (SELECT COUNT(*) FROM paragraph q
          JOIN chapter c2 ON c2.id = q.chapter_id
          JOIN chapter c1 ON c1.id = p.chapter_id
          WHERE q.project_id = p.project_id
            AND (c2.ordinal < c1.ordinal OR (c2.ordinal = c1.ordinal AND q.ordinal < p.ordinal))) AS global_ordinal
FROM paragraph p
WHERE p.chapter_id = ?
ORDER BY p.ordinal;
```

The correlated `global_ordinal` subquery is O(n²) on a 10,000-paragraph project and MUST NOT be used as written for whole-book queries. Instead, maintain a materialized `global_ordinal` column on `paragraph`, recomputed in one pass whenever chapters or paragraph ordinals change:

```sql
-- migration 2: materialize global ordinals
ALTER TABLE paragraph ADD COLUMN global_ordinal INTEGER NOT NULL DEFAULT 0;
CREATE INDEX idx_paragraph_global ON paragraph(project_id, global_ordinal);
```

```swift
func renumberGlobalOrdinals(projectID: UUID) async throws {
    // one pass, ordered by (chapter.ordinal, paragraph.ordinal); single transaction; ~10 ms for 10 000 rows
}
```

Call it after import, split/merge, chapter reorder, and script application. Every UI surface that shows "¶ 218 of 2,884" reads this column.

**Queue resolution** (`ReviewQueueResolver.sql`), flagged, document order:

```sql
SELECT p.id FROM paragraph p JOIN chapter c ON c.id = p.chapter_id
WHERE p.project_id = ?
  AND p.review_state = 'flagged'
  AND (? IS NULL OR p.chapter_id IN (SELECT value FROM json_each(?)))
  AND p.selected_take_id IS NOT NULL
ORDER BY c.ordinal, p.ordinal;
```

`flaggedFirst` order adds a computed rank:

```sql
ORDER BY CASE p.review_state WHEN 'flagged' THEN 0 WHEN 'needsPickup' THEN 1 ELSE 2 END,
         c.ordinal, p.ordinal;
```

**Drifted paragraphs** (validation and the script editor's chip):

```sql
SELECT p.id, p.text_hash, t.text_hash_at_recording
FROM paragraph p JOIN take t ON t.id = p.selected_take_id
WHERE p.project_id = ? AND p.text_hash <> t.text_hash_at_recording;
```

**Selected-take metrics for validation** (one query, not N):

```sql
SELECT p.id AS paragraph_id, p.chapter_id, t.id AS take_id, t.origin_kind,
       t.duration, t.sample_rate, t.channels, t.metrics_json
FROM paragraph p JOIN take t ON t.id = p.selected_take_id
WHERE p.project_id = ?
ORDER BY p.global_ordinal;
```

Loading this once and evaluating in memory is what keeps full validation under the 2-second budget.

### 7.9 Concurrency and the store

- One `ProjectDatabase` actor per open package. Multiple view models share it.
- Reads during playback are safe (WAL) but should still go through the actor; SQLite's own locking is not the bottleneck at this scale.
- Long operations (import, script application, full save) run in a single `transaction` and must not be interleaved with UI-driven mutations; the store exposes `func withExclusiveWrite<T>(_ body: …) async throws -> T` that serializes them and lets the UI show a progress state.
- After any write batch larger than 1,000 rows, call `checkpoint()` so the WAL does not grow unbounded during import.

## 8. Document lifecycle

### 8.1 Library and recents

The Studio library screen (mockup `01-project-library`) lists projects from a **recents store** of security-scoped bookmarks, not from a scan of a fixed directory. Projects live wherever the user puts them.

```swift
public struct RecentProject: Codable, Sendable, Identifiable {
    public var id: UUID                // project id from the manifest
    public var bookmark: Data          // app-scoped security bookmark
    public var lastKnownURL: URL
    public var manifest: PackageManifest
    public var summarySnapshot: ProjectSummary?    // cached counts for instant render
    public var lastOpenedAt: Date
}
```

- On launch, resolve bookmarks lazily; a project whose bookmark fails to resolve shows as "Missing — locate…" rather than disappearing.
- The sidebar sections in the mockup — **All Projects / Needs Review / Ready to Export / Archive / Settings** — are filters over the cached `summarySnapshot`, refreshed when a project is opened or closed and after any sync fetch.
- "Ready to Export" means: every non-synthetic paragraph has a selected take, zero `needsPickup`, and the last validation run for the intended destination had no blocking issues. Compute from the snapshot; never open all DBs to render the sidebar.

### 8.2 Creating a project

The New Project wizard has four steps (mockup `02-new-project` shows "Step 1 of 4"):

1. **Project details** — title, author, narrator (all required, trimmed, non-empty).
2. **Purpose** — `publicDomainCommunity` / `personal` / `commercial (Pro)`. Selecting commercial does **not** require a purchase here; it sets the intended destination, and the Pro gate appears only at export.
3. **Rights** — basis, source edition URL, edition year, evidence notes, attestation checkbox, and the fixed string `legal.noCopyrightDetermination`.
4. **Location & source** — where to save the `.voxproject`, and (optionally) the source document to import immediately.

On finish: `ProjectPackage.create` → `ProductionStore.save(project)` → if a source was chosen, push straight into Source Import (mockup `03`); otherwise land on the Dashboard.

The wizard MUST be resumable: cancelling before finish creates nothing on disk.

### 8.3 Opening, moving, and multiple windows

- One window per project. Opening an already-open project focuses its window.
- A project is opened with an exclusive advisory lock: write a `Autosave/lock.json` containing `{ pid, deviceName, openedAt }`; if present and the pid is alive on this machine, focus that window. If present but stale (different machine, or pid gone), offer "Open anyway" — SQLite WAL tolerates it, but concurrent multi-machine editing of a package in iCloud Drive is a data-loss scenario the user should be warned about explicitly.
- Renaming the package in Finder is safe (all references are relative). Moving it while open is handled by `NSFilePresenter`-style URL tracking or, more simply, by re-resolving the bookmark on write failure.

### 8.4 Undo

Undo is required in the script editor and the take list, and is the most common source of "the app ate my work" complaints.

Implement with `UndoManager` at the **view-model** level, registering inverse store operations:

| Action | Undo |
|---|---|
| Edit paragraph text | restore previous text + hash + `updatedAt` |
| Split paragraph | merge the two back, restoring the original ID and notes |
| Merge paragraphs | split again, restoring both original IDs, texts, takes, and review states |
| Select take | select the previous take ID (or nil) |
| Archive take | unarchive |
| Delete chapter | restore chapter row + paragraphs + takes (soft-delete: keep rows with `deleted_at` until vacuum) — **DEFERRED for MVP: chapter deletion is not offered.** |
| Reorder chapters | restore prior ordinals |
| Accept structure (import) | not undoable; it is the first write of the project |

**Split/merge undo is the risky one** because takes hang off paragraph IDs. Implement split as: keep the original paragraph ID for the *first* half (so its takes stay attached) and mint a new ID for the second half. Merge as: keep the *first* paragraph's ID, move the second's takes onto it as archived takes with a label noting their origin, and record the removed ID in the undo record. This is asserted by `SplitMergeTests` (§19.3).

Recording is **not** undoable — a take is never destroyed by undo. "Undo" after a record simply reselects the previous take.
---

## 9. Text pipeline

The text pipeline turns a document into a stable, paragraph-addressed script. Its hardest requirement is **stable paragraph identity across re-import**, because a narrator who has recorded 1,200 paragraphs and then re-imports a corrected EPUB must not lose the mapping between text and audio.

### 9.1 Importers

```swift
public protocol SourceImporting: Sendable {
    var format: SourceFormat { get }
    func canImport(_ url: URL) -> Bool
    func extract(from url: URL) async throws -> ExtractedDocument
}

public struct ExtractedDocument: Sendable, Equatable {
    public var sections: [ExtractedSection]
    public var title: String?
    public var author: String?
    public var language: String?
    public var warnings: [ImportWarning]
    public var plainText: String                 // the normalized full text, for hashing + source map
}

public struct ExtractedSection: Sendable, Equatable {
    public var heading: String?
    public var blocks: [ExtractedBlock]
    public var sourceStart: Int                  // offset into plainText
}

public struct ExtractedBlock: Sendable, Equatable {
    public var kind: BlockKind                   // paragraph | heading | sceneBreak | verse | listItem | blockquote
    public var text: String
    public var headingLevel: Int?                // 1-6 for kind == .heading; nil otherwise
    public var sourceRange: Range<Int>
}
public enum BlockKind: String, Sendable { case paragraph, heading, sceneBreak, verse, listItem, blockquote }
```

Four concrete importers:

**`TXTImporter`** — the baseline; everything else normalizes toward it.
- Detect encoding: try UTF-8; on failure try UTF-16 (BOM), then Windows-1252, then ISO-8859-1; emit `.encodingFallback` warning when not UTF-8.
- Normalize line endings to `\n`.
- Blocks are separated by one or more blank lines. A single newline inside a block is a soft wrap and becomes a space — *except* when the file appears to be hard-wrapped verse (heuristic: > 30 % of lines are shorter than 60 characters and the file has no blank-line-separated blocks longer than 2 lines), in which case each line is a block of kind `.verse`.
- Heading detection: a block that is ≤ 80 characters, has no terminal `.`/`?`/`!`, and matches `^\s*(CHAPTER|BOOK|PART|SECTION|PROLOGUE|EPILOGUE|ACT|SCENE|CANTO)\b` (case-insensitive, plus Roman/Arabic numeral variants) OR is entirely uppercase.
- Scene break detection: a block matching `^\s*([*#•~—-]\s*){3,}\s*$` → `.sceneBreak` + `.possibleSceneBreak` warning (this is the mockup's "Three asterisks may indicate a scene break").

**`MarkdownImporter`** — parse with a minimal, dependency-free block scanner (do not add a Markdown dependency):
- ATX headings `#`–`######` → `.heading` with level; `#`/`##` start new sections.
- Setext headings (`===`, `---` underlines) → `.heading`.
- Thematic breaks (`***`, `---`, `___` on their own line) → `.sceneBreak`.
- Fenced code blocks are skipped with an `.imageOnlyContent`-style warning (`unrecognizedHeading` is wrong; add `.skippedNonProse`).
- Inline markup (`*`, `_`, `` ` ``, links) is **stripped to its text content** — the narrator reads prose, not syntax. Link text is kept, URL discarded.
- Images `![alt](url)` are dropped with a warning.

**`EPUBImporter`** — EPUB is a ZIP of XHTML. Implement without third-party libraries:
- Unzip via `Foundation`'s `FileManager` + a minimal ZIP reader, or via `NSFileCoordinator` + `Archive`… **decision:** implement a small read-only ZIP (deflate) reader in `Text/Zip/`, ~250 lines, using `Compression` framework's `COMPRESSION_ZLIB` raw-deflate. Do not shell out, do not add a package.
- Read `META-INF/container.xml` → OPF path → parse OPF `<manifest>` and `<spine>` with `XMLParser`.
- Read `<metadata>`: `dc:title`, `dc:creator`, `dc:language`, `dc:date`, `dc:identifier`.
- For each spine item in order, parse the XHTML with `XMLParser` in a lenient mode (EPUB 2 files are frequently malformed; on parse failure, fall back to a tag-stripping regex scan and emit `.encodingFallback`).
- Map elements: `<h1>`–`<h6>` → heading (h1/h2 start sections); `<p>` → paragraph; `<blockquote>` → blockquote; `<hr/>` → sceneBreak; `<li>` → listItem; `<img>`/`<svg>` → dropped + `.imageOnlyContent` warning.
- Decode HTML entities; collapse whitespace; preserve `&nbsp;` as a normal space.
- Skip navigation documents (`nav`, `toc.ncx`) and items whose `properties` contains `nav`.
- Emit `.emptySection` for spine items with no prose (common for cover pages).

**`DOCXImporter`** — DOCX is also a ZIP; read `word/document.xml`.
- Blocks are `<w:p>`; runs are `<w:t>` (respect `xml:space="preserve"`).
- Style-based headings: `<w:pStyle w:val="Heading1"/>` … `Heading6`, plus `Title`.
- `<w:br/>` → space; `<w:tab/>` → space.
- Numbered/bulleted lists → `.listItem`.
- Tables are skipped with a warning (audiobooks do not narrate tables well; DEFERRED).

**Registry:**

```swift
public struct SourceImporterRegistry: Sendable {
    public static let all: [any SourceImporting] = [EPUBImporter(), DOCXImporter(), MarkdownImporter(), TXTImporter()]
    public static func importer(for url: URL) -> (any SourceImporting)?  // by UTType, then extension, then sniffing
}
```

### 9.2 Segmentation

```swift
public struct SegmenterOptions: Sendable, Equatable {
    public var mergeShortBlocksUnderChars: Int = 0        // 0 = never merge
    public var splitLongBlocksOverChars: Int = 0          // 0 = never split (default; user does it manually)
    public var treatHeadingsAsParagraphs: Bool = true     // narrator usually reads "Chapter Two"
    public var sceneBreaksBecomeMarkers: Bool = true      // mark, don't create a paragraph
    public var dropEmpty: Bool = true
}

public struct Segmenter: Sendable {
    public func segment(_ doc: ExtractedDocument,
                        options: SegmenterOptions,
                        existing: AudiobookProject?,     // for stable IDs on re-import
                        ids: any IDGenerator,
                        clock: any Clock) -> SegmentationResult
}

public struct SegmentationResult: Sendable {
    public var chapters: [Chapter]
    public var warnings: [ImportWarning]
    public var stats: SegmentationStats
    public var reidentification: ReidentificationReport?   // nil on first import
}
public struct SegmentationStats: Sendable {
    public var chapterCount: Int; public var paragraphCount: Int
    public var averageParagraphChars: Int; public var longestParagraphChars: Int
    public var estimatedDuration: TimeInterval     // chars / 14.5 chars-per-second (≈150 wpm English)
}
```

Chapter formation: a new chapter begins at each `.heading` block whose level is 1 or 2 (or at each `ExtractedSection` boundary from EPUB/DOCX, which is more reliable). Blocks before the first heading become a `frontMatter` chapter titled "Front Matter" (matching mockup `03`). Chapters with zero paragraphs are dropped with a warning.

Paragraph formation: each `.paragraph`, `.verse`, `.blockquote`, `.listItem` block becomes one paragraph. `.heading` becomes a paragraph with `role = .chapterHeading` when `treatHeadingsAsParagraphs`. `.sceneBreak` sets `isSceneBreak = true` on the *following* paragraph rather than creating one.

**Estimated duration** matters for the UI (queue durations appear in the watch/CarPlay mockups) and is computed from character count at 14.5 characters per second, which approximates 150 wpm English narration. Once real takes exist, actual durations replace estimates. Non-English languages use the same constant in MVP with a `// TODO` comment; per-language rates are DEFERRED.

### 9.3 Text normalization and hashing

```swift
public enum TextNormalizer {
    /// The canonical form used for hashing and for drift comparison. NOT what is displayed.
    public static func normalize(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping        // NFC
         .replacingOccurrences(of: "\u{00A0}", with: " ")
         .replacingOccurrences(of: "\u{2018}", with: "'").replacingOccurrences(of: "\u{2019}", with: "'")
         .replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
         .replacingOccurrences(of: "\u{2013}", with: "-").replacingOccurrences(of: "\u{2014}", with: "-")
         .replacingOccurrences(of: "\u{2026}", with: "...")
         .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Aggressive form for identity matching: normalize + lowercase + strip all punctuation.
    public static func identityKey(_ s: String) -> String
    public static func hash(_ s: String) -> String { SHA256Hex.hex(Data(normalize(s).utf8)) }
}
```

`Paragraph.textHash` is `TextNormalizer.hash(text)`. Because normalization folds smart quotes and dashes, a typographic change to the source does **not** count as drift — which is exactly right: it does not change how the paragraph is read.

### 9.4 Stable paragraph identity across re-import

This is the algorithm the source plan calls "re-import preserves unchanged ¶ IDs." Implement it as a three-pass matcher:

```swift
public struct ParagraphReidentifier: Sendable {
    public func match(existing: [Paragraph], incoming: [ExtractedBlock]) -> ReidentificationReport
}

public struct ReidentificationReport: Sendable {
    public var assignments: [Int: UUID]         // incoming index → reused existing paragraph ID
    public var newIndices: [Int]                // incoming with no match → mint new ID
    public var retiredIDs: [UUID]               // existing with no match → paragraph (and its takes) orphaned
    public var driftedIDs: [UUID: DriftKind]    // matched but text changed
}
```

**Pass 1 — exact identity hash, in order.** Walk both sequences with two cursors. When `identityKey(existing[i]) == identityKey(incoming[j])`, assign and advance both. This handles the overwhelmingly common case (nothing changed) in O(n) with zero ambiguity.

**Pass 2 — anchored windowed match.** For unmatched runs between two matched anchors, match within the window by `identityKey` equality regardless of order (a paragraph moved a little), then by high similarity. Similarity is **token-level Jaccard on word 3-grams**, threshold **0.72**, computed only within the window (bounded work). A window larger than 400 paragraphs on either side is split at the midpoint to bound cost.

**Pass 3 — first/last-sentence anchoring.** For still-unmatched pairs in a window, compare the first 60 and last 60 characters of `identityKey`. If either end matches exactly and lengths are within ±40 %, treat as the same paragraph with drift. This catches "the editor fixed a typo in the middle."

Everything else is new/retired.

**Retirement is never destructive.** A retired paragraph's takes are not deleted. The re-import UI reports "12 paragraphs no longer appear in the source; 4 of them have recordings" and offers **Keep as orphaned** (moved into a synthetic `Orphaned Recordings` chapter with `role = .backMatter`, excluded from export) or **Discard**. Default is Keep.

**Complexity budget.** For 10,000 paragraphs, pass 1 is O(n); passes 2 and 3 are bounded by window size. `SegmenterTests` includes a 10,000-paragraph re-import that must complete in under 2 seconds on an M-series Mac.

### 9.5 Text drift detection

Drift is what happens when a paragraph's text changes *after* a take was recorded for it. The take's `textHashAtRecording` is compared to the paragraph's current `textHash`.

```swift
public enum DriftKind: String, Sendable, Codable {
    case none
    case cosmetic          // punctuation/whitespace/quote style only → keep take, mark informational
    case minor             // ≤ 2 word-level edits and no meaning-bearing change → keep take, warn
    case semantic          // anything else → set needsPickup
}

public struct TextDriftDetector: Sendable {
    public func classify(recorded: String, current: String) -> DriftKind
}
```

Algorithm:

1. If `TextNormalizer.hash(recorded) == TextNormalizer.hash(current)` → `.none`.
2. If `identityKey(recorded) == identityKey(current)` → `.cosmetic` (only punctuation/case/whitespace differ).
3. Compute word-level Levenshtein distance on the `identityKey` token arrays. Let `d` be the distance and `n` the max token count.
   - `d <= 2 && Double(d)/Double(n) <= 0.05` → `.minor`
   - otherwise → `.semantic`
4. Special case: if the only difference is the addition or removal of a **number word or digit**, always `.semantic` (numbers are read aloud and matter).

> **Amended (S5 audit):** the implementation runs the step-4 number check *before* the step-2/step-3 cosmetic/minor checks. The spec's step 4 says "always `.semantic`", so the reordering is intentional and correct; the algorithm below is unchanged. Also, `identityKey` includes decimal digits (the original wording "strip all punctuation" excluded digits by accident, which made `"Chapter 3"` and `"Chapter 4"` collide).

Consequences:
- `.cosmetic` — no UI noise beyond a subtle chip.
- `.minor` — the Script Editor shows the amber "Text changed" chip (mockup `05-script-editor`) and the Validation report emits a **warning**.
- `.semantic` — the paragraph's review state is set to `needsPickup` by emitting a `ReviewEvent(type: .needsPickup)` with `device: .mac`, and the Validation report emits a **blocking** issue for export targets.

Drift is recomputed whenever paragraph text changes and whenever a take is selected, and is *not* stored: it is derived from `textHash` vs `textHashAtRecording` on read. `ParagraphSummary.isTextDrifted` is computed in SQL: `p.text_hash != t.text_hash_at_recording`.

### 9.6 Split and merge

```swift
public struct ParagraphSplitter: Sendable {
    public func split(_ paragraph: Paragraph, atCharacterOffset: Int, ids: any IDGenerator, clock: any Clock)
        -> (first: Paragraph, second: Paragraph)
    public func merge(_ a: Paragraph, _ b: Paragraph, clock: any Clock) -> Paragraph
}
```

Normative semantics (asserted by `SplitMergeTests`):

- **Split** keeps `a.id` on the first half. The second half gets a new ID. Takes stay with the first half but are **all marked drifted** automatically (their `textHashAtRecording` no longer matches), so the narrator is prompted to re-record. Direction notes and pronunciation refs are copied to **both** halves. Review state: first keeps its state; second becomes `.unreviewed`.
- **Merge** keeps `a.id`. `b`'s takes are moved onto `a` with `isArchived = true` and `label` prefixed "From merged ¶". `b`'s notes are re-pointed to `a`. Direction notes are concatenated with `"\n"`. Review state is the *worse* of the two, ordered `needsPickup > flagged > unreviewed > approved`.
- Both operations renumber the chapter's ordinals contiguously and update `updatedAt`.
- Both are undoable (§8.4).

### 9.7 The Source Import screen contract

Mockup `03-source-import` shows: a chapter/paragraph tree with counts, the detected format and section count, warnings, per-paragraph "Split here" / "Merge next" affordances, a "Mark Scene Break" action for the warning, "Re-segment", "Accept Structure", and a Source Mapping panel with the text hash and edition year.

The screen operates on an **in-memory** `SegmentationResult` and writes nothing until "Accept Structure". On accept:

1. `ProjectPackage` ingests the original file into `Text/source/` and the extracted JSON into `Text/extracted/`.
2. `SourceDocument` is populated (including `textHash` and `detectedSectionCount`).
3. `ProductionStore.save(project)` writes chapters and paragraphs in one transaction.
4. If this is a **re-import** over an existing project, the reidentification report is applied and shown as a summary sheet before the write, with counts of reused / new / retired / drifted.

---

## 10. Generated scripts: disclaimers and credits

This is the feature that most directly converts §3's research into narrator value, and it is small.

### 10.1 The generator protocol

```swift
public protocol ScriptGenerating: Sendable {
    var destination: DestinationID { get }
    /// Returns the paragraphs that must exist, in order, for each chapter, plus book-level chapters.
    func plan(for project: AudiobookProject) -> ScriptPlan
}

public struct ScriptPlan: Sendable, Equatable {
    public var chapterIntros: [UUID: String]       // chapterID → intro text
    public var chapterOutros: [UUID: String]
    public var bookChapters: [SyntheticChapter]    // e.g. opening/closing credits chapters
}
public struct SyntheticChapter: Sendable, Equatable {
    public var role: ChapterRole; public var title: String; public var paragraphText: String
    public var paragraphRole: ParagraphRole
}
```

### 10.2 `LibriVoxScriptGenerator`

Produces the exact text from §3.2.3.

```swift
public struct LibriVoxScriptGenerator: ScriptGenerating {
    public let useShortFormAfterFirstSection: Bool = true
    public func plan(for project: AudiobookProject) -> ScriptPlan
}
```

Intro text for section *N* (1-based, counting only `role == .body || .frontMatter || .backMatter` chapters), long form:

```
Chapter {N} of {Title}. This is a LibriVox recording. All LibriVox recordings are in the public domain. For more information, or to volunteer, please visit librivox dot org.
Recording by {Narrator}.
{Title}, by {Author}.{ Translated by {Translator}.} {ChapterTitle}.
```

Short form for N > 1 when `useShortFormAfterFirstSection`:

```
Chapter {N} of {Title}. This LibriVox recording is in the public domain.
{ChapterTitle}.
```

Outro:

```
End of {ChapterTitle}.
```

Final section outro appends:

```
End of {Title}, by {Author}.
```

Notes:
- "librivox dot org" is spelled out because the narrator reads it aloud; do not write "librivox.org" and expect the human to interpret it.
- If `ChapterTitle` is empty or duplicates "Chapter N", omit the trailing sentence rather than producing "Chapter 3. Chapter 3."
- The generator is pure and fully unit-tested against a table of fixtures including a translated work, a single-section work, and a work with front matter.

### 10.3 `RetailScriptGenerator`

```
Opening credits:  {Title}.{ {Subtitle}.} Written by {Author}. Narrated by {Narrator}.
Closing credits:  This has been {Title}, written by {Author}, narrated by {Narrator}.
                  { Copyright {CopyrightYear} {RightsHolder}.}{ Production copyright {ProductionYear} {Publisher}.}
                  The end.
```

These become `SyntheticChapter`s with `role = .openingCredits` (ordinal 0) and `.closingCredits` (last ordinal).

### 10.4 Applying and re-applying a plan

```swift
public struct ScriptApplier: Sendable {
    public func apply(_ plan: ScriptPlan, to project: inout AudiobookProject,
                      ids: any IDGenerator, clock: any Clock) -> ScriptApplyReport
}
public struct ScriptApplyReport: Sendable {
    public var inserted: Int; public var updated: Int; public var unchanged: Int; public var drifted: [UUID]
}
```

Rules:

- Applying is **idempotent**: applying the same plan twice changes nothing.
- A generated paragraph is identified by `(chapterID, role)`, not by text. If its text changes because metadata changed, the paragraph's `text` and `textHash` are updated and any existing take becomes drifted (which, being `.semantic`, sets `needsPickup`). This is correct: if the title changed, the disclaimer must be re-recorded.
- Generated paragraphs are visually distinct in the UI (a "Generated" chip) and are **not editable** by hand — editing is done by changing the metadata. (Rationale: hand-edited disclaimers are the #1 LibriVox rejection cause.) An "Edit anyway" escape hatch exists behind a confirmation, which sets a `isCustomized` flag that stops regeneration for that paragraph.
- The apply action is offered:
  - automatically on first entering the Record tab when `intendedDestination == .librivox` and no intro paragraphs exist ("Add LibriVox disclaimers to all chapters?" — one-tap accept);
  - from Metadata & Rights whenever metadata that appears in the script changes ("Disclaimer text is out of date — Update");
  - from the Export wizard's validation step as a `FixAction`.

### 10.5 Validation ties

- `IssueCode.missingDisclaimerParagraph` — LibriVox target, chapter without an intro/outro generated paragraph. **Blocking.**
- `IssueCode.unrecordedDisclaimer` — generated paragraph exists but has no selected take. **Blocking.**
- `IssueCode.staleDisclaimerText` — generated paragraph's text differs from what the generator currently produces (metadata changed). **Blocking** for LibriVox, **warning** elsewhere.
- `IssueCode.missingOpeningCredits` / `.missingClosingCredits` — retail targets. **Blocking.**
---

## 11. Audio: capture, import, and measurement

### 11.1 Capture protocol (Core)

```swift
public protocol AudioCapturing: AnyObject, Sendable {
    var state: CaptureState { get }
    var levels: AsyncStream<CaptureLevels> { get }          // ~30 Hz, for meters only
    func availableInputDevices() async -> [AudioDeviceInfo]
    func prepare(device: String?, format: RecordingDefaults) async throws
    func startMonitoring() async throws                      // input → output, no file
    func stopMonitoring() async
    /// Starts writing to `destinationURL`. Pre-roll is handled by the caller (§11.4).
    func startRecording(to destinationURL: URL) async throws
    func stopRecording() async throws -> CapturedTake
    func cancelRecording() async                             // discards the file
    func punchIn(from offset: TimeInterval) async throws     // DEFERRED for MVP; protocol reserved
}

public enum CaptureState: Sendable, Equatable { case idle, prepared, monitoring, recording, stopping, failed(String) }

public struct CaptureLevels: Sendable, Equatable {
    public var peakDBFS: Float          // instantaneous peak of the last block
    public var rmsDBFS: Float
    public var isClipping: Bool         // any sample |x| >= 0.999 in the last block
    public var sampleTime: TimeInterval // running recorded duration
}

public struct CapturedTake: Sendable, Equatable {
    public var fileURL: URL
    public var duration: TimeInterval
    public var format: AudioFormatDescription
    public var clippedDuringCapture: Bool
    public var peakDBFS: Double         // running peak, cheap; full metrics computed later
}

public struct AudioDeviceInfo: Sendable, Equatable, Identifiable {
    public var id: String               // device UID
    public var name: String             // "Universal Audio Volt 2 — Input 1"
    public var channelCount: Int
    public var supportedSampleRates: [Double]
    public var isDefault: Bool
    public var transport: String        // "USB", "Built-in", "Bluetooth"
}
```

### 11.2 `AVAudioEngineCapture` (Studio)

Graph:

```
AVAudioInputNode ──tap(bufferSize: 4096)──▶ RingBuffer ──▶ WriterTask ──▶ AVAudioFile
       │
       └─(when monitoring)─▶ AVAudioMixerNode ─▶ AVAudioOutputNode
```

Requirements:

1. **Format.** Record at the project's `RecordingDefaults` (default 48 kHz / 24-bit / mono WAV). The input node's hardware format may differ; insert an `AVAudioConverter` in the writer task, never in the tap.
2. **Channel selection.** If the device offers more channels than requested, take channel 0 by default, with a device-settings picker for which channel to use. (A Volt 2 exposes two inputs; narrators use one.)
3. **Tap discipline.** The tap block MUST: copy floats into a preallocated lock-free ring buffer, update `atomic` peak/RMS accumulators, and return. No allocation, no locks, no logging, no Swift concurrency, no `Date()`.
4. **Ring buffer.** Single-producer/single-consumer, power-of-two capacity sized to 4 seconds of audio at the record format. Overrun (writer starved) increments a counter that is surfaced as a `CaptureError` after the take, and the take is still kept — never discard audio because of a meter problem.
5. **Bluetooth inputs** are offered but flagged in the UI: "Bluetooth microphones are low quality and not suitable for audiobook production." Do not block them.
6. **Device change mid-recording** (`AVAudioEngineConfigurationChange`): stop the engine, finalize the file as a complete take, and surface `CaptureError.deviceChanged(name)` with the take preserved. **Never lose audio because a cable moved.**
7. **Sample-rate mismatch** between requested and hardware: prefer setting the hardware rate; if the device refuses, record at the hardware rate and record the true format in the take. The transcoder handles conversion later. Emit a warning in the UI once per session.
8. **Interruptions.** macOS does not have `AVAudioSession`, but it does have engine-stop conditions (sleep, device removal). Handle `NSWorkspace.willSleepNotification` by stopping cleanly.
9. **Permissions.** Request microphone access via `AVCaptureDevice.requestAccess(for: .audio)` on first prepare, with a pre-permission explanation sheet. Denied → `CaptureError.permissionDenied` with a "Open System Settings" button.

### 11.3 Metering isolation (the invalidation-storm fix)

```swift
@Observable @MainActor public final class RecordingMeter {
    public private(set) var peakDBFS: Float = -120
    public private(set) var rmsDBFS: Float = -120
    public private(set) var isClipping = false
    public private(set) var waveform: [Float] = []       // ring of ~600 downsampled peaks for the scroller
    public private(set) var elapsed: TimeInterval = 0
}
```

- `RecordingMeter` is a **separate** `@Observable` from `RecordingModel`. It is consumed only by `RecordingMeterView` and `WaveformView`.
- It is updated from the `levels` stream at ≤ 30 Hz, coalescing.
- `RecordingModel` (teleprompter text, take list, transport enablement, paragraph navigation) MUST NOT observe it, MUST NOT store `elapsed`, and MUST NOT be updated per audio block. `RecordingModel.elapsedForDisplay` does not exist; the timer lives in the meter.
- Test: `RenderCountProbeTests` wraps the teleprompter view in a counter and asserts fewer than 3 body evaluations during a 5-second simulated recording. This is CI-gate-adjacent and is the concrete defense against the previously observed 1 Hz app-wide invalidation.

### 11.4 The recording workflow

Mockup `06-recording-workspace` defines the interaction. Normative behavior:

**Keyboard flow (the entire product's ergonomics live here):**

| Key | Action |
|---|---|
| `Space` | Record / Stop |
| `Return` | Accept take & advance to next paragraph |
| `⌘Return` | Flag & advance |
| `R` | Retake (discard nothing; start a new take on the same paragraph) |
| `←` / `→` | Previous / next paragraph |
| `⌥Space` | Play selected take |
| `⇧Space` | Play in context (previous paragraph tail + this + next head) |
| `⌘⌫` | Archive current take |
| `1`…`9` | Select take N |
| `P` | Toggle monitoring |

All shortcuts MUST work without focus juggling: the recording workspace installs a local key monitor and text fields are the only elements that swallow keys.

**Recording a paragraph:**

1. Pre-roll: if `preRollSeconds > 0`, the transport shows a countdown and the engine is already running; audio recorded during pre-roll is written but the take's `trimStart` processing step is set to `preRollSeconds` so it is inaudible by default. (Recording *through* the pre-roll rather than after it means the narrator's first breath is captured and recoverable.)
2. Recording writes to `Autosave/takes/<uuid>.wav` with `session.json` present (§7.7).
3. Stop: engine stops → file finalized → hashed → ingested (moved) into `Audio/Original` → `Take` row inserted → metrics computed asynchronously → `session.json` deleted.
4. Auto-selection: the new take becomes selected **unless** the setting "Keep previously selected take" is on. Default: newest becomes selected.
5. Auto-advance: `Return` selects and advances. Advance skips paragraphs that already have a selected take when "Skip recorded" is on (default on for a first pass; off during pickups).
6. Clipping: if the take clipped and "Warn on clipping" is on, show a non-modal inline warning with **Retake** and **Keep** buttons. Never auto-discard.

**Recording a pickup queue:** when entering the workspace from the review queue with `needsPickup` paragraphs, the paragraph list is filtered to that queue and `Return` advances within it.

**Acceptance:** record 100 sequential paragraphs without losing a take; recover the last take after a forced termination.

### 11.5 Importing existing audio

Mockup `07-import-audio`. Supported inputs: WAV, AIFF, CAF, M4A/AAC, MP3, FLAC (all decodable by AVFoundation on macOS 14; FLAC decode is supported natively).

```swift
public protocol AudioDecoding: Sendable {
    func describe(_ url: URL) async throws -> AudioFormatDescription
    func decodeToMonoFloat(_ url: URL, targetSampleRate: Double?) async throws -> DecodedAudio
}
public struct DecodedAudio: Sendable { public var samples: [Float]; public var sampleRate: Double; public var duration: TimeInterval }
```

**Assignment methods** (the mockup's three options):

1. **Assign one paragraph** — the whole file becomes one take for the selected paragraph.
2. **Assign entire file to chapter** — the file becomes one take spanning the chapter; Voxglass creates a single `chapterSpanning` take attached to the chapter's *first* paragraph and marks the remaining paragraphs `.coveredBySpanningTake`. **DECISION: not in MVP.** Spanning takes break paragraph addressing, which is the product's core. Instead, this option performs silence-based splitting into exactly `chapter.paragraphs.count` segments, and if the counts do not match, the user must adjust markers. Rename the UI option to **"Split file across this chapter"**.
3. **Assign detected segments sequentially** — the default. Silence detection proposes boundaries; the user adjusts.

**Silence-based segmentation:**

```swift
public struct SilenceSegmenter: Sendable {
    public struct Options: Sendable {
        public var thresholdDBFS: Double = -40      // relative to file peak, clamped to absolute -50
        public var minSilenceDuration: TimeInterval = 0.35
        public var minSegmentDuration: TimeInterval = 0.8
        public var boundaryPadding: TimeInterval = 0.08   // keep a little air on both sides
    }
    public func detect(samples: [Float], sampleRate: Double, options: Options) -> [SilenceRegion]
    public func proposeBoundaries(_ regions: [SilenceRegion], targetCount: Int?) -> [SegmentBoundary]
}
public struct SegmentBoundary: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var time: TimeInterval
    public var confidence: Confidence       // high | review  (mockup shows "High"/"Review")
    public var isUserPlaced: Bool
}
```

Algorithm: compute a 20 ms-hop RMS envelope; mark frames below threshold; coalesce runs ≥ `minSilenceDuration` into silence regions; boundaries are placed at the *midpoint* of each silence region; drop boundaries that would create segments shorter than `minSegmentDuration`. When `targetCount` is known (number of paragraphs to fill), keep the `targetCount - 1` boundaries sitting in the longest silences and mark the rest `.review`.

**Confidence** is `.high` when the silence region is ≥ 0.6 s and the surrounding segments are ≥ 2 s; otherwise `.review`.

The import table (mockup) shows `Segment | Paragraph | Confidence` with editable paragraph assignment, plus **＋ Split Marker** / **− Remove Marker**. Users can drag markers on the waveform.

**Origin declaration is mandatory.** The sheet forces one of:
- *External human recording* → `.importedHuman(sourceFilename:)`
- *AI-generated or AI-processed* → `.aiImported(providerLabel:)` (with a free-text provider field)
- *Unknown* → `.unknownImport(sourceFilename:)`

and shows, live, the sentence: **"AI-origin segments make the project ineligible for LibriVox export."** when a non-human option is chosen. This is a required a11y-labeled element (`import.originWarning`).

**Import writes** one `Take` per assigned segment. Rather than slicing the source file into N files (which would multiply storage), the MVP **does** slice: each segment is decoded and written as its own WAV in `Audio/Original`, because paragraph-addressed playback, proxy generation, and per-take metrics all assume one file per take. Slicing a 3-hour import to 400 WAVs at 48/24 mono costs ~3 GB — acceptable, and the original imported file is *also* retained. Offer a post-import "Remove original imported file" action that trashes the source blob once slices are verified.

### 11.6 Metrics — exact algorithms

```swift
public protocol AudioMetricsCalculating: Sendable {
    func metrics(for url: URL) async throws -> AudioQualityMetrics
    func metrics(for samples: [Float], sampleRate: Double, channels: Int) -> AudioQualityMetrics
}
public struct AudioMetricsCalculator: AudioMetricsCalculating { public static let analyzerVersion = 1 }
```

The pure sample-array overload lives in Core and is fully unit-tested; the URL overload lives in the app and decodes first. All levels are dBFS with 1.0 full scale: `db = 20 * log10(max(x, 1e-7))`.

**11.6.1 Peak.** `peakDBFS = 20*log10(max |x|)`.

**11.6.2 True peak.** 4× oversample with a windowed-sinc (or a simple 4-phase FIR polyphase interpolator, 33 taps, Kaiser β=8), take max |y|. Report `truePeakDBFS`. Needed because MP3/AAC encoding can push inter-sample peaks above the PCM peak; the retail limiter targets true peak.

**11.6.3 RMS.** Compute over the file **excluding leading and trailing silence** (else a long tail drags the number down and an ACX-compliant file reads as too quiet):

```
rms = sqrt( (1/N) * Σ x[i]^2 )  for i in [firstNonSilent, lastNonSilent]
rmsDBFS = 20*log10(rms)
```

**11.6.4 Noise floor.** *The commonly mis-implemented one.* Measured as the RMS of the **silent** portions only:

1. Compute a 50 ms-window RMS envelope with 25 ms hop.
2. Take the 10th percentile of the envelope as an initial estimate `e0`.
3. Define silence as windows whose RMS < `max(e0 * 4, absoluteFloor)` where `absoluteFloor = 10^(-70/20)`.
4. `noiseFloorDBFS` = dB of the RMS over all silent windows, or `-90` if fewer than 10 windows qualify (report `-90` and set a `insufficientSilence` note rather than pretending).
5. Require at least 0.5 s of detected silence total; otherwise mark the metric as unreliable (`noiseFloorDBFS = .nan` is forbidden — use `-90` plus a boolean `noiseFloorReliable`). **Add `noiseFloorReliable: Bool` to `AudioQualityMetrics`.**

**11.6.5 Clip count.** Number of runs of ≥ 3 consecutive samples with |x| ≥ 0.9995. Runs, not samples, so one clipped transient counts once.

**11.6.6 DC offset.** Mean of all samples; report as a linear value. Warn above 0.002.

**11.6.7 Leading/trailing silence.** Time from file start to the first window above the silence threshold, and symmetrically at the end.

**11.6.8 ReplayGain (for LibriVox).** Implement the ReplayGain 1.0 algorithm: equal-loudness (Butterworth + Yulewalk) filter pair, 50 ms blocks, RMS per block, 95th-percentile block loudness, referenced to 89 dB. This is ~120 lines of biquad coefficients and is worth doing properly because it is the number LibriVox proof-listeners use. The repo already contains `BiquadFilter.swift`, which the implementation SHOULD reuse.

> **Deviation (amended S5):** the implementation does NOT reuse `BiquadFilter.swift`. That filter is `Float` while the ReplayGain metrics are specified in `Double`, and the Yule stage is not a biquad but a single direct-form 11-tap section (ReplayGain 1.0 defines it that way to avoid ill-conditioned degree-10 root-finding). The S5 implementation keeps the published coefficient tables (44.1 kHz and 48 kHz) verbatim in `ReplayGainCoefficients.swift` and runs them through a single direct-form-II transposed section; the per-sample arithmetic is Float32 — exactly as in the published reference (`flac` `gain_analysis.c`) — because that is what keeps the §11.6.9 30-second budget in reach. Any other sample rate is resampled to 48 kHz before analysis. §23's reuse list is amended identically.

Report `replayGainDB` as the *gain that would be applied* (so `0` means already at 89 dB) and derive the displayed "perceived volume" as `89 - replayGainDB`.

**11.6.9 Performance.** Metrics for a 30-second take must complete in < 150 ms. Metrics run on a background task after the take is saved; the UI shows "Analyzing…" and fills in.

**11.6.10 Batch analysis.** "Automatically calculate quality metrics" (Settings) computes metrics on import and record. A "Analyze all takes" maintenance action recomputes when `analyzerVersion` changes, showing progress; stored metrics with an older `analyzerVersion` are treated as absent by validation.

### 11.7 Take comparison

Mockup `08-take-comparison`: A/B playback, per-take duration and peak, "Select This Take".

- A/B switching is **gapless and position-preserving**: switching from take A at t=3.2 s starts take B at min(3.2, B.duration). Implement by keeping two prepared player nodes and crossfading in 15 ms.
- The comparison view shows metrics side by side with the differences highlighted; the recommended take (highest RMS within range, no clipping, lowest noise floor) is marked "Suggested" — a heuristic, never automatic selection.

---

## 12. Assembly, rendering, and playback

### 12.1 Segments

```swift
public struct PlaybackSegment: Sendable, Equatable, Identifiable {
    public var id: UUID { paragraphID }
    public let paragraphID: UUID
    public let chapterID: UUID
    public let globalOrdinal: Int
    public let assetRef: AudioAssetReference
    public let trim: Range<TimeInterval>          // in-file window after processing steps
    public let gainDB: Double
    public let fadeIn: TimeInterval
    public let fadeOut: TimeInterval
    public let leadingSilence: TimeInterval       // inserted BEFORE this segment
    public let trailingSilence: TimeInterval
    public let text: String                       // for teleprompter/watch display
    public let reviewState: ReviewState
}

public struct AssemblySettings: Codable, Sendable, Equatable {
    public var paragraphGap: TimeInterval = 0.45
    public var sentenceGapBonus: TimeInterval = 0.0     // DEFERRED, keep at 0
    public var chapterHeadSilence: TimeInterval = 0.75
    public var chapterTailSilence: TimeInterval = 1.5
    public var sceneBreakExtraGap: TimeInterval = 1.0   // applied before a paragraph with isSceneBreak
    public var normalizeGapsFromTakeSilence: Bool = true // trim take head/tail silence, then insert exact gaps
}
```

`normalizeGapsFromTakeSilence` is important and defaulted **on**: raw takes have irregular head/tail silence, so the assembler trims each take to its non-silent bounds (leaving 30 ms of air) and then inserts the exact configured gap. That is what makes an assembled chapter sound even without editing.

### 12.2 Queue building

```swift
public enum PlaybackMode: Sendable, Equatable {
    case wholeBook
    case chapter(UUID)
    case selectedChapters(Set<UUID>)
    case flagged
    case needsPickup
    case unapproved
    case reviewQueue(ReviewQueueDefinition)
    case paragraphRange(chapterID: UUID, from: Int, to: Int)
    case retailSample(startParagraph: UUID, maxDuration: TimeInterval)
}

public struct SegmentQueueBuilder: Sendable {
    public func build(_ mode: PlaybackMode, from project: AudiobookProject, settings: AssemblySettings) -> [PlaybackSegment]
}
```

Rules:
- Only paragraphs with a selected take produce segments. Paragraphs without one are **skipped silently** in listening modes and are **reported** in export modes (validation catches them first).
- `wholeBook` inserts `chapterHeadSilence` before each chapter's first segment and `chapterTailSilence` after its last.
- In review modes, `leadingSilence` is 0 and `trailingSilence` is 0.25 s — the reviewer wants tight turnaround, not the book's pacing. When "Play 1 s context" is enabled (mockups: Mac review queue, CarPlay settings), the builder prepends a 1.0 s tail slice of the previous paragraph's take and appends a 1.0 s head slice of the next, as separate non-actionable segments flagged `isContext = true`. **Add `isContext: Bool` to `PlaybackSegment`.**

### 12.3 Render plans and the cache key

```swift
public struct RenderPlan: Sendable, Equatable {
    public let chapterID: UUID
    public let segments: [PlaybackSegment]
    public let settings: AssemblySettings
    public let outputFormat: AudioSpec
    public let cacheKey: String
}

public enum RenderCacheKey {
    /// SHA-256 over a canonical, versioned description of everything that affects the output.
    public static func key(chapterID: UUID, segments: [PlaybackSegment],
                           settings: AssemblySettings, format: AudioSpec, algorithmVersion: Int) -> String {
        var parts: [String] = ["v\(algorithmVersion)", chapterID.uuidString,
                               "\(format.container.rawValue)/\(format.codec.rawValue)/\(format.sampleRate ?? 0)/\(format.channels ?? 0)/\(format.bitrateKbps ?? 0)"]
        parts.append("gap=\(settings.paragraphGap);head=\(settings.chapterHeadSilence);tail=\(settings.chapterTailSilence);scene=\(settings.sceneBreakExtraGap);norm=\(settings.normalizeGapsFromTakeSilence)")
        for s in segments {
            parts.append("\(s.assetRef.sha256)|\(s.trim.lowerBound)|\(s.trim.upperBound)|\(s.gainDB)|\(s.fadeIn)|\(s.fadeOut)|\(s.leadingSilence)|\(s.trailingSilence)")
        }
        return SHA256Hex.hex(joining: parts)
    }
}
```

**Requirements:**
- The key MUST be stable across process launches (CI gate G-4 forbids `Hasher()`/`hashValue` in this area).
- Changing one paragraph's take changes exactly one chapter's key. The Assembly screen's "Only 3 changed paragraphs require rebuilding" (mockup `10`) is computed by diffing the current key set against `render_cache`.
- Bump `algorithmVersion` whenever the assembler's output would change (e.g. a different trim rule). This invalidates every cached render deliberately.

### 12.4 Rendering

```swift
public protocol ChapterRendering: Sendable {
    func render(_ plan: RenderPlan, to url: URL, progress: @Sendable (Double) -> Void) async throws -> RenderedChapter
}
public struct RenderedChapter: Sendable { public var ref: AudioAssetReference; public var duration: TimeInterval; public var paragraphOffsets: [UUID: Range<TimeInterval>] }
```

Implementation (`AVChapterRenderer` in Studio):
- Output to CAF/PCM at the project's recording format (lossless intermediate). Lossy conversion happens only in the transcoder at export.
- Read each take with `AVAudioFile`, apply trim by frame position, apply gain and fades sample-wise, write silence buffers between segments.
- Resample per-take if a take's sample rate differs from the render format (imports may differ) using `AVAudioConverter` with `.mastering` quality.
- `paragraphOffsets` is returned and **persisted** — this is what makes "seek to ¶ 218" work on a rendered file, and what the M4B/exported-file paragraph map uses.
- Cancellable between segments.
- Progress reported per segment.

### 12.5 Playback

```swift
public protocol SegmentPlayer: AnyObject, Sendable {
    var currentParagraphID: UUID? { get }
    var currentTime: TimeInterval { get }              // within the current paragraph
    var isPlaying: Bool { get }
    var events: AsyncStream<PlayerEvent> { get }
    func load(_ segments: [PlaybackSegment]) async throws
    func play() async throws
    func pause() async
    func seek(toParagraph id: UUID, offset: TimeInterval) async throws
    func nextParagraph() async throws
    func previousParagraph() async throws
    func skip(by seconds: TimeInterval) async throws
    func setRate(_ rate: Float) async
}
public enum PlayerEvent: Sendable, Equatable {
    case paragraphChanged(UUID)
    case finished
    case stalled
    case failed(String)
    case bufferedThrough(UUID)
}
```

`AVSegmentPlayer` implementation notes (shared design; three platform copies differing only in session handling):

- Use `AVAudioEngine` + `AVAudioPlayerNode` with **scheduled buffers** rather than `AVQueuePlayer`, because gapless segment-to-segment transitions with programmatic silence require sample-accurate scheduling.
- Schedule the current segment plus the next two; refill on completion callbacks. This bounds memory and satisfies the phone's "prefetch next 3 ¶" requirement.
- Silence between segments is scheduled as an actual zero buffer of exact length — do not rely on timers.
- Paragraph boundary detection uses the scheduler's completion handler, and the `paragraphChanged` event MUST fire within 50 ms of the boundary (performance budget) because the watch fires a haptic on it.
- **Transport semantics in production mode: `next`/`previous` mean paragraph**, not 15/30 seconds and not chapter. The ± buttons on iPhone/CarPlay remain time skips (mockups show `−15` / `+30` alongside `◀¶` / `¶▶`).
- Rate: 0.75×–2.0× via `AVAudioUnitTimePitch`. Reviewers use 1.25–1.5×.
- **iOS/watchOS only:** configure `AVAudioSession` in the app layer — `.playback` category, `.spokenAudio` mode, `.duckOthers` off. CarPlay requires the session to be active before the now-playing template appears.

### 12.6 The Assembly screen contract

Mockup `10-chapter-assembly`: table of ¶ / Take / Trim / Gap / Status, spacing controls, "Render Preview", "Play Chapter", "Rebuild Changed Audio", and the cache summary.

- Editing `paragraphGap` recomputes the cache key and immediately shows how many renders are invalidated, before the user commits.
- "Render Preview" renders only the visible chapter.
- "Rebuild Changed Audio" renders every chapter whose key is missing from `render_cache`, sequentially, cancellable, with per-chapter progress.
- Trim values shown (e.g. `0.12–7.82`) come from the take's processing steps; editing them opens a small waveform trim editor. Trim edits are non-destructive and invalidate that chapter's render.
---

## 13. Sync: CloudKit projection and the watch relay

### 13.1 The model in one paragraph

The Mac is the **single writer** of production content. It publishes a *projection* — a read-only, compressed, selected-takes-only view of the project — to the user's private CloudKit database. The phone and CarPlay consume the projection and emit **review events**. The watch never touches CloudKit; it exchanges payloads with the phone over WatchConnectivity. Events flow back to the Mac, which folds them into review state and may then republish. There is exactly one writer per record type, which is why the conflict surface is small.

```
   Mac (writer) ──publish projection──▶ CloudKit ──fetch──▶ iPhone ──WatchConnectivity──▶ Watch
        ▲                                   ▲                  │                            │
        └──────fetch events─────────────────┴───push events────┴────────relay events────────┘
```

### 13.2 CloudKit schema

Container `iCloud.guru.parso.voxglass`, **private** database, custom zone `VGProductionZone`.

**`VGProductionProject`** — recordName = `project-<uuid>`
| Field | Type | Notes |
|---|---|---|
| `projectID` | String | UUID string |
| `title`, `author`, `narrator`, `language` | String | |
| `purpose` | String | `ProjectPurpose` raw |
| `percentRecorded` | Double | |
| `recordedCount`, `totalCount`, `flaggedCount`, `needsPickupCount`, `unapprovedCount` | Int64 | |
| `revision` | Int64 | monotonically increasing; the consumer's staleness check |
| `isHidden` | Int64 | 1 = withdrawn from devices |
| `coverAsset` | CKAsset | ≤ 512×512 JPEG |
| `modifiedAt` | Date | |
| `narrationOrigin` | String | `humanOnly` / `containsImportedAI` |
| `intendedDestination` | String | |

**`VGProductionChapter`** — recordName = `chapter-<uuid>`, `parent` = project record
| `chapterID`, `projectID`, `ordinal`, `title`, `role`, `paragraphCount`, `recordedCount`, `duration` |

**`VGProductionParagraph`** — recordName = `para-<uuid>`, `parent` = chapter record
| Field | Type | Notes |
|---|---|---|
| `paragraphID`, `chapterID`, `projectID` | String | |
| `ordinal`, `globalOrdinal` | Int64 | |
| `text` | String | omitted when `includeSourceTextInProjection == false` |
| `reviewState` | String | |
| `takeID` | String | the selected take |
| `duration` | Double | |
| `proxyAsset` | CKAsset | AAC mono @ `proxyBitrateKbps` |
| `proxySHA` | String | content hash of the *source* take, for change detection |
| `latestNoteText`, `latestNoteTag` | String | denormalized for the phone list |
| `originKind` | String | for the AI audit on device |

**`VGReviewEvent`** — recordName = `event-<uuid>` (the event's own UUID → **idempotent by construction**)
| `eventID`, `projectID`, `paragraphID`, `type`, `noteText`, `tag`, `device`, `createdAt` |

Subscriptions: one `CKDatabaseSubscription` on the zone per device, with silent push (`shouldSendContentAvailable = true`). The Mac subscribes to receive events; the phone subscribes to receive projection updates. The app already has `remote-notification` in `UIBackgroundModes`.

### 13.3 Projection building

```swift
public struct ProjectionBuilder: Sendable {
    public func projection(from project: AudiobookProject, counts: ProjectCounts, revision: Int) -> SyncProjection
}

public struct SyncProjection: Sendable, Equatable {
    public var project: ProjectSummary
    public var chapters: [ChapterProjection]
    public var paragraphs: [ParagraphProjection]
    public var revision: Int
    public var narrationOrigin: NarrationOrigin
}
public struct ParagraphProjection: Sendable, Equatable {
    public var id: UUID; public var chapterID: UUID; public var ordinal: Int; public var globalOrdinal: Int
    public var text: String?; public var reviewState: ReviewState
    public var takeID: UUID?; public var duration: TimeInterval
    public var proxySourceSHA: String?          // sha of the selected take's asset
    public var latestNote: (text: String, tag: ReviewTag?)?
    public var originKind: String
}
```

Rules (asserted by `ProjectionBuilderTests`):

1. **Only paragraphs with a selected take are projected with audio.** Unrecorded paragraphs appear (so the phone can show progress and paragraph lists) but with `takeID == nil` and no asset.
2. **Only the selected take is projected.** Alternate takes never leave the Mac.
3. An **AI-origin unselected** take must not affect anything projected; an AI-origin *selected* take sets `originKind` and contributes to `narrationOrigin`.
4. Hidden projects (`isHiddenFromDevices`) are **not** projected; if a projection already exists, publishing withdraws it (delete records, keep a tombstone `VGProductionProject` with `isHidden = 1` until the consumer acknowledges by fetching it, then delete).
5. Text is included only when `includeSourceTextInProjection` is true. For a commercial project under NDA, a user may want audio-only review.

### 13.4 Proxy generation

- Proxies are AAC mono at `proxyBitrateKbps` (default 80) in `.m4a`, generated by AVFoundation (no third-party encoder needed).
- Proxy source is the take's **trimmed** audio, i.e. what the reviewer would hear, so review timecodes map to the same positions the Mac shows.
- Cached in `proxy_cache` keyed by `(takeID, bitrate)`; regenerated only when the take's asset hash or the bitrate changes.
- Estimated total is shown in Device Preview ("Full project estimate: 412 MB"). At 80 kbps, 1 hour ≈ 36 MB; a 10-hour book ≈ 360 MB.
- If the estimate exceeds a threshold (default 1 GB), the publish action warns and offers 48 kbps or "flagged-only projection".

### 13.5 Publish policy

```swift
public actor ProjectionPublisher {
    public func publishIfNeeded(reason: PublishReason) async throws -> PublishOutcome
}
public enum PublishReason: Sendable { case takeSelected, reviewStateChanged, metadataChanged, manual, appBackgrounded, periodic }
```

- **Debounce**: coalesce triggers into a publish no more often than every 20 seconds, except `manual` (immediate) and `appBackgrounded` (immediate flush).
- **Delta only**: compare against the last published projection snapshot (stored as JSON in `sync_state`), and modify only changed records. A single re-recorded paragraph must produce one record modification plus one asset upload, not a full republish. This is the difference between a usable and an unusable feature on a 3,000-paragraph book.
- `revision` increments on every successful publish.
- Batch `CKModifyRecordsOperation` at ≤ 100 records / ≤ 20 assets per operation with `.ifServerRecordUnchanged` policy; on `serverRecordChanged`, take the server record's change tag and retry once (the Mac is the only writer, so this is nearly always a duplicate-publish race with itself).
- On `.quotaExceeded`, stop, surface a specific message with the storage estimate and the "Hide Project from Devices" action.
- On `.notAuthenticated`, surface "Sign in to iCloud to preview on your devices" and keep every local feature working.

### 13.6 Watch relay (`WatchTransport`)

```swift
public protocol WatchTransport: Sendable {
    var isReachable: Bool { get }
    var activationState: WatchLinkState { get }
    func sendSummaries(_ summaries: [ProjectSummary]) async throws
    func sendActiveQueue(_ payload: ResolvedQueuePayload) async throws
    func sendAudio(_ items: [WatchAudioItem]) async throws          // file transfers
    func sendArtwork(_ artwork: [UUID: Data]) async throws
    func receiveEvents() -> AsyncStream<ReviewEvent>
    func requestRefresh() async throws
}

public struct ResolvedQueuePayload: Codable, Sendable, Equatable {
    public var projectID: UUID
    public var projectTitle: String
    public var queueLabel: String                    // "Flagged"
    public var paragraphIDs: [UUID]
    public var texts: [UUID: String]
    public var notes: [UUID: String]
    public var durations: [UUID: TimeInterval]
    public var chapterLabels: [UUID: String]         // "Chapter 4 · ¶ 218"
    public var tags: [UUID: ReviewTag]
    public var autoAdvance: Bool
    public var revision: Int
}
public struct WatchAudioItem: Codable, Sendable, Equatable {
    public var paragraphID: UUID
    public var sha256: String
    public var byteCount: Int
    public var fileURL: URL?        // set on the sending side only
}
```

Transport mapping (WatchConnectivity):

| Payload | Mechanism | Why |
|---|---|---|
| `summaries`, `activeQueue` metadata | `updateApplicationContext` | small, latest-wins, survives sleep |
| audio files | `transferFile` | large, queued, background, resumable |
| artwork | `transferFile` (one per project) | cacheable |
| events (watch → phone) | `transferUserInfo` | guaranteed delivery, FIFO, survives unreachability |
| "refresh now" | `sendMessage` when reachable, else fall back to `transferUserInfo` | interactive |

Watch-side rules:

1. **No CloudKit.** CI gate G-5 greps the watch target for `import CloudKit`.
2. **Prefetch discipline:** the watch downloads audio for the **current and next** queue item eagerly, and the rest lazily unless "Prepare Offline Queue" was used, in which case all items are transferred before the queue is marked "Downloaded 18 of 18" (mockup `10-offline-queue`).
3. **Offline events** accumulate in a local file-backed outbox and are transferred when the phone becomes reachable. The watch UI shows "Pending actions 2" (mockup `09-watch-sync-status`).
4. **Storage cap:** the watch keeps at most 200 MB of production audio and evicts by least-recently-queued.
5. When no audio is available and the phone is unreachable, the review player shows an explicit offline state (mockup requirement) — it must never spin forever.

### 13.7 Event ingestion and error recovery on the Mac

```swift
public actor EventIngestor {
    public func pump() async throws -> IngestReport   // fetch → dedupe → append → fold → maybe republish
}
```

Sequence: fetch changes with the stored change token → decode `VGReviewEvent` records → `ProductionStore.appendEvents` (idempotent by event id, `INSERT OR IGNORE`) → fold (§14.3) → mark applied → delete consumed event records from CloudKit (they are a queue, not a log of record) → publish if any review state changed.

**Stale change token.** When CloudKit returns `.changeTokenExpired`, the engine MUST discard the token, refetch the zone from scratch, and continue — never surface an error, never lose events. There MUST be a regression test (`SyncTokenRecoveryTests`) that injects `changeTokenExpired` on the first fetch and asserts a successful full refetch on the second. (This mirrors a defect already fixed once in this repository's consumer sync engine; do not regress it in the production engine.)

**Retry policy.** Exponential backoff 2 s → 4 s → 8 s → 30 s → 120 s, capped, with jitter. `CKError.retryAfterSeconds` always wins when present.

**Conflict policy.** Review events never conflict (append-only, unique IDs). Projection records are single-writer. The only real conflict is two Macs publishing the same project (rare, and prevented by the package lock in §8.3) — resolved last-writer-wins on `revision`.

### 13.8 The Device Preview screen contract

Mockup `12-device-preview` requires: sync status with revision number, per-device state (iPhone connected through iCloud; Watch relayed by iPhone), "Automatically sync accepted takes" toggle, "Include source text" toggle, "Hide Project from Devices", the watch queue size and "Prepare Offline Queue", the storage profile with the proxy bitrate and estimates, and pending feedback counts with a jump into the review queue.

All of those map 1:1 to fields already specified. The only nontrivial one is **"Prepare Offline Queue"**, which on the Mac side means: resolve the flagged queue → ensure proxies exist for every item → mark those paragraphs as `watchPinned` in the projection so the phone transfers them all to the watch. Add `watchPinnedParagraphIDs: [UUID]` to `SyncProjection` and the project record (`pinnedIDs` as a String list).

---

## 14. The review system

### 14.1 Events

```swift
public struct ReviewEvent: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID                  // idempotency key; generated at the originating device
    public var projectID: UUID
    public var paragraphID: UUID
    public var type: ReviewEventType
    public var noteText: String?
    public var tag: ReviewTag?
    public var device: DeviceKind
    public var createdAt: Date
}
public enum ReviewEventType: String, Codable, Sendable {
    case flag, unflag, approve, needsPickup, clearPickup, addNote, voiceNoteRequested, resolveNote
}
```

**Every** user action that changes review state — on any device, including the Mac — is expressed as an event. The Mac does not mutate `paragraph.review_state` directly. This gives one code path, one conflict policy, and a complete audit trail for free.

### 14.2 The fold

```swift
public struct ReviewState_Fold: Sendable {   // named ReviewEventFolder in code
    public func fold(_ events: [ReviewEvent], into current: [UUID: ReviewState]) -> FoldResult
}
public struct FoldResult: Sendable {
    public var states: [UUID: ReviewState]
    public var notesToInsert: [ReviewNote]
    public var changedParagraphIDs: Set<UUID>
}
```

Normative fold semantics:

1. Events are sorted by `(createdAt, id)`. `id` breaks ties deterministically so two devices folding the same set produce the same result.
2. State transitions:
   - `.flag` → `.flagged`
   - `.unflag` → `.unreviewed` (only if currently `.flagged`; otherwise no-op)
   - `.approve` → `.approved`
   - `.needsPickup` → `.needsPickup`
   - `.clearPickup` → `.unreviewed` (only if currently `.needsPickup`)
   - `.addNote` → inserts a note; **also sets `.flagged` if the paragraph is currently `.unreviewed`** (adding a note means something is wrong)
   - `.voiceNoteRequested` → inserts a placeholder note with text `"(voice note — complete on iPhone)"`, tag preserved, and sets `.flagged`
   - `.resolveNote` → marks the referenced note resolved; does not change state
3. **Last writer wins by timestamp**, but with one exception: `.needsPickup` is *sticky against `.approve`* within a 60-second window from different devices. Rationale: a driver taps Approve and then immediately realizes it needs a pickup; clock skew between devices should not silently drop the more conservative action. Implement as: when two events for the same paragraph are within 60 s and one is `.needsPickup`, `.needsPickup` wins regardless of order.
4. The fold is **idempotent**: folding the same event twice yields the same state (guaranteed by unique `id` plus `INSERT OR IGNORE`).
5. Folding is pure and lives in Core; the store applies the result in one transaction.

`ReviewEventFoldTests` asserts: idempotency, deterministic ordering under equal timestamps, the pickup-stickiness rule, note-implies-flag, and that unknown future event types (decoded from a newer client) are ignored rather than throwing.

### 14.3 Queues

```swift
public enum ReviewPredicate: Codable, Sendable, Equatable {
    case allRecorded
    case flagged
    case needsPickup
    case unapproved                 // recorded && state != .approved
    case unreviewed
    case selectedParagraphs(Set<UUID>)
    case chapter(UUID)
    case tag(ReviewTag)
}
public enum QueueOrder: String, Codable, Sendable { case documentOrder, byChapter, flaggedFirst, shortestFirst }

public struct ReviewQueueDefinition: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var projectID: UUID
    public var chapterIDs: Set<UUID>?
    public var predicate: ReviewPredicate
    public var order: QueueOrder
    public var autoAdvance: Bool
    public var skipApprovedImmediately: Bool
    public var playContextSecond: Bool
}

public struct ReviewQueueResolver: Sendable {
    public func resolve(_ def: ReviewQueueDefinition, in project: AudiobookProject) -> [UUID]
    public func sql(for def: ReviewQueueDefinition) -> (String, [DatabaseValue])   // store-backed fast path
}
```

Both a pure in-memory resolver (for tests and for the phone's projection) and a SQL form (for the Mac's large projects) must exist and MUST agree. `ReviewQueueResolverTests` asserts equality of the two for every predicate × order combination on a shared fixture.

> **§14.3 implementation note.** `ReviewQueueResolver.sql(for:)` is implemented
> as `ProductionStore.paragraphIDs(matching:order:)` rather than a free
> function, so the Mac's store-backed fast path lives with the store (where the
> SQL bindings already are). The "both forms MUST agree" requirement is
> unchanged and is asserted by `ProductionStoreTests` alongside
> `ReviewQueueResolverTests`.

`documentOrder` = ascending `globalOrdinal`. `flaggedFirst` = flagged before needsPickup before unapproved, each in document order. `shortestFirst` = ascending duration (useful for clearing a backlog quickly).

### 14.4 Live queue mutation

A queue is resolved once at start and then **held stable** for the session, with two exceptions:

- Items whose state changes to a state excluded by the predicate are marked *done* in place (they remain in the list, greyed) rather than vanishing. Vanishing items under a driver's thumb is a safety problem and a UX one.
- "Refresh queue" re-resolves explicitly.

The player advances to the next *not-done* item.

### 14.5 Cross-device flows (normative walkthroughs)

**Flow A — flag on the watch, fix on the Mac.**
1. Watch: user taps ⚑ on ¶ 218. `ReviewEvent(.flag, device: .watch)` written to the watch outbox; haptic; confirmation view (mockup `06`).
2. Watch → phone via `transferUserInfo` (queued if unreachable).
3. Phone appends to its local outbox and pushes `VGReviewEvent` to CloudKit.
4. Mac's subscription fires → `EventIngestor.pump()` → event appended → fold sets `.flagged` → Mac republishes (revision++).
5. Mac's Review tab badge increments; the paragraph appears in the flagged queue.
6. Narrator re-records; new take selected; `needsPickup` cleared by an explicit `.clearPickup` event from the Mac.
7. Republish → phone and watch see the updated state and the new proxy audio.

**Flow B — dictated note on the watch.**
1. Watch: long-press or "Add Dictated Note" → category picker (6 tags) → `WKInterfaceController` dictation → result screen → Save.
2. Emits `.addNote` with `noteText` and `tag`. Same path as Flow A.
3. Mac shows the note text on the paragraph inspector and in the review queue ("Watch note: 'Pronounce Poirot more softly' · ¶ 218" on the library activity feed).

**Flow C — CarPlay approve while driving.**
1. CarPlay now-playing custom button "Approve" → `.approve` event, spoken confirmation if enabled, auto-advance to the next queue item.
2. Event goes straight to the phone's outbox (CarPlay runs in the phone's process).
3. Undo is available for 10 seconds via the confirmation template (mockup `06-voice-action-confirmation`), implemented as an `.unflag`-style compensating event **only if** the original event has not yet been pushed; after push, undo emits a new compensating event (`.flag` restoring the prior state) rather than deleting.

**Flow D — offline everything.**
1. Phone in airplane mode: events accumulate in the outbox with real timestamps.
2. On reconnect, all are pushed. The fold on the Mac applies them in timestamp order, so a sequence of flag → note → approve on one paragraph yields `.approved` with the note attached.
3. `OfflineEventQueueTests` asserts exactly this sequence produces one final state and no duplicate notes when the push is retried.

### 14.6 Notes

- A note always belongs to a paragraph and optionally carries a timecode within it (mockup shows `Chapter 4 · Paragraph 218 · 00:03.4`).
- Notes are never edited after creation on a device other than the one that made them; the Mac may resolve them.
- The six tags are fixed (§5.5).
- Voice notes: the watch and CarPlay may emit `.voiceNoteRequested`; **no audio is recorded for notes in MVP** on those devices (watch dictation produces text; CarPlay produces a marker). Recording note audio is DEFERRED.
---

## 15. The validation engine

### 15.1 Shape

```swift
public struct ValidationRuleEngine: Sendable {
    /// PURE. Inputs → issues. No I/O, no file access, no clock.
    public func evaluate(project: AudiobookProject,
                         metrics: [UUID: AudioQualityMetrics],     // keyed by TAKE id
                         profile: DestinationProfile,
                         eligibility: EligibilityProfile,
                         assembly: AssemblySettings) -> [ValidationIssue]
}

public struct ValidationIssue: Sendable, Identifiable, Equatable, Codable {
    public let id: UUID                  // deterministic: UUIDv5-style hash of (code, chapterID, paragraphID)
    public var severity: Severity        // .blocking | .warning | .passed
    public var code: IssueCode
    public var title: String             // "Missing accepted take"
    public var message: String           // "Chapter 7, paragraph 44 has no selected audio."
    public var chapterID: UUID?
    public var paragraphID: UUID?
    public var takeID: UUID?
    public var measured: Double?         // e.g. -16.2
    public var expected: String?         // e.g. "-23 to -18 dBFS"
    public var fix: FixAction?
}

public enum Severity: String, Sendable, Codable, Comparable { case passed, warning, blocking }

public struct ValidationReport: Sendable, Codable, Equatable {
    public var destination: DestinationID
    public var generatedAt: Date
    public var projectID: UUID
    public var projectTitle: String
    public var issues: [ValidationIssue]
    public var eligibility: EligibilityProfile
    public var summary: ValidationSummary
    public var analyzerVersion: Int
    public var appVersion: String
}
public struct ValidationSummary: Sendable, Codable, Equatable {
    public var blocking: Int; public var warnings: Int; public var passed: Int
    public var totalParagraphs: Int; public var recordedParagraphs: Int
    public var totalDuration: TimeInterval
    public var chaptersOverMaxDuration: Int
}
```

**Issue IDs must be deterministic** so that re-running validation does not reshuffle the list and so a fixed issue can be diffed away. Compute as `SHA256Hex.hex(joining: [code.rawValue, chapterID?.uuidString ?? "-", paragraphID?.uuidString ?? "-"])` truncated into a UUID.

### 15.2 Fix actions

```swift
public enum FixAction: Sendable, Equatable, Codable {
    case goToParagraph(UUID)
    case goToChapter(UUID)
    case openMetadata(field: MetadataField)
    case openRights
    case recordParagraph(UUID)
    case selectTake(paragraphID: UUID, takeID: UUID)
    case regenerateDisclaimers
    case regenerateCredits
    case applyMastering                    // Pro
    case splitChapter(UUID, atParagraph: UUID)
    case chooseArtwork
    case setRetailSample
    case reanalyzeTake(UUID)
    case clearPickup(UUID)
}
```

Every issue with a mechanical remedy MUST carry a `FixAction`. The Validation screen's "Fix Next Issue" button (mockup `13`) walks blocking issues in document order and performs/navigates the action.

### 15.3 The complete rule catalogue

Rules are grouped. Each row: code, severity by target, and the exact condition. `L` = LibriVox, `IA` = Internet Archive, `R` = retail family (ACX / Apple/aggregator), `P` = personal master. `B` = blocking, `W` = warning, `–` = not evaluated.

**Group 1 — Metadata and rights**

| Code | L | IA | R | P | Condition |
|---|---|---|---|---|---|
| `missingTitle` | B | B | B | W | `metadata.title` trimmed empty |
| `missingAuthor` | B | B | B | – | empty |
| `missingNarrator` | B | B | B | – | empty |
| `missingLanguage` | B | B | B | – | empty or not a valid BCP-47 tag |
| `missingDescription` | W | W | B | – | empty (retail listings require it) |
| `missingSourceURL` | B | W | – | – | `rights.sourceURL == nil` |
| `missingRightsBasis` | B | B | B | – | – (basis is non-optional, but `personalUseOnly` for a public destination is an issue) |
| `personalRightsForPublicTarget` | B | B | B | – | `rights.basis == .personalUseOnly` |
| `unattestedRights` | B | B | B | – | `rights.attestedAt == nil` |
| `missingCoverArt` | W | W | B | – | `metadata.coverRef == nil` |
| `artworkTooSmall` | – | W | B | – | cover shorter side < profile minPx |
| `artworkNotSquare` | – | W | B | – | aspect ratio outside 1.0 ± 0.01 |
| `missingCopyrightYear` | – | W | B | – | retail: `copyrightYear == nil` |
| `missingPublisher` | – | – | W | – | retail: `publisher == nil` |
| `missingArchiveIdentifier` | – | B | – | – | IA: `archiveIdentifier == nil` |
| `invalidArchiveIdentifier` | – | B | – | – | fails the identifier charset/length rule |

**Group 2 — Narration origin and eligibility**

| Code | L | IA | R | P | Condition |
|---|---|---|---|---|---|
| `aiOriginInLibriVoxProject` | **B** | – | – | – | `eligibility.librivoxEligible == false` |
| `unknownOriginTakeSelected` | B | W | W | – | any selected take with `.unknownImport` |
| `undisclosedAINarration` | – | B | B | – | `narrationOrigin == .containsImportedAI` and the AI disclosure line is absent from the manifest/metadata |

**Group 3 — Completeness and structure**

| Code | L | IA | R | P | Condition |
|---|---|---|---|---|---|
| `missingAcceptedTake` | B | B | B | W | a `body`/`chapterHeading` paragraph with `selectedTakeID == nil` |
| `unresolvedNeedsPickup` | B | B | B | W | any paragraph in `.needsPickup` |
| `unapprovedParagraphs` | W | W | W | – | count of recorded-but-not-approved > 0 (informational; never blocking — approval is the narrator's discipline, not the platform's rule) |
| `textChangedAfterRecording` | B | W | B | W | drift `.semantic` on a selected take |
| `textChangedCosmetically` | W | – | W | – | drift `.minor` |
| `emptyChapter` | B | B | B | W | a chapter with zero paragraphs |
| `duplicateOrdinal` / `missingOrdinal` | B | B | B | B | from `ProjectIntegrity` |
| `assetMissing` / `assetHashMismatch` | B | B | B | B | from `ProjectIntegrity` deep check |
| `missingDisclaimerParagraph` | B | – | – | – | §10.5 |
| `unrecordedDisclaimer` | B | – | – | – | §10.5 |
| `staleDisclaimerText` | B | – | – | – | §10.5 |
| `missingOpeningCredits` / `missingClosingCredits` | – | – | B | – | §10.5 |
| `missingRetailSample` | – | – | B | – | retail sample not configured |
| `retailSampleTooShort` / `retailSampleTooLong` | – | – | B | – | outside [60 s, 300 s] |
| `retailSampleStartsInCredits` | – | – | B | – | sample start paragraph role is a credits role |
| `chapterTooLong` | W | – | B | – | rendered chapter duration > `profile.maxFileDuration` |
| `chapterVeryLong` | W | W | W | – | > 60 min where no hard cap applies |

**Group 4 — Audio quality (per selected take, aggregated per chapter for file-level rules)**

| Code | L | IA | R | P | Condition |
|---|---|---|---|---|---|
| `clipping` | B | W | B | W | `clipCount > 0` |
| `peakTooHot` | W | W | B | W | `truePeakDBFS > profile.peakCeilingDBFS` |
| `peakTooLow` | W | – | W | – | `peakDBFS < -24` (suspiciously quiet capture) |
| `rmsOutOfRange` | – | – | B | – | chapter RMS outside `[minDBFS, maxDBFS]` |
| `noiseFloorTooHigh` | W | W | B | W | `noiseFloorDBFS > profile.noiseFloorCeilingDBFS` |
| `noiseFloorUnreliable` | W | W | W | W | `noiseFloorReliable == false` (not enough silence to measure) |
| `dcOffset` | W | W | W | W | `abs(dcOffset) > 0.002` |
| `sampleRateMismatch` | W | – | W | – | take sample rate differs from other takes in the project |
| `channelInconsistency` | B | W | B | W | takes with differing channel counts |
| `stereoWhereMonoExpected` | W | – | W | – | channels == 2 and profile wants mono |
| `bitDepthMismatch` | – | W | – | W | mixed bit depths among originals |
| `loudnessDiscontinuity` | W | W | W | W | a paragraph's RMS differs from the median of its 4 neighbors by > 4 dB (mockup: "approximately 4.8 dB louder than adjacent paragraphs") |
| `durationOutlier` | W | W | W | – | take duration deviates from `estimatedDuration(text)` by > 60 % in either direction (catches truncated or wrong-paragraph takes) |
| `suspectedTruncation` | W | W | B | W | first 40 ms or last 40 ms of the trimmed take is above −35 dBFS (speech starts/ends abruptly at the file edge) |
| `excessiveLeadingSilence` | W | – | W | – | trimmed leading silence > 2 s |
| `headRoomToneOutOfRange` | – | – | W | – | head silence outside `[headMin, headMax]` after assembly |
| `tailRoomToneOutOfRange` | – | – | W | – | tail silence outside `[tailMin, tailMax]` after assembly |
| `missingMetrics` | W | W | B | W | selected take has no metrics or a stale `analyzerVersion` |

**Group 5 — Loudness for LibriVox (§3.2.1)**

| Code | L | Condition |
|---|---|---|
| `perceivedVolumeOutOfBand` | W | `89 - replayGainDB` outside `[86, 92]` |

This is a warning, never blocking, because the mapping from ReplayGain to LibriVox's checker is approximate (§3.2.1). The message MUST say so: *"Estimated perceived volume is 84 dB (LibriVox prefers 86–92 dB). This is an estimate; the LibriVox checker is authoritative."*

### 15.4 Evaluation order and cost

1. Cheap project-level rules (metadata, rights, eligibility) — always.
2. Structural rules — always; require only the project graph.
3. Audio rules — require metrics for every selected take. If metrics are missing, emit `missingMetrics` **instead of** silently passing.
4. Assembly-derived rules (chapter duration, room tone) — require an assembly pass but not a render: durations are the sum of trimmed take durations plus configured gaps.

A full validation of a 3,000-paragraph project must complete in **under 2 seconds** with metrics already computed (performance budget §19.7). Achieve this by evaluating in one pass over paragraphs with precomputed neighbor windows for `loudnessDiscontinuity`.

### 15.5 The report

```swift
public struct ValidationReportRenderer: Sendable {
    public func json(_ report: ValidationReport) throws -> Data
    public func html(_ report: ValidationReport) -> String      // self-contained, no external assets
    public func plainText(_ report: ValidationReport) -> String // for the submission checklist
}
```

- The **screen** version (mockup `13-validation-report`) groups by severity with counts in the sidebar (All / Blocking / Warnings / Passed), shows target selection, an Eligibility panel, and per-issue "Go to Paragraph" / "Compare Text" actions.
- Exporting the report to disk is `ProFeature.validationReportExport`. Viewing it is free.
- The HTML report is single-file, printable, includes the project title, destination, generation timestamp, app version, analyzer version, and a table of every issue with its measured/expected values. It MUST NOT include paragraph text beyond a 90-character snippet (NDA safety).

### 15.6 Loudness rule details

The retail RMS rule is evaluated **per delivered file** (i.e. per chapter after assembly), not per paragraph, because that is what ACX measures. Compute the chapter RMS as the energy-weighted combination of its segments:

```
chapterRMS = sqrt( Σ (rms_i^2 × dur_i) / Σ dur_i )   over non-silence-normalized segment audio
```

Silence inserted between paragraphs is **excluded** from the RMS computation (it would drag the value down and misrepresent the speech level), but is included in `duration`. Document this in the code, because a naive whole-file RMS gives a different answer than ACX's tooling and will produce false failures.

`peakTooHot` uses `truePeakDBFS`, `noiseFloorTooHigh` uses the chapter's minimum-reliable noise floor across segments (worst case wins).

### 15.7 Free-tier honesty

The rule engine runs for **every** destination regardless of entitlement. A free user selecting "Professional Retail Master" in the Validation screen's target picker sees the full ACX rule evaluation, including exactly which paragraphs are too hot and which need re-recording. Only the *export* is gated. This is a deliberate product decision: it demonstrates the value of Pro without withholding information, and it means a narrator can fix their room and their technique before spending anything.
---

## 16. Packaging and export

This is the section that makes Voxglass a *distribution* tool rather than a recorder. It is also the section with the single largest engineering item in the MVP: the encoder.

### 16.1 The export pipeline

```
Validate (target) ──▶ [blocking issues? stop] ──▶ Gate (Pro?) ──▶ Assemble chapter render plans
   ──▶ Render lossless chapter masters (cache) ──▶ Master (Pro targets only)
   ──▶ Transcode to destination format ──▶ Tag ──▶ Name ──▶ Write package artifacts
   ──▶ Checksums ──▶ Checklist ──▶ Report
```

Each arrow is a cancellable, resumable step. An interrupted export leaves a partially populated `Exports/<Destination>/<slug>.partial/` directory and an `export_run` row with status `running`; resuming skips files whose checksum already matches.

```swift
public protocol PackageBuilder: Sendable {
    var destination: DestinationID { get }
    func build(project: AudiobookProject,
               renders: any ChapterRendering,
               transcoder: any AudioTranscoding,
               assets: any ContentAddressedStore,
               into exportsRoot: URL,
               options: ExportOptions,
               progress: @Sendable (ExportProgress) -> Void) async throws -> ExportBundle
}

public struct ExportOptions: Sendable {
    public var includeMP3Derivatives: Bool          // IA
    public var useTestCollection: Bool              // IA
    public var applyMastering: Bool                 // retail (Pro)
    public var m4bBitrateKbps: Int
    public var retailSample: RetailSampleSelection?
    public var overwriteExisting: Bool
    public var writeValidationReport: Bool          // Pro
}

public struct ExportBundle: Sendable {
    public var destination: DestinationID
    public var rootURL: URL
    public var files: [ExportedFile]
    public var checklistURL: URL
    public var manifestURL: URL?
    public var checksumURL: URL?
    public var reportURL: URL?
    public var totalBytes: Int64
    public var totalDuration: TimeInterval
    public var warnings: [String]
}

public struct ExportedFile: Sendable, Equatable {
    public var url: URL
    public var role: ExportedFileRole      // chapter | sample | cover | manifest | checksum | checklist | report | master
    public var chapterID: UUID?
    public var duration: TimeInterval?
    public var byteCount: Int64
    public var sha256: String
}
```

### 16.2 `AudioTranscoding`

```swift
public protocol AudioTranscoding: Sendable {
    var availableEncoders: Set<Codec> { get }
    func transcode(input: URL, to spec: AudioSpec, tags: AudioTags, output: URL,
                   progress: @Sendable (Double) -> Void) async throws -> ExportedFile
    func concatenate(_ inputs: [URL], to spec: AudioSpec, chapters: [ChapterMark]?,
                     tags: AudioTags, output: URL) async throws -> ExportedFile
}
public struct ChapterMark: Sendable, Equatable { public var title: String; public var start: TimeInterval }
```

### 16.3 The encoder decision (correction C-3, in full)

**Requirement.** MP3 CBR at 128 and 192 kbps, and FLAC. AVFoundation on macOS **decodes** MP3 and FLAC but **encodes** neither. AAC/ALAC/PCM encoding is available through AVFoundation and needs no third party.

**Licensing constraint.** Voxglass is GPLv3 with a hand-written App Store additional permission covering *this repository's* code. That permission cannot extend to third-party GPL code. Therefore:

- **Do not** ship a GPL-configured ffmpeg binary (`--enable-gpl`) in an App Store build.
- **Do** use LGPL/BSD components: **libmp3lame** (LGPL-2.1) for MP3, **libFLAC** (BSD-3-Clause) for FLAC.
- Under LGPL, dynamic linking with a mechanism for the user to substitute a modified library is the safe pattern. Ship them as **embedded dynamic frameworks** in `Contents/Frameworks/`, signed with the app's identity, and publish the exact build recipe plus sources.

**Recommended implementation (primary path):**

1. Build `libmp3lame` and `libFLAC` as xcframeworks for `arm64` + `x86_64` macOS, minimum 14.0, with a documented, scripted recipe checked into `Tools/encoders/build-encoders.sh`.
2. Write two thin Swift wrappers over their C APIs:
   - `LameMP3Encoder` — `lame_init`, `lame_set_num_channels/in_samplerate/brate`, `lame_set_VBR(vbr_off)` for CBR, `lame_set_quality(2)`, `lame_encode_buffer_ieee_float`, `lame_encode_flush`, then `lame_mp3_tags_fid` for the Xing/LAME header. **CBR requires `vbr_off`** — this is the exact setting the destinations care about.
   - `FLACEncoder` — `FLAC__stream_encoder_new`, set channels/bps/sample rate/compression level 5, `FLAC__stream_encoder_process_interleaved`, `finish`.
3. `VoxTranscoder` composes: AVFoundation for decode and for AAC/ALAC/PCM encode; `LameMP3Encoder` for MP3; `FLACEncoder` for FLAC.
4. `availableEncoders` reports what actually loaded, and the Export wizard disables destinations whose codec is unavailable with a specific message rather than failing mid-export.

**Fallback path (if the framework build is deferred to a later stage):** an `FFmpegProcessTranscoder` that invokes a bundled **LGPL-configured** ffmpeg (`--disable-gpl --disable-nonfree --enable-libmp3lame --enable-libvorbis` etc.) from `Contents/Helpers/`. Requirements if this path is used:
- Signed with the app's team ID and the hardened runtime; `Contents/Helpers/` is inside the app bundle so it inherits the sandbox.
- Invoked with absolute paths, no shell, `Process` with explicit `arguments`, `standardError` captured for `TranscodeError.encoderFailed(status:stderr:)`.
- Exact invocations:
  - MP3 CBR 128 mono 44.1k: `-i in.caf -vn -ac 1 -ar 44100 -c:a libmp3lame -b:a 128k -abr 0 -write_xing 1 out.mp3` (verify CBR by inspecting the resulting frame headers in a test).
  - MP3 CBR 192: same with `-b:a 192k`.
  - FLAC: `-i in.caf -c:a flac -compression_level 5 out.flac`.
- **Sandbox note:** spawning a helper from an App Sandbox app is permitted for binaries inside the app bundle. Do **not** rely on `/usr/local/bin/ffmpeg`; never invoke a user-installed binary.

**Verification tests (required either way):**
- `TranscoderCBRTests` — encode 10 s of tone to MP3 at 128 kbps and parse the MPEG frame headers, asserting every frame reports the same bitrate index (true CBR) and 44.1 kHz, mono.
- `TranscoderFLACTests` — encode and decode round-trip, assert bit-exact PCM.
- `TranscoderAvailabilityTests` — with encoders unavailable, `availableEncoders` excludes them and the LibriVox builder throws `TranscodeError.encoderUnavailable("mp3")` **before** writing any file.

**Third-party notices.** Add `Voxglass/Resources/ThirdPartyNotices.md` listing LAME (LGPL-2.1) and FLAC (BSD-3) with copyright notices, the build recipe location, and the written offer for the corresponding sources. Surface it in Settings → About. This is a licensing obligation, not a nicety.

### 16.4 `LibriVoxPackageBuilder`

**Preconditions (all enforced before any file is written):**
1. `EligibilityProfile.evaluate(project).librivoxEligible == true` — else `PackagingError.ineligible(.librivox, reason: legal.librivoxHumanOnly)`. *(Grep gate G-6 requires this call to appear in this file.)*
2. Validation for `.librivox` has zero blocking issues.
3. `availableEncoders.contains(.mp3)`.

**Output:**

```
Exports/LibriVox/<projectslug>/
  <shorttitle>_01_<authorlastname>.mp3
  <shorttitle>_02_<authorlastname>.mp3
  ...
  section-durations.txt
  librivox-checklist.md
  metadata.json
  <projectslug>-cover.jpg              (if present)
  checksums.sha256
```

**Per file:** render chapter master (lossless) → transcode to 44.1 kHz mono 128 kbps CBR MP3 → write ID3v2.4 tags (§16.6) → name by `FilenameSanitizer` (§16.5) → hash.

**`section-durations.txt`:**

```
alicewonderland_01_carroll.mp3    12:41
alicewonderland_02_carroll.mp3    15:03
...
TOTAL                             4:12:55
```

**`librivox-checklist.md`** (generated; this is the artifact that saves the user a rejection round-trip):

```markdown
# LibriVox submission checklist — {Title} by {Author}

Prepared by Voxglass Studio {version} on {date}. **You submit these files yourself. Voxglass never uploads on your behalf.**

## Technical
- [x] 128 kbps constant bit rate MP3 — verified on all {N} files
- [x] 44.1 kHz, mono — verified
- [ ] Perceived volume 86–92 dB — Voxglass estimates {min}–{max} dB (estimate only; the LibriVox checker is authoritative)
- [x] No clipping detected
- [x] ID3 tags written (title, artist, album, track, year, genre)

## Content
- [x] LibriVox disclaimer recorded in all {N} sections
- [x] Closing line recorded in all sections
- [x] Final section ends with "End of {Title}, by {Author}."
- [ ] Filenames match your project's first-post template — Voxglass used `{template}`; confirm it matches your project thread

## Rights
- Basis: {rights basis}
- Source: {source URL}
- Edition: {year}
- Attested by {name} on {date}

## Narration origin
- {H} human-narrated paragraphs, {A} AI-origin paragraphs
- LibriVox does not accept machine-generated audio. This project is {eligible / NOT eligible}.

## Sections
| # | File | Duration |
|---|------|----------|
...

**Voxglass does not determine copyright status.**
```

### 16.5 Filenames and identifiers

```swift
public struct FilenameSanitizer: Sendable {
    public func sanitize(_ raw: String, rule: FilenameRule) -> String
    public func librivoxFilename(shortTitle: String, section: Int, sectionCount: Int, authorLastName: String) -> String
    public func archiveFilename(identifier: String, section: Int, sectionCount: Int, chapterTitle: String, ext: String) -> String
    public func freeformNumbered(section: Int, sectionCount: Int, chapterTitle: String, ext: String) -> String
}
```

`librivoxLowercaseNoSpace` algorithm (exhaustively tested):

1. Unicode-decompose and strip combining marks (`é` → `e`, `ß` → `ss` via a small explicit map).
2. Lowercase.
3. Replace any run of characters outside `[a-z0-9]` with a single `_`.
4. Trim leading/trailing `_`.
5. Collapse repeated `_`.
6. Truncate `shortTitle` to 24 characters at a `_` boundary where possible.
7. Compose `\(shortTitle)_\(zeroPadded(section, width: digits(sectionCount)))_\(authorLastName)`.
8. Reject (assert in tests) any result matching `[^a-z0-9_]` or exceeding 100 characters.

Test table MUST include: `"The Murder of Roger Ackroyd"` → `themurderofrogerackroyd`; `"Émile Zola"` → `emile_zola`; `"L'Assommoir"` → `l_assommoir`; a 200-character title; a title of only punctuation (→ fallback `"book"`); CJK title (→ transliteration is out of scope; fall back to `book_NN_author` and emit a warning issue); section 7 of 9 → `07`? **No** — width follows `digits(sectionCount)`, so 7 of 9 → `7`… **decision: always minimum width 2** (`07`), because LibriVox templates conventionally use two digits, expanding to three at 100+.

`IdentifierSuggester` for the Internet Archive:

```swift
public struct IdentifierSuggester: Sendable {
    public func suggest(title: String, author: String, narrator: String, year: Int?) -> String
    public func isValid(_ id: String) -> Bool     // ^[A-Za-z0-9][A-Za-z0-9._-]{4,79}$
}
```

Suggested form: `<titleslug>_<authorlastname>_<narratorlastname>` lowercased, `_`-joined, truncated at 60 characters with no trailing separator. The UI states clearly: *"Identifiers are permanent and must be unique on archive.org. Confirm availability before uploading."*

### 16.6 Tagging

```swift
public struct AudioTags: Sendable, Equatable {
    public var title: String; public var artist: String; public var album: String
    public var albumArtist: String?; public var composer: String?      // narrator convention
    public var track: (Int, Int)?; public var disc: (Int, Int)?
    public var year: Int?; public var genre: String                    // "Speech" / "Audiobook"
    public var comment: String?; public var copyright: String?
    public var narrator: String?; public var publisher: String?
    public var language: String?; public var description: String?
    public var artworkJPEG: Data?
    public var isAudiobook: Bool
    public var chapters: [ChapterMark]?
}
```

- **MP3 → ID3v2.4** written by a small dedicated writer (`ID3Writer`) — LAME does not write ID3 for you beyond the Xing frame. Write `TIT2 TPE1 TALB TPE2 TCOM TRCK TDRC TCON COMM TCOP TLAN APIC`. Use UTF-8 encoding byte `0x03`. Write a padded frame area of 4 KB so retagging does not rewrite the file.
- **M4A/M4B → MPEG-4 metadata** via `AVAssetExportSession`/`AVAssetWriter` metadata items: `©nam ©ART ©alb ©wrt ©day ©gen ©cmt cprt covr stik pgap` plus the freeform `----:com.apple.iTunes:NARRATOR`.
- **FLAC → Vorbis comments** written by the FLAC encoder wrapper: `TITLE ARTIST ALBUM TRACKNUMBER DATE GENRE DESCRIPTION COPYRIGHT PERFORMER`.
- **WAV → LIST/INFO chunk** (`INAM IART IPRD ICRD IGNR ICMT`) — optional, best-effort.

`TaggingTests` round-trips every container: write tags, read them back with `AVAsset`/a minimal parser, assert equality of the fields each format supports.

### 16.7 The mastering chain (Pro)

Applied **only** for retail destinations and only when `applyMastering` is on (default on). Deterministic, documented, and non-configurable beyond a target selector — this is a "make it pass ACX" button, not a mixing console.

Order of operations on the assembled chapter master (float PCM):

1. **DC removal** — subtract the mean.
2. **High-pass filter** — 2nd-order Butterworth at 80 Hz. Removes rumble; inaudible on speech. (Reuse `BiquadFilter.swift`.)
3. **Room-tone normalization** — trim head/tail to the profile's window: head to 0.75 s, tail to 2.0 s of the take's own room tone (never digital silence — inserting true silence at the head is itself an ACX failure mode because it makes the noise floor measurement discontinuous). If insufficient room tone exists, synthesize it by looping the quietest 250 ms window found in the chapter, at unity gain, with a 30 ms crossfade.
4. **RMS normalization** — compute speech-only RMS (excluding inserted gaps) and apply a single static gain so RMS hits `profile.loudness.targetDBFS` (−20 dBFS).
5. **True-peak limiting** — lookahead limiter, 5 ms attack, 50 ms release, ceiling at `profile.peakCeilingDBFS - 0.5` (−3.5 dBFS), operating on a 4× oversampled signal.
6. **Re-measure** — recompute metrics on the mastered audio and assert the result satisfies the profile. If it does not (e.g. noise floor still above −60 dB), the export **still proceeds** but the report records the failure and the completion screen says exactly which rule the file misses and why mastering cannot fix it (a noisy room cannot be fixed by gain).
7. **Dither** — only when reducing bit depth for a PCM output (24 → 16): TPDF dither at 1 LSB, applied after limiting. Never dither before lossy encoding.

`MasteringChainTests` asserts: an input at −30 dBFS RMS comes out at −20 ± 0.3 dB; a signal with a +0 dBFS transient comes out with true peak ≤ −3.5 dBFS; and the chain is idempotent to within 0.1 dB when run twice.

### 16.8 `RetailMasterPackageBuilder`

```
Exports/Retail/<projectslug>/
  01 - Opening Credits.mp3
  02 - Chapter One.mp3
  ...
  NN - Closing Credits.mp3
  <projectslug>-retail-sample.mp3
  <projectslug>.m4b                        (Pro: m4bExport)
  masters/01 - Opening Credits.wav         (or .flac with flacExport)
  cover-2400.jpg
  delivery-metadata.json
  validation-report.html                   (Pro: validationReportExport)
  validation-report.json
  checksums.sha256
  submission-checklist.md
```

Chapter files: mastered → 44.1 kHz mono 192 kbps CBR MP3 → tagged → named `NN - <Chapter Title>.mp3` (freeform numbered; retailers do not impose LibriVox-style naming, and human-readable names help the user's own intake process).

M4B assembly: concatenate the mastered chapter PCM into one AAC-LC track with chapter marks at chapter boundaries, embed cover and metadata, set `stik = 2` and `pgap = 1`.

**File-length rule:** if any chapter exceeds `maxFileDuration` (120 min), the builder does not silently split. It fails validation first (`chapterTooLong`, blocking) and offers the `splitChapter` fix action, which inserts a chapter boundary at the paragraph nearest the midpoint. Splitting the delivered audio without splitting the *project's* chapter structure would desynchronize the chapter list from the files.

### 16.9 `InternetArchivePackageBuilder`

Preconditions: validation for `.internetArchive` clean; `archiveIdentifier` present and valid; `availableEncoders.contains(.flac)` if FLAC masters requested (fall back to WAV with a warning if not).

Output as specified in §3.3.3. Additional requirements:

- `<identifier>_meta.json` uses the archive's field names exactly (`identifier`, `mediatype`, `collection`, `title`, `creator`, `date`, `language`, `description`, `subject`, `licenseurl`, `rights`, `notes`, `runtime`, `source`, `scanner`).
- `subject` is emitted as a JSON array; the generated `ia` command emits repeated `--metadata='subject:...'` arguments.
- The generated command in the checklist:

```bash
ia upload <identifier> \
  --metadata='mediatype:audio' \
  --metadata='collection:opensource_audio' \
  --metadata='title:...' --metadata='creator:...' --metadata='date:...' \
  --metadata='language:...' --metadata='licenseurl:...' \
  *.flac *.mp3 <identifier>.jpg
```

  with a preceding note: *"Review this command before running it. Uploading is your action, not Voxglass's."*
- When `useTestCollection`, `collection` becomes `test_collection` and the checklist explains that test items are removed automatically after about 30 days — the recommended dry run.
- The AI-disclosure `notes` line is added automatically when applicable (§3.3.2).

### 16.10 Checksums

```swift
public struct ChecksumWriter: Sendable {
    public func sha256Manifest(_ files: [ExportedFile]) -> Data   // "<sha256>  <filename>\n" — coreutils format
}
```

Emitted for every destination. The format is deliberately `shasum -a 256 -c`-compatible so the user can verify a transfer.

### 16.11 The Export wizard contract

Mockup `14-export-wizard` (three steps: choose scope → choose destination → confirm & run).

- **Step 1 — scope:** whole book (default), selected chapters, or a single chapter (useful for LibriVox section-by-section submission, which is the actual LibriVox workflow — a volunteer posts sections as they finish, not the whole book at once). **This is important and easy to miss: LibriVox export MUST support exporting one chapter.**
- **Step 2 — destination:** three cards exactly as in the mockup (LibriVox / Internet Archive / Professional Retail Master), each listing what it produces, with the Free/Pro chip. Ineligible destinations are shown **disabled with the reason inline**, never hidden.
- **Step 3 — confirm:** validation summary (blocking count blocks the Export button), output location picker (defaults to the package's `Exports/`, with "Reveal in Finder" after), options (IA test collection, MP3 derivatives, mastering, M4B bitrate, retail sample range), estimated output size and time.
- **Run:** per-file progress, cancellable, with a live log. On completion: a summary sheet with file count, total duration, total size, the checklist link, "Reveal in Finder", and `legal.userSubmits`.
- The Pro gate is checked **once**, at the transition from step 2 to step 3, via `LicenseGate.require(_:)`. If it throws, the wizard shows the purchase sheet inline and, on success, continues to step 3 with all selections preserved.

### 16.12 Export idempotency and resumption

- Every produced file's SHA-256 is recorded in `export_run`. Re-exporting to the same directory with `overwriteExisting == false` skips files whose content hash already matches the planned output and reports them as "unchanged".
- Because chapter renders are cached by content, re-exporting after changing one paragraph re-encodes exactly one chapter.
- A cancelled export leaves `.partial` and can be resumed; a failed export keeps the partial directory and the error code for diagnosis.

---

### 16.13 Worked artifact examples

These are the literal shapes the builders must produce. Tests compare against these fixtures.

**LibriVox package for "The Murder of Roger Ackroyd", 12 sections, author Christie:**

```
Exports/LibriVox/the-murder-of-roger-ackroyd/
  murderrogerackroyd_01_christie.mp3      12:41   4.8 MB
  murderrogerackroyd_02_christie.mp3      15:03   5.7 MB
  …
  murderrogerackroyd_12_christie.mp3      11:58   4.5 MB
  section-durations.txt
  librivox-checklist.md
  metadata.json
  checksums.sha256
```

`metadata.json`:

```json
{
  "generator": "Voxglass Studio 1.0 (1)",
  "generatedAt": "2026-08-14T18:22:09Z",
  "destination": "librivox",
  "project": { "title": "The Murder of Roger Ackroyd", "author": "Agatha Christie",
               "narrator": "John Burns", "language": "en-US" },
  "rights": { "basis": "Public domain in the United States",
              "sourceURL": "https://www.gutenberg.org/ebooks/69087",
              "editionYear": 1926, "attestedBy": "John Burns",
              "attestedAt": "2026-08-01T15:04:00Z" },
  "narrationOrigin": { "kind": "humanOnly", "humanParagraphs": 2884, "aiParagraphs": 0 },
  "audio": { "container": "mp3", "codec": "mp3", "sampleRate": 44100, "channels": 1,
             "bitrateKbps": 128, "cbr": true },
  "sections": [
    { "index": 1, "title": "Breakfast Table", "file": "murderrogerackroyd_01_christie.mp3",
      "duration": 761.4, "sha256": "9f2c…", "peakDBFS": -3.1, "rmsDBFS": -19.4,
      "noiseFloorDBFS": -63.2, "estimatedPerceivedVolumeDB": 89.1 }
  ],
  "totals": { "sections": 12, "duration": 15175.0, "bytes": 243100160 },
  "disclaimers": { "intro": "present", "outro": "present", "finalOutro": "present" }
}
```

**Internet Archive manifest** `<identifier>_meta.json`:

```json
{
  "identifier": "murderrogerackroyd_christie_burns",
  "mediatype": "audio",
  "collection": "opensource_audio",
  "title": "The Murder of Roger Ackroyd",
  "creator": ["Agatha Christie"],
  "performer": "John Burns",
  "date": "2026",
  "language": "eng",
  "description": "<p>A Hercule Poirot mystery, read by John Burns.</p><p>Source edition: 1926.</p>",
  "subject": ["audiobook", "mystery", "detective fiction", "public domain"],
  "licenseurl": "https://creativecommons.org/publicdomain/mark/1.0/",
  "rights": "Public domain in the United States. Recording released to the public domain by the narrator.",
  "source": "https://www.gutenberg.org/ebooks/69087",
  "runtime": "4:12:55",
  "notes": "",
  "scanner": "Voxglass Studio 1.0 (1)"
}
```

with the AI-disclosure line placed in `notes` when applicable. `checksums.sha256`:

```
9f2c1b0e…  murderrogerackroyd_01_christie.mp3
a71d4e88…  murderrogerackroyd_02_christie.mp3
```

**Retail `delivery-metadata.json`:**

```json
{
  "generator": "Voxglass Studio 1.0 (1)",
  "destination": "acx",
  "title": "The Murder of Roger Ackroyd",
  "subtitle": null,
  "series": { "name": null, "index": null },
  "authors": ["Agatha Christie"],
  "narrators": ["John Burns"],
  "publisher": "Burns Audio",
  "publicationDate": "2026-09-01",
  "language": "en-US",
  "isAbridged": false,
  "isbn": null,
  "asin": null,
  "copyright": "Copyright 1926 Agatha Christie. Production copyright 2026 Burns Audio.",
  "description": "…",
  "categories": ["Mysteries & Thrillers"],
  "narrationOrigin": "humanOnly",
  "cover": { "file": "cover-2400.jpg", "width": 2400, "height": 2400, "colorSpace": "RGB" },
  "retailSample": { "file": "murder-roger-ackroyd-retail-sample.mp3", "duration": 143.2,
                    "startsAtParagraph": "…uuid…" },
  "files": [
    { "index": 1, "role": "openingCredits", "file": "01 - Opening Credits.mp3", "duration": 21.4,
      "rmsDBFS": -20.1, "truePeakDBFS": -3.6, "noiseFloorDBFS": -64.8, "sha256": "…" },
    { "index": 2, "role": "chapter", "title": "Chapter One", "file": "02 - Chapter One.mp3",
      "duration": 761.4, "rmsDBFS": -20.0, "truePeakDBFS": -3.5, "noiseFloorDBFS": -63.9, "sha256": "…" }
  ],
  "compliance": { "profile": "acx", "rmsRange": [-23, -18], "peakCeiling": -3,
                  "noiseFloorCeiling": -60, "allFilesPass": true }
}
```

The `compliance` block is what makes the package self-describing: a user (or a future automated submitter) can verify the claim without re-analyzing the audio, and `allFilesPass: false` is legal — it means the user exported anyway, with the failures enumerated per file.

**Section durations file** (`section-durations.txt`, LibriVox forum-ready):

```
murderrogerackroyd_01_christie.mp3    12:41
murderrogerackroyd_02_christie.mp3    15:03
murderrogerackroyd_03_christie.mp3    13:22
TOTAL                                 4:12:55
```

### 16.14 Export progress model

```swift
public struct ExportProgress: Sendable, Equatable {
    public var phase: ExportPhase
    public var completedUnits: Int
    public var totalUnits: Int
    public var currentFileName: String?
    public var fractionCompleted: Double
    public var estimatedRemaining: TimeInterval?
}
public enum ExportPhase: String, Sendable {
    case validating, rendering, mastering, transcoding, tagging, writingArtifacts, hashing, done
}
```

The wizard shows phase plus per-file progress. Estimated remaining is computed from a rolling average of completed chapter durations against wall time; it is a hint and must never block completion.

## 17. Licensing and StoreKit

### 17.1 Product

| Property | Value |
|---|---|
| Product ID | `guru.parso.voxglass.studio.pro` |
| Type | Non-consumable |
| Price | $149.00 (Tier equivalent) |
| Family Sharing | Enabled |
| Display name | "Voxglass Studio Pro" |
| Description | "Unlock professional retail delivery: mastered MP3/WAV/FLAC chapter files, chapterized M4B, retail samples, batch export, and exportable validation reports. One-time purchase, no subscription." |

### 17.2 Provider

```swift
public protocol LicenseProvider: Sendable {
    var entitlement: EntitlementState { get async }
    var updates: AsyncStream<EntitlementState> { get }
    func refresh() async
    func purchasePro() async throws -> EntitlementState
    func restore() async throws -> EntitlementState
    func product() async throws -> ProductInfo          // localized price for the UI
}
public enum EntitlementState: Sendable, Equatable { case free, pro(since: Date), pending, unknown }
public struct ProductInfo: Sendable, Equatable { public var displayPrice: String; public var displayName: String; public var description: String }
```

`StoreKitLicenseProvider` (Studio target):

- On init: start a `Transaction.updates` listener task **before** any other StoreKit call, and finish any unfinished transactions.
- `entitlement` derives from `Transaction.currentEntitlements` filtered to the product ID, with `VerificationResult` checked — unverified transactions yield `.unknown`, never `.pro`.
- `purchasePro()` → `product.purchase()` → handle `.success(verification)` (verify, finish, return `.pro`), `.userCancelled` (throw `LicenseError.cancelled`), `.pending` (return `.pending`, show "waiting for approval" — Ask to Buy), unknown (throw).
- `restore()` → `AppStore.sync()` then re-derive.

### 17.3 The gate

```swift
public struct LicenseGate: Sendable {
    public let provider: any LicenseProvider
    public func require(_ feature: ProFeature) async throws {
        guard await isUnlocked(feature) else { throw LicenseError.proRequired(feature) }
    }
    public func isUnlocked(_ feature: ProFeature) async -> Bool {
        switch await provider.entitlement {
        case .pro: return true
        case .free, .pending, .unknown: return false
        }
    }
}
```

All `ProFeature` cases map to the same entitlement in MVP. The enum exists so that the *call sites* are self-documenting and so a future tier split is mechanical.

### 17.4 Caching and offline behavior

- The last verified `.pro(since:)` is cached in the app's preferences with the transaction ID and original purchase date.
- On launch, the cached value is used **immediately** so a Pro user never sees a locked UI while StoreKit warms up; it is then confirmed asynchronously.
- If confirmation says `.free` (refund/revocation), the app reverts and shows a one-time, non-blocking notice: "Your Voxglass Studio Pro purchase is no longer active." No data is deleted; previously exported files are untouched.
- If confirmation cannot complete (offline), the cached value stands indefinitely. Do **not** expire the cache. A narrator on a plane with a deadline must not lose their exporter.

### 17.5 Placement rules (CI-enforced)

Files permitted to reference `LicenseGate`, `ProFeature`, `isPro`, or `EntitlementState`:

```
**/Export*.swift  **/Packaging/**  **/RetailMaster*.swift  **/Master*.swift
**/License*.swift  **/Settings*.swift  **/StudioEnvironment.swift
```

Everything else fails grep gate G-2. In particular, `RecordingModel`, `ReviewQueueModel`, `ProductionSyncModel`, `AssemblyModel`, and every watch/CarPlay type MUST be entitlement-free.

**Consequence to watch for:** the Export wizard's *card* needs to show "Pro · $149", which means the wizard view reads entitlement — that is allowed (`Export*`). The Validation screen must **not** read entitlement, because validation is free for all targets (§15.7); its target picker offers every destination unconditionally.
---

## 18. UI specification

Every view listed here maps to a mockup file in `docs/voxglass-mvp/`. The mockups are the visual contract; this section is the *behavioral* contract: state, empty/loading/error states, accessibility identifiers, and keyboard support.

Universal rules:

1. **All view models are `@Observable` and `@MainActor`.** `ObservableObject` fails CI gate G-3.
2. **Every interactive element sets `.accessibilityIdentifier`** from the registry in §22.1. Adding a control requires adding its identifier there.
3. **Every screen defines four states:** loading, empty, content, error. No screen may show an indefinite spinner without a cancel/retry affordance.
4. **Dynamic Type** is honored everywhere; the Mac uses `.font(.body)`-relative sizing, iOS/watchOS support the full range including accessibility sizes. Fixed-height rows are forbidden in lists that show user text.
5. **VoiceOver labels** are written for meaning, not appearance: the flag button is "Flag paragraph 218 for review", not "flag".
6. **Reduced Motion** disables the waveform animation and queue transitions.
7. Colors come from the existing `Voxglass/DesignSystem`; the Studio app adds a `StudioTheme` extension rather than new literals.

### 18.1 macOS — VoxglassStudio

#### 18.1.1 Shell

```swift
@main struct StudioApp: App {
    var body: some Scene {
        WindowGroup(for: ProjectReference.self) { $ref in StudioRootView(reference: ref) }
            .commands { StudioCommands() }
        Settings { SettingsView(model: settingsModel) }
    }
}
enum StudioSection: Hashable { case library, needsReview, readyToExport, archive, settings }
enum ProjectTab: Hashable { case dashboard, script, record, review, assemble, metadata, validateExport }
```

- Library window: `NavigationSplitView` with the sidebar from mockup `01` (All Projects / Needs Review / Ready to Export / Archive / Settings) and counts.
- Project window: title bar shows book title; a segmented tab bar (mockup `04`) with Dashboard / Script / Record / Review (badge) / Assemble / Metadata / Validate & Export.
- `StudioCommands` adds: New Audiobook (⌘N), Open (⌘O), Import Source (⇧⌘I), Record (⌘R), Next Paragraph (⌘→), Previous (⌘←), Start Review Queue (⌘⇧R), Export (⌘E), Verify Project, Rebuild Caches.

#### 18.1.2 Project Library — `ProjectLibraryView` / `ProjectLibraryModel`

*Mockup `01-project-library`.*

| Element | Behavior |
|---|---|
| Project card | Cover monogram (initials) or artwork, title, "Author · Narrator", progress chip ("42% recorded"), flagged chip ("18 flagged"), purpose chip ("Public domain"/"Personal"), footer "Edited 8 minutes ago · Preview synced" |
| `＋ New Audiobook` | opens the wizard (`library.newAudiobook`) |
| "Start another audiobook" tile | same as above; also offers "Open existing package…" |
| Production Activity feed | last 10 cross-device events: watch notes, phone approvals, sync status. Tapping a row opens the project at that paragraph. |
| Sidebar counts | from cached `summarySnapshot`; refresh on window focus |

Model:

```swift
@Observable @MainActor final class ProjectLibraryModel {
    private(set) var section: StudioSection = .library
    private(set) var projects: [RecentProject] = []
    private(set) var activity: [ActivityItem] = []
    private(set) var state: LoadState = .loading
    func load() async; func open(_ p: RecentProject); func createNew(); func openPackage(at: URL)
    func remove(_ p: RecentProject)           // removes from recents; never deletes the package
}
```

Empty state: "No audiobooks yet — create one, or open a `.voxproject` you already have." with both buttons.

#### 18.1.3 New Project wizard — `NewProjectWizard` / `NewProjectModel`

*Mockup `02-new-project`.* Four steps (§8.2). Validation: title/author/narrator non-empty (trimmed); if purpose is `publicDomainCommunity`, the source URL field is required before Continue on step 3; the attestation checkbox is required to finish.

Identifiers: `wizard.title`, `wizard.author`, `wizard.narrator`, `wizard.purpose.<case>`, `wizard.rightsBasis.<case>`, `wizard.sourceURL`, `wizard.attest`, `wizard.continueToImport`, `wizard.cancel`.

The step-3 footnote is exactly `legal.noCopyrightDetermination`.

#### 18.1.4 Source Import — `SourceImportView` / `SourceImportModel`

*Mockup `03-source-import`.*

- Left: chapter tree with paragraph counts (`Front Matter 7 ¶`, `1. Breakfast Table 84 ¶`).
- Center: paragraph list with inline `Split here` / `Merge next`.
- Right: format badge ("EPUB"), "312 sections detected", warning count, Segmentation Warning card with `Mark Scene Break`, Source Mapping (text hash, edition year).
- Top: `Re-segment` (re-runs with adjusted options), `Accept Structure` (`import.acceptStructure`).
- `import.chapterCount` is a static text with the detected chapter count — the smoke test keys on it.

Re-import mode adds a summary sheet: "Reusing 2,871 paragraphs · 13 new · 12 no longer in source (4 have recordings) · 6 changed text" with Keep/Discard for orphans.

#### 18.1.5 Project Dashboard — `ProjectDashboardView` / `ProjectDashboardModel`

*Mockup `04-project-dashboard`.* Progress ring, "1,204 of 2,884 paragraphs recorded", review card ("18 · 7 need pickup · 11 need approval" → Start Review Queue), chapter list with per-chapter completion, Device Preview status (iPhone Current / Watch Via iPhone / CarPlay Available), Recent Feedback ("2 Watch actions · 3 iPhone notes" → Open Feedback), and the two primary actions `Preview on Devices` and `Record Next` (`dashboard.recordNext`).

"Record Next" resolves to the first paragraph in document order with no selected take, or the first `needsPickup` if everything is recorded.

#### 18.1.6 Script Editor — `ScriptEditorView` / `ScriptEditorModel`

*Mockup `05-script-editor`.*

- Chapter list, paragraph list with state chips (`Recorded`, `Text changed`, `Unrecorded`, `Needs pickup`), inspector with direction note, pronunciation, review status, Split/Merge.
- Text editing is inline with a 400 ms debounce; the explicit `Save` button flushes immediately.
- The drift explanation banner ("This paragraph has a selected take recorded before the latest text edit") appears when drift is `.minor` or `.semantic`, with actions **Re-record** and **Keep take**.
- Find (⌘F) searches paragraph text with match highlighting and next/previous; the list virtualizes (must handle 10,000 paragraphs — use `List` with `id`-based lazy rows and never build all rows eagerly).
- Generated paragraphs (disclaimers/credits) show a "Generated" chip and are read-only unless "Edit anyway" is confirmed.

#### 18.1.7 Recording Workspace — `RecordingWorkspaceView` / `RecordingModel` + `RecordingMeter`

*Mockup `06-recording-workspace`.* The most important screen in the app.

Layout: left paragraph rail with state glyphs (`✓ ⚑ ● ○`), center teleprompter + waveform + transport, right inspector (Takes, Direction, Pronunciation, Flag for review, Quality).

Behavior:

- The teleprompter shows the current paragraph at a large, adjustable size (⌘+/⌘−), with the previous and next paragraph dimmed above/below for context. Scrolling is by paragraph, not free.
- Header shows "Chapter 1 · Paragraph 37 of 84", input level chip ("● Input −18 dB"), `Audio Setup` (opens Settings → Audio), and the current selection ("Take 2 selected · 48 kHz · 24-bit · mono").
- Transport: Record (`record.transport.record`), Play Take, Play in Context, ◀ Previous ¶, Accept & Next ¶ (`record.acceptAndNext`), Next ¶ ▶.
- Keyboard flow card is visible (it teaches the shortcuts) and is collapsible.
- Takes list shows every take with duration, quality flags ("clipped"), and selection state; `Import WAV as Take` opens the import sheet scoped to this paragraph.
- Quality panel shows peak and noise estimate live after analysis.
- `record.teleprompter` identifies the teleprompter container for the smoke test.

`RecordingModel` state machine:

```
idle → preparing → armed → (preRoll) → recording → finalizing → idle
                                   ↘ cancelled → idle
```

Every transition is logged. `armed` means the engine is running and monitoring is possible but nothing is being written. Entering the workspace prepares the engine immediately so the **record-start latency budget (< 250 ms)** is met.

#### 18.1.8 Import Audio — `ImportAudioView` / `ImportAudioModel`

*Mockup `07-import-audio`.* Waveform with draggable markers, `＋ Split Marker` / `− Remove Marker`, origin picker (with the LibriVox ineligibility warning), start paragraph picker, assignment method picker, and the segment→paragraph→confidence table. `Assign 12 Segments` commits.

Identifiers: `import.audio.origin.<case>`, `import.audio.method.<case>`, `import.audio.assign`, `import.originWarning`.

#### 18.1.9 Take Comparison — `TakeComparisonView` / `TakeComparisonModel`

*Mockup `08-take-comparison`.* A/B with synchronized position (§11.7), per-take metrics, "Use Selected Take".

#### 18.1.10 Review Queue — `ReviewQueueView` / `ReviewQueueModel`

*Mockup `09-review-queue`.* Queue rail with state glyphs, current paragraph text, transport with ◀ Previous Flagged / ▶ / Next Flagged ▶, incoming device notes with attribution ("iPhone · Today 3:42 PM"), the three actions **Approve & Next**, **Needs Pickup & Next**, **Keep Flagged**, a local review-note field, and the options `Auto-advance` and `Play 1 s context`.

All three actions emit events (§14.1); none writes review state directly.

#### 18.1.11 Chapter Assembly — `ChapterAssemblyView` / `AssemblyModel`

*Mockup `10-chapter-assembly`.* Per-paragraph table (¶ / Take / Trim / Gap / Status), spacing controls, Render Preview, Play Chapter, and the render-cache summary with `Rebuild Changed Audio`.

#### 18.1.12 Metadata & Rights — `MetadataRightsView` / `MetadataRightsModel`

*Mockup `11-metadata-rights`.* Tabs: Book Details / Rights / Artwork / Identifiers. Header chip shows live eligibility ("LibriVox eligible so far"). Narration Origin Audit shows the human/AI paragraph counts from `EligibilityProfile` with a link to a filtered list. Artwork tab validates size/aspect and generates the 2400 px derivative. Identifiers tab holds ISBN/ASIN and the archive identifier with the suggester and validity check.

#### 18.1.13 Device Preview — `DevicePreviewView` / `DevicePreviewModel`

*Mockup `12-device-preview`.* Per §13.8.

#### 18.1.14 Validation Report — `ValidationReportView` / `ValidationModel`

*Mockup `13-validation-report`.* Severity sidebar with counts, target picker (all destinations, ungated), issue rows with title/message/fix button, Eligibility panel, `Run Again`, `Fix Next Issue`.

#### 18.1.15 Export Wizard — `ExportWizardView` / `ExportModel`

*Mockup `14-export-wizard`.* Per §16.11. Identifiers: `export.scope.<case>`, `export.destination.librivox|internetArchive|retail`, `export.unlockPro`, `export.run`, `export.revealInFinder`.

#### 18.1.16 Settings — `SettingsView` / `SettingsModel`

*Mockup `15-settings-audio`.* Tabs: Audio / Recording / Preview Sync / Storage / License.

- **Audio:** input device picker (live device list, hot-plug aware), recording format, monitoring output, monitoring toggle, pre-roll, warn-on-clipping, auto-compute metrics, and **Record 10-second Test** with an "Input Check: Healthy level" verdict computed from the same metrics engine (peak, RMS, noise floor, with plain-language guidance: "Your noise floor is −52 dB. Retail delivery needs −60 dB or lower. Try turning off fans and adding soft furnishings.").
- **Recording:** auto-select newest take, skip recorded paragraphs on advance, auto-advance behavior, teleprompter size.
- **Preview Sync:** account status, proxy bitrate, auto-sync default, purge all projections.
- **Storage:** per-project storage report, Rebuild caches, Vacuum unused assets, Verify project, Copy diagnostics.
- **License:** entitlement state, price, Purchase, Restore, Third-Party Notices.

### 18.2 iPhone — Voxglass additions

The production feature is additive; the existing consumer app's tabs (Discover / Library / Search / Stats) are untouched.

#### 18.2.1 My Productions shelf — `MyProductionsShelf` / `MyProductionsModel`

*Mockup `01-library-my-productions`.* A filter chip row on the Library tab: Books / Playlists / Downloads / **My Productions**. Selecting it shows production cards with progress, flagged count, and sync state ("✓ Current with Mac", "Downloaded"). Identifier `shelf.myProductions`; each card `production.<slug>`.

If no projections exist: "Productions you preview from Voxglass Studio on your Mac appear here." with no call to action (the phone cannot create one).

#### 18.2.2 Production Book Detail — `ProductionBookDetailView` / `ProductionDetailModel`

*Mockup `02-production-book-detail`.* Primary actions `▶ Play Whole Book` (`detail.playWholeBook`) and `⚑ Review N Flagged Paragraphs` (`detail.reviewFlagged`); progress card; a Listen section with rows Whole Book / Selected Chapters / Flagged / Needs Pickup / Unapproved (each with counts); chapter list with completion.

#### 18.2.3 Production Review Player — `ProductionReviewPlayerView` / `ProductionPlayerModel`

*Mockup `03-production-player`.* Paragraph text prominent; header "Chapter 4 · Paragraph 218 of 2,884"; transport `◀¶  −15  ▶  +30  ¶▶`; the three review actions `player.flag` / `player.approve` / `player.pickup`; `＋ Add Review Note`; auto-advance toggle; "Next: …" preview.

Requirements: actions are debounced (a double-tap must not emit two events); each action gives haptic feedback; the queue label and position are always visible; the player continues in the background and appears on the lock screen with the paragraph as the title.

#### 18.2.4 Paragraph List — `ProductionParagraphListView` / `ParagraphListModel`

*Mockup `04-paragraph-list`.* Filter chips All / Flagged / Pickups; grouped by chapter; rows show state, snippet, and the latest note; multi-select with `▶ Play Selected Range`.

#### 18.2.5 Review Queue Builder — `ReviewQueueBuilderView` / `ReviewQueueBuilderModel`

*Mockup `05-review-queue-builder`.* Predicate selection with counts, playback options (auto-advance, skip approved), "Download queue to Apple Watch" with the size estimate, live queue duration and item count, and `Start N-Paragraph Review`.

#### 18.2.6 Add Review Note — `AddReviewNoteSheet` / `ReviewNoteModel`

*Mockup `06-review-note-sheet`.* Timecoded header, six category chips, text field, `🎙 Dictate Note` (uses the system dictation keyboard — **not** speech recognition APIs), `Save & Continue Review`.

#### 18.2.7 Production Sync & Storage — `ProductionSyncStorageView` / `ProductionSyncModel`

*Mockup `07-production-sync-storage`.* Mac Preview status with revision and last-received time, `Check for Updates`, local storage figures with `Download Entire Project` / `Remove Downloaded Audio`, the Apple Watch section with reachability and item count plus `Refresh Watch Queue`, the explanatory line that the watch does not connect to CloudKit directly, and pending feedback counts with upload state.

#### 18.2.8 iPhone-side services

- `ProductionPreviewStore` — local cache of the projection in the existing app database (new tables mirroring §7.3's paragraph projection subset), plus proxy audio files in `Application Support/Productions/<projectID>/`.
- Prefetch policy: on entering a queue, download proxies for the current + next 3 items; on Wi-Fi, opportunistically fetch the rest of the queue.
- `WatchConnectivityTransport` (phone side) implements `WatchTransport` and bridges to `WCSession`.
- Events are queued in a file-backed outbox and pushed with the same retry/backoff policy as §13.7.

### 18.3 CarPlay scene

Entitlement `com.apple.developer.carplay-audio` (already declared; the scene delegate `CarPlaySceneDelegate` exists). Production templates extend the existing CarPlay layer (`Voxglass/App/CarPlay/`, `Voxglass/Core/CarPlay/`).

| Mockup | Type | Contents |
|---|---|---|
| `01-productions-tab` | `CPTabBarTemplate` | Continue / Productions / Review(badge) tabs; Productions tab lists productions with subtitle and flagged count |
| `02-production-detail` | `CPListTemplate` | Play Whole Book, Review N Flagged, Continue from …, Choose Chapter, Needs Pickup |
| `03-review-queue-list` | `CPListTemplate` | Flagged / Needs Pickup / Unapproved with counts and durations; auto-advance toggle row |
| `04-review-player` | `CPNowPlayingTemplate` | custom buttons Keep Flagged / Approve / Needs Pickup; ◀¶ / ¶▶ mapped to paragraph boundaries |
| `05-review-note-summary` | `CPInformationTemplate` | the paragraph's note text, tag, source device and time; the three actions |
| `06-voice-action-confirmation` | `CPAlertTemplate` (or an information template) | "Paragraph Approved", next item, Play Next / Undo |
| `07-review-queue-browser` | `CPListTemplate` | queue items with tag and duration; current item marked "Playing" |
| `08-carplay-review-settings` | `CPListTemplate` | auto-advance, play 1 s context, voice confirmations, plus the safety note |

Normative CarPlay rules:

1. **No free-text entry anywhere.** The safety note in mockup `08` is required copy: "Typing and free-form note entry are unavailable in CarPlay. Detailed notes can be added later on iPhone, Watch, or Mac."
2. Voice notes are markers only (`.voiceNoteRequested`).
3. `MPRemoteCommandCenter` next/previous track commands map to **paragraph** boundaries while a production queue is active, and revert to the consumer app's behavior otherwise. This switch is the most likely regression point; it needs a test.
4. Now-playing metadata: title = paragraph label ("Chapter 4 · ¶ 218"), artist = book title, artwork = cover.
5. List templates must respect the CarPlay item limit (`CPListTemplate.maximumItemCount`); queue browsers page in chunks.
6. Announcements ("approved", "flagged", "pickup") use `AVSpeechSynthesizer`… **NO.** That is a speech-synthesis API and CI gate G-1 forbids synthesis symbols. **Decision: voice confirmations in MVP are pre-recorded short audio cues or simply distinct earcons/haptics, not TTS.** Rename the setting to "Spoken confirmations" → **"Audio confirmations"**, implemented as three short bundled tones. Update the mockup copy accordingly and record the deviation in §22.4.
7. `CarPlayReviewController` is the single place that maps commands → `ReviewEvent`, and it is unit-tested without a car (§19.5).

### 18.4 watchOS — VoxglassWatch additions

| Mockup | View | Model |
|---|---|---|
| `01-productions-list` | `ProductionsListView` | `WatchProductionsModel` |
| `02-production-home` | `ProductionHomeView` | `WatchProductionHomeModel` |
| `03-review-queue-list` | `WatchReviewQueueListView` | `WatchReviewModel` |
| `04-review-player` | `WatchReviewPlayerView` | `WatchReviewModel` |
| `05-paragraph-text` | `WatchParagraphTextView` | `WatchReviewModel` |
| `06-review-action-confirmation` | `WatchReviewConfirmationView` | — |
| `07-dictation-category` | `WatchDictationCategoryView` | `WatchDictationModel` |
| `08-dictation-result` | `WatchDictationResultView` | `WatchDictationModel` |
| `09-watch-sync-status` | `WatchSyncStatusView` | `WatchSyncModel` |
| `10-offline-queue` | `WatchOfflineQueueView` | `WatchSyncModel` |

Interaction rules (normative):

- **Digital Crown = volume**, never paragraph selection. Paragraph movement is by the ◀¶ / ¶▶ buttons and by swipe.
- **Flag is the most prominent action** in the player; approve and pickup are equally sized beside it.
- **Long-press** on the player opens the tag picker.
- **Haptic** (`.click`) fires at each paragraph boundary; `.success` on approve; `.warning` on pickup.
- **Offline state is explicit**: when audio is unavailable and the phone is unreachable, the player shows "Audio not downloaded — open Voxglass on iPhone" instead of a spinner.
- The dictation flow is category → dictation → confirm; dictation uses `WKExtension`'s text input controller with `.dictation` only (no keyboard on a watch is fine, but allow scribble).
- Row taps require `.contentShape(Rectangle())` for the UI test to hit them (known gotcha in this repo).
- Sheets are presented with `.sheet`, **not** pushed onto a `NavigationPath` — the existing watch UI tests depend on this distinction.

### 18.5 Empty, loading, and error copy (normative)

| Situation | Copy |
|---|---|
| No projects (Mac) | "No audiobooks yet — create one, or open a `.voxproject` you already have." |
| No productions (phone) | "Productions you preview from Voxglass Studio on your Mac appear here." |
| No flagged items | "Nothing flagged. Everything you have reviewed is approved." |
| Not signed into iCloud | "Sign in to iCloud to preview this project on your devices. Everything else keeps working." |
| Watch unreachable | "iPhone not reachable. Your review actions are saved and will sync." |
| Microphone denied | "Voxglass needs microphone access to record. Open System Settings → Privacy & Security → Microphone." |
| Encoder unavailable | "The MP3 encoder could not be loaded, so LibriVox export is unavailable. Reinstall Voxglass Studio." |
| Export blocked | "{N} blocking issues must be fixed before exporting to {destination}." |
| Pro required | "Professional retail delivery is part of Voxglass Studio Pro — a one-time $149 purchase. Everything you have already done stays free." |
---

## 19. Testing, fixtures, and CI gates

### 19.1 Test topology

**Test policy: every test in this repository is a Swift Testing suite run by `swift test` on the macOS host, except the five UI smoke tests in §19.6.** The Swift Testing suites never require a simulator. The five UI smoke tests are the only XCUITest targets; they run only locally (via `scripts/test.sh`) and never on GitHub Actions.

| Target | Framework | Runs where | Contents |
|---|---|---|---|
| `VoxglassCoreTests` (path `VoxglassTests`) | Swift Testing | macOS host, `swift test`, no simulator | all pure logic: domain, text, metrics math, queues, fold, validation, filenames, cache keys, phone view models (Production), watch models |
| `VoxglassStudioTests` | Swift Testing | macOS host, `swift test`, no simulator | Studio view models + services with fakes; package/store integration; transcoder round-trips |
| `VoxglassPerformanceTests` (path `VoxglassTests/Performance`) | Swift Testing | macOS host, `VOXGLASS_TIMING_TESTS=1 swift test --no-parallel`, no simulator | **timing-only budgets** (§19.3 budgets + §19.8 probe): one consolidated `@Suite(.serialized)` (`PerformanceBudgetTests`) so the budgets can never contend with each other. The suite is gated behind the `VOXGLASS_TIMING_TESTS` environment variable: the runner is invoked with `--no-parallel` everywhere (CI, the pre-push hook, and `scripts/test_logic.sh`), so the budgets can never contend with the logic suites for CPU. **All** logic suites are currently serialized for the same reason — `swift test --no-parallel --skip VoxglassPerformanceTests` — a temporary policy until the load-sensitive suites are made load-independent. |
| `VoxglassStudioUITests` | XCUITest | macOS, local only | **three smoke tests** (§19.6): create a LibriVox audiobook, create an Internet Archive audiobook, create a commercial audiobook |
| `VoxglassUITests` | XCUITest | iOS simulator, local only | **iPhone smoke test** (existing target) |
| `VoxglassWatchUITests` | XCUITest | watchOS simulator, local only | **watch smoke test** (existing target) |

The CarPlay scene/template check is folded into the **iPhone smoke test** (§19.5): it is not XCUITest-automatable, so it runs as a hosted scene test in the same iOS-simulator test action (`VoxglassCarPlaySmokeTests`), not as a separate UI test.

GitHub Actions runs only `swift test` (the two Swift Testing targets above, plus the serial timing target) plus the compile-only builds and the grep gates (§19.9). **No XCUITest, no simulator, and no `xcodebuild test` ever runs in CI.**

### 19.2 `VoxglassCoreTestSupport`

A test-only SwiftPM target providing fakes and fixtures. Never linked into a shipping target (CI gate G-9 greps app targets for `import VoxglassCoreTestSupport`).

> **`.test(seed:)` fakes (§19.6).** Because gate G-9 forbids `VoxglassCoreTestSupport`
> in a shipping target, the Studio's seeded UI-test environment wires its own
> fakes — `UITestAudioCapture`, `UITestSyncTransport`/`UITestSyncStateStore`,
> `UITestLicenseProvider`, `UITestTranscoder`, `UITestMetricsCalculator`,
> `UITestSegmentPlayer`, `UITestFixedClock`, `UITestSequentialIDGenerator` —
> from `VoxglassStudio/Support/UITestFakes.swift` behind `#if DEBUG`,
> mirroring the Core fakes. The `UITestSeed` enum itself compiles in all
> configurations so gate G-8 can find it.

**Fakes:** `InMemoryProductionStore`, `InMemoryAssetStore`, `FakeAudioCapture`, `FixtureMetricsCalculator`, `FakeTranscoder`, `FakeSegmentPlayer`, `FakeSyncEngine`, `FakeWatchTransport`, `FakeLicenseProvider`, `FixedClock`, `SequentialIDGenerator`, `FixtureDecoder`.

Requirements for fakes: deterministic, inspectable (record every call in an array), and configurable to fail (`fake.failNextWith(.diskFull)`), because half the tests in this spec are error-path tests.

**Fixtures:**

```swift
public enum ProjectFixtures {
    public static func tiny() -> AudiobookProject                 // 2 chapters × 3 ¶, all recorded
    public static func typical() -> AudiobookProject              // 12 chapters × ~90 ¶, 42% recorded, 18 flagged
    public static func stress(paragraphs: Int = 10_000) -> AudiobookProject
    public static func aiTainted() -> AudiobookProject            // one SELECTED aiImported take
    public static func aiUnselected() -> AudiobookProject         // aiImported take present but NOT selected
    public static func drifted() -> AudiobookProject              // cosmetic + minor + semantic drift cases
    public static func librivoxReady() -> AudiobookProject        // disclaimers recorded, rights attested
    public static func retailReady() -> AudiobookProject          // credits + sample + mastered-quality metrics
    public static func brokenIntegrity() -> AudiobookProject      // duplicate ordinals, missing asset, hash mismatch
}

public enum AudioFixtures {
    public static func tone(hz: Double, seconds: Double, dbfs: Double, sampleRate: Double) -> [Float]
    public static func speechLike(seconds: Double, rmsDBFS: Double, noiseFloorDBFS: Double) -> [Float]
    public static func clipped(seconds: Double) -> [Float]
    public static func withSilence(head: Double, tail: Double, body: [Float]) -> [Float]
    public static func writeWAV(_ samples: [Float], sampleRate: Double, to url: URL) throws
}
```

`speechLike` is important: it generates band-limited noise bursts with pauses so silence detection, noise floor, and RMS have realistic material. Metrics tests assert against the *known* generated values within tolerance (±0.5 dB).

### 19.3 Core suites (Swift Testing) — required tests

**Domain**
- `DomainCodingTests` — JSON round-trip of `AudiobookProject`, every `AudioOrigin` case in both JSON and flat storage form, `ReviewEvent`, `ValidationReport`.
- `EligibilityProfileTests` — human-only → eligible; one selected `aiImported` → ineligible with the paragraph listed; `aiImported` present but unselected → eligible; `unknownImport` selected → ineligible.
- `ProjectIntegrityTests` — each `IntegrityCode` produced by a purpose-built broken fixture; repairs applied yield a clean check.

**Package & store**
- `ProjectPackageTests` — create/open/move/copy; copy excludes caches; missing asset → finding; `schemaTooNew`.
- `AssetStoreTests` — dedupe on identical bytes, streaming hash equals in-memory hash, trash instead of delete, disk-full mapping.
- `SchemaMigrationTests` — migration 1 from empty; a captured v1 snapshot migrates forward; every migration is idempotent when re-run against an already-migrated DB.
- `ProductionStoreTests` — granular mutations do not rewrite the project; `counts()` matches a brute-force count over `load()`; `paragraphIDs(matching:order:)` matches `ReviewQueueResolver.resolve`.

**Timing budgets** — these live in the dedicated `VoxglassPerformanceTests` target as **one consolidated `@Suite(.serialized)`** (`PerformanceBudgetTests`) gated behind `VOXGLASS_TIMING_TESTS=1`, and run serially (`VOXGLASS_TIMING_TESTS=1 swift test --no-parallel --filter VoxglassPerformanceTests`) so parallel-suite CPU contention cannot produce a false failure. Because `swift test` runs test targets in parallel, a plain `swift test` would skew these budgets; the environment gate makes it impossible to run them un-serialized (a plain `swift test` reports them skipped), and **all** logic suites currently run serialized (`swift test --no-parallel --skip VoxglassPerformanceTests`) — a temporary policy until the load-sensitive suites are made load-independent. Each budget is asserted as the **best of several runs** so transient CI-runner jitter is likewise discounted; the budget measures the engine's best-case throughput:
- `paragraphSummaries` on the 10,000-¶ fixture < 120 ms; `counts()` < 20 ms.
- Metrics for a 30-second take < 150 ms.
- The 10,000-¶ re-import completes < 2 s.
- §19.8 render-count probe: the meter sustains > 100 invalidations while the teleprompter stays < 3. It pumps the runloop until the meter has actually invalidated past the budget (machine-speed independent), so a slow CI runner cannot produce a false failure.

**Deviation (recorded in §22.4):** serialization removes the contention the test run itself creates, but a shared dev machine can still be saturated by unrelated processes, and an absolute wall-clock budget then fails regardless of engine speed. The four wall-clock budgets (metrics, summaries, counts, re-import) are therefore asserted as a **ratio between two input sizes of the same workload** (30 s vs 3 s audio; 10 K vs 1 K rows/paragraphs): the ratio is ~10 under any uniform machine load and blows past the 12× margin on a superlinear regression, while a loose absolute ceiling (3× the numbers above) still fails gross slowdowns.

**Text**
- `ImporterTests` — one fixture document per format (`.txt`, `.md`, `.epub`, `.docx`) with a known expected chapter/paragraph shape; malformed EPUB falls back without throwing.
- `SegmenterTests` — heading detection table; scene-break detection; verse mode; front matter; re-import preserves unchanged IDs. (The 10,000-¶ re-import budget lives in `SegmenterPerformanceTests`, §19.3.)
- `ReidentificationTests` — insert/delete/move/edit scenarios with expected assignment maps; a paragraph edited beyond threshold becomes new + retired, not silently matched.
- `TextDriftTests` — the classification table: identical → `.none`; smart quotes → `.cosmetic`; one word typo → `.minor`; sentence rewritten → `.semantic`; "three" → "four" → `.semantic`.
- `SplitMergeTests` — takes stay with the first half; notes copied; merge keeps the first ID and archives the second's takes; undo restores exactly.
- `ScriptGeneratorTests` — LibriVox long/short forms, translator variant, final-section outro, retail credits; applying twice is a no-op; metadata change marks stale.

**Audio math**
- `MetricsCalculatorTests` — for each generated fixture, assert peak/RMS/noise floor/clip count/DC/silence within tolerance; a file with no silence sets `noiseFloorReliable == false`; true peak of a full-scale square wave exceeds sample peak. (The 30 s metrics budget lives in `AudioMetricsPerformanceTests`, §19.3.)
- `SilenceSegmenterTests` — a known 12-gap file yields 12 boundaries; confidence classification; `targetCount` trimming keeps the largest silences.
- `ReplayGainTests` — a −20 dBFS pink-noise-like signal produces a gain near the expected value; the function is monotonic in input level.

**Assembly**
- `SegmentQueueTests` — every `PlaybackMode` → expected segments; gaps applied; scene-break extra gap; context segments when enabled; unrecorded paragraphs skipped.
- `RenderCacheKeyTests` — key is stable across two process invocations (compute, write to a file in test A, compare in test B via a fixture constant), changes when any input changes, and is unchanged by irrelevant fields (paragraph text).
- `AssemblyDurationTests` — computed chapter duration equals the sum of trims + gaps within 1 ms.

**Review**
- `ReviewQueueResolverTests` — predicates × orders; SQL and in-memory agree.
- `ReviewEventFoldTests` — idempotency, tie-breaking, pickup stickiness, note-implies-flag, unknown types ignored.
- `OfflineEventQueueTests` — replaying a batch twice yields one note and one state.

**Validation**
- `ValidationRuleEngineTests` — **one test per rule code**, each with a minimal fixture that triggers exactly that code and asserts severity per target. Include `test_aiOriginBlocksLibriVox_AIblocksLibriVox` (the name is required by grep gate G-6).
- `ValidationDeterminismTests` — running twice on the same input yields identical issue IDs and order.
- `ValidationPerformanceTests` — 3,000-¶ project < 2 s.

**Destinations & packaging**
- `FilenameSanitizerTests` — the full table from §16.5 plus fuzz: 1,000 random Unicode titles must all produce `[a-z0-9_]+` of length ≤ 100.
- `IdentifierSuggesterTests` — validity rule, truncation, collision-free-ish suffixing.
- `DestinationProfileTests` — every profile's constants match §3's tables (this test is the executable copy of the research dossier; when a platform changes its rules, this test is what fails).
- `PackageBuilderTests` (with `FakeTranscoder`) — LibriVox: N files named correctly, durations file, checklist contains every required line, AI-tainted project throws before writing; IA: manifest fields, checksum file, test-collection switch, AI disclosure line; Retail: chapter files + sample + M4B request + masters + report.
- `ChecksumWriterTests` — output verifies with `shasum -a 256 -c` (shell out in the test only).

**License**
- `LicenseGateTests` — free export paths never touch the gate (assert via a `FakeLicenseProvider` that records every access and expecting zero for LibriVox/IA builds); retail export requires Pro; restore path; revoked entitlement reverts.

### 19.4 Studio integration suites

- `RecordingFlowTests` — with `FakeAudioCapture`: arm → record → stop → take inserted → metrics computed → selection applied → advance; crash-recovery path with a synthetic `session.json` and a truncated WAV (asserts `WAVHeaderRepair`).
- `TranscoderTests` — real encoders: MP3 CBR frame-header verification, FLAC bit-exact round-trip, AAC/M4B chapter marks readable back via `AVAsset`.
- `MasteringChainTests` — §16.7 assertions.
- `ExportEndToEndTests` — `librivoxReady()` fixture → real transcoder → real files on disk in a temp dir → re-validate the *output* files by decoding them and running the metrics engine, asserting the destination profile is met. **This is the highest-value test in the suite**: it proves the product's core claim.
- `ProjectionBuilderTests`, `ProjectionPolicyTests` (debounce, delta, hidden, tombstones), `SyncTokenRecoveryTests` (stale token), `SyncConflictTests`.
- `RenderCountProbeTests` — §11.3.

### 19.5 CarPlay smoke test (part of the iPhone smoke test)

CarPlay templates cannot be driven by XCUITest, so the CarPlay scene check is **folded into the iPhone smoke test**: it runs in the same iOS-simulator test action (`VoxglassCarPlaySmokeTests`, hosted in `Voxglass.app`) as `VoxglassUITests`. It is not a fifth UI test target and does not appear in the §19.1 topology as a separate smoke test.

```swift
import XCTest; import CarPlay; @testable import Voxglass

final class CarPlaySceneSmokeTests: XCTestCase {
    func test_buildsTabTemplate_andApproveEmitsOneEvent() throws {
        let env = CarPlayTestEnvironment(seed: .oneFlaggedQueue)
        let controller = CarPlayReviewController(store: env.store, sync: env.sync, player: env.player)
        let root = try XCTUnwrap(controller.makeRootTemplate() as? CPTabBarTemplate)
        XCTAssertEqual(root.templates.count, 3)                                  // Continue / Productions / Review
        let review = try XCTUnwrap(root.templates.compactMap { $0 as? CPListTemplate }.first { $0.title == "Review" })
        XCTAssertFalse(review.sections.first?.items.isEmpty ?? true)
        let nowPlaying = controller.startQueue(.flagged)
        XCTAssertTrue(nowPlaying.reviewButtonIDs.contains("carplay.approve"))
        controller.perform(.approveAndNext)
        XCTAssertEqual(env.sync.emittedEvents.map(\.type), [.approve])           // exactly one
        controller.perform(.approveAndNext)                                       // idempotence of the UI path
        XCTAssertEqual(env.sync.emittedEvents.count, 2)                           // different paragraph, not a duplicate
        XCTAssertEqual(Set(env.sync.emittedEvents.map(\.paragraphID)).count, 2)
        XCTAssertTrue(controller.remoteCommandMapping == .paragraphBoundaries)
    }
}
```

### 19.6 Device smoke tests

Convention for all five: launch with `-uiTestSeed <name>` and `-useTemporaryStore`; never touch the user's real projects, the microphone, CloudKit, or StoreKit. The only UI tests in the repository are these five — every other test is a Swift Testing suite run by `swift test`.

**macOS Studio — three smoke tests, one per audiobook destination.** Each drives the full create-and-import path and ends in the record workspace (the export surface is asserted in the destination walkthroughs, §20.13):

```swift
final class StudioSmokeUITests: XCTestCase {
    private func createAndImport(_ app: XCUIApplication, destination: String) throws {
        app.launchArguments = ["-uiTestSeed", "empty", "-useTemporaryStore"]
        app.launch()
        app.buttons["library.newAudiobook"].click()
        app.textFields["wizard.title"].click(); app.typeText("Smoke Book")
        app.textFields["wizard.author"].click(); app.typeText("Tester")
        app.textFields["wizard.narrator"].click(); app.typeText("Tester")
        app.popUpButtons["wizard.destination"].click()
        app.staticTexts[destination].click()
        app.buttons["wizard.continueToImport"].click()
        XCTAssertTrue(app.staticTexts["import.chapterCount"].waitForExistence(timeout: 5))
        app.buttons["import.acceptStructure"].click()
        XCTAssertTrue(app.buttons["dashboard.recordNext"].waitForExistence(timeout: 5))
    }

    func test_createLibrivoxAudiobook() throws {
        try createAndImport(XCUIApplication(), destination: "librivox")
    }

    func test_createInternetArchiveAudiobook() throws {
        try createAndImport(XCUIApplication(), destination: "internetArchive")
    }

    func test_createCommercialAudiobook() throws {
        try createAndImport(XCUIApplication(), destination: "acx")
    }
}
```

**iPhone:** the existing `VoxglassUITests` target — boot → all tabs render → a key surface is reachable. One smoke test.

**watchOS:** `-uiTestSeed watchQueue`, production → review flagged → player → approve → confirmation. Gotchas that this repo has already hit and that MUST be honored:
- rows need `.contentShape(Rectangle())` or taps miss;
- the confirmation is a **sheet**, not a `NavigationPath` destination;
- pre-boot the simulator and use `build`/`test-without-building` to avoid flaky first-launch timeouts;
- seeders must be idempotent because the runner may relaunch the app.

**Seeds:**

```swift
public enum UITestSeed: String {
    case empty                 // no projects; bundled fixture .txt auto-selected in import
    case onePreviewProject     // one projection: "The Murder of Roger Ackroyd", 18 flagged
    case watchQueue            // FakeWatchTransport preloaded with an 18-item flagged queue + audio
    case oneFlaggedQueue       // CarPlay (folded into the iPhone smoke test)
    case librivoxReady         // for manual export walkthroughs
}
```

Seeds MUST be defined in one place shared by all targets, and MUST be no-ops in release builds (`#if DEBUG` around the seeding code, with the enum itself compiled always so the CI gate can find it).

### 19.7 Performance budgets

Asserted with XCTest `measure` where practical, otherwise with explicit timing assertions.

| Operation | Budget |
|---|---|
| Library first render after DB open | < 500 ms |
| Project open (10,000 ¶) to Dashboard interactive | < 1.5 s |
| Paragraph selection → teleprompter updated | < 100 ms |
| Record start after engine prepared | < 250 ms |
| Paragraph-boundary gap accuracy | configured gap ± 50 ms |
| Review action → visual feedback | < 100 ms |
| `paragraphSummaries` (10,000 ¶) | < 120 ms |
| Full validation (3,000 ¶, metrics present) | < 2 s |
| Metrics for a 30 s take | < 150 ms |
| Chapter render (60 min of audio) | < 90 s |
| MP3 transcode (60 min) | < 60 s |
| Projection publish delta (1 changed ¶) | < 3 s to CloudKit ack |
| SwiftUI invalidations during 5 s of recording (teleprompter) | < 3 |

### 19.8 Render-count probe

```swift
final class RenderCounter { nonisolated(unsafe) static var counts: [String: Int] = [:] }
extension View { func countRenders(_ key: String) -> some View { RenderCounter.counts[key, default: 0] += 1; return self } }
```

Used only in DEBUG. `RenderCountProbeTests` drives a 5-second fake recording and asserts the teleprompter's count stays below 3 while the meter's count exceeds 100 — proving the isolation works rather than merely that nothing crashed.

### 19.9 CI gates

Implement as `scripts/guard_production.sh`, invoked from `.github/workflows/ios.yml` (extended with a `macos` build job for the Studio scheme). Each gate prints the offending file:line and exits non-zero.

| # | Gate | Rule |
|---|---|---|
| **G-1** | No synthesis | In all app and Core sources: no `import MLX`, `import CoreML`, and no symbol matching `TTS\|Synthesi[sz]\|VoiceModel\|Kokoro\|Chatterbox\|CosyVoice\|voiceClone\|AVSpeechSynthesizer`. |
| **G-2** | Pro-gate placement | `LicenseGate\|\.isPro\|ProFeature\|EntitlementState` must not appear in files matching `Recording*\|Review*\|Preview*\|Capture*\|Assembly*\|Segment*\|Sync*\|Watch*\|CarPlay*\|Validation*`. |
| **G-3** | No `ObservableObject` | New files under `Voxglass/Core/Production`, `VoxglassStudio`, `Voxglass/Features/Production`, `VoxglassWatch/Production` must not contain `ObservableObject`. |
| **G-4** | Stable hashing | Under `Production/Package`, `Production/Packaging`, `Production/Assembly`: no `Hasher()` or `.hashValue`; each of those directories must contain at least one `SHA256Hex` reference. |
| **G-5** | Watch isolation | `VoxglassWatch/**` must not contain `import CloudKit`. |
| **G-6** | Eligibility wired | `LibriVoxPackageBuilder.swift` must contain `EligibilityProfile.evaluate`; the Core test target must contain a test named matching `AIblocksLibriVox`. |
| **G-7** | Determinism seams | Under `Voxglass/Core/Production`: no bare `Date()` or `UUID()` (allow `// determinism-exempt:` on the same line for the two generator implementations). |
| **G-8** | Tests never touch real services | `VoxglassStudio/**` must contain `isTestEnvironment` handling; UI test files must contain `-uiTestSeed`. |
| **G-9** | No test support in shipping targets | App target sources must not `import VoxglassCoreTestSupport`. |
| **G-10** | Destination constants centralized | Literal `128`, `192`, `44100`, `-23`, `-18`, `-60`, `-3.0` must not appear in `Validation/**` or `Packaging/**` outside `Destinations/DestinationProfiles.swift` and `Destinations/ValidationThresholds.swift`. (Prevents the research from drifting into scattered magic numbers.) |
| **G-11** | Legal strings centralized | The literal strings from §3.6 must appear only in `Destinations/LegalStrings.swift`. |
| **G-12** | No auto-upload | No `archive.org`, `librivox.org`, or `acx.com` URL is passed to `URLSession` upload/data-task APIs anywhere. Only string generation is permitted. |
| **G-19** | The gates can fail | `scripts/test_guards.sh` MUST plant a probe for each grep gate and assert the guard catches it, then assert the guard passes without it. Runs in CI immediately before `guard_production.sh`. A gate that cannot fail is not a gate. (Numbered G-19 because G-13…G-18 are taken by the discovery gates; the gap plan's provisional label "G-13" was superseded.) |

CI jobs — **GitHub Actions runs no UI tests and no simulator tests.** The only test job is `swift test`, fully serialized (`swift test --no-parallel` for all logic suites, plus `VoxglassPerformanceTests` via `VOXGLASS_TIMING_TESTS=1 swift test --no-parallel --filter VoxglassPerformanceTests` — both Swift Testing on the macOS host). Serialization is a deliberate temporary policy: `swift test` runs test targets in parallel by default and load-sensitive suites (playback seek timing, performance budgets, audio metrics) produce false failures under runner CPU contention; run everything serially until those suites are made load-independent. The UI smoke tests never run in CI; they are the local pre-commit gate, and `swift test` runs on every push (pre-push hook).

```yaml
jobs:
  guards:      # ubuntu-latest, ~30 s — grep gates only
  core-tests:  # macos-latest — swift test --no-parallel --skip VoxglassPerformanceTests (all suites serial) + swift test --no-parallel --filter VoxglassPerformanceTests (serial timing); no simulator
  build-ios:   # macos-latest — existing
  build-watch: # macos-latest — existing
  build-mac:   # macos-latest — xcodebuild build -scheme VoxglassStudio -destination generic/platform=macOS
```

The five UI smoke tests remain local (`scripts/test.sh --all`: `VoxglassUITests` + `VoxglassCarPlaySmokeTests` on the iPhone simulator, `VoxglassWatchUITests` on the watch simulator, and `VoxglassStudioUITests` on the host Mac).

### 19.10 Manual test matrix (human, per release)

| # | Scenario | Pass condition |
|---|---|---|
| M-1 | Record 100 paragraphs in one sitting with a real interface | No take lost; every take has metrics; app memory stable |
| M-2 | Unplug the interface mid-take | Take preserved, clear error, engine recovers on replug |
| M-3 | Force-quit during a take | Recovery sheet offers the take; accepting yields playable audio |
| M-4 | Fill the disk during a take | Specific disk-full error; existing audio intact |
| M-5 | Review 20 flagged paragraphs on iPhone offline, then reconnect | All 20 states land on the Mac exactly once |
| M-6 | Review on the watch with the phone in another room | Actions queue; sync on return; no duplicates |
| M-7 | CarPlay session in a real car, 15 minutes | No template rejections; paragraph transport correct; no free-text prompts |
| M-8 | LibriVox export of a 12-chapter book | Files play; bitrate/CBR/sample rate verified externally; checklist complete |
| M-9 | IA export + actual manual upload to `test_collection` | Item derives correctly; metadata as intended |
| M-10 | Retail export + external ACX-style check | RMS/peak/noise floor within spec on every file |
| M-11 | Purchase Pro, then restore on a second Mac | Pro active without re-purchase |
| M-12 | VoiceOver pass over all four surfaces | Every control reachable and meaningfully labeled |
---

## 20. Stage plan

Twelve stages, each one reviewable commit (or a small ordered series). Every stage lists what to add, what to test, and the acceptance assertion. **Do not start a stage until the previous stage's acceptance passes.**

Commit subject convention: `feat(studio): S<N> — <summary>` with a body listing the acceptance criterion.

### S1 — Scaffolding and domain

**Add**
- `Package.swift` → tools 6.0; add `VoxglassCoreTestSupport` target; per-target language modes (§4.4).
- `project.yml` → `VoxglassStudio` app target (macOS 14, Swift 6, entitlements §4.9, UTType §4.8), `VoxglassStudioTests`, `VoxglassStudioUITests`; run `xcodegen generate`.
- `Voxglass/Core/Production/Domain/**` — all of §5: primitives, project, chapter, paragraph, take, origin (+explicit Codable), review types, eligibility, rights, source document, destination types, integrity.
- `Clock`, `IDGenerator`, `SHA256Hex`.
- `VoxglassCoreTestSupport` with `ProjectFixtures` (tiny, typical, stress, aiTainted, aiUnselected, drifted, brokenIntegrity) and `FixedClock`/`SequentialIDGenerator`.

**Test** `DomainCodingTests`, `EligibilityProfileTests`, `ProjectIntegrityTests`.

**Accept** The 10,000-¶ stress fixture builds and JSON-round-trips in < 1 s; an AI-tainted fixture reports `librivoxEligible == false` and lists the paragraph; an unselected AI take does not.

### S2 — Package and store

**Add** `Production/Package/**` (`FileAssetStore`, `ProjectPackage`, `PackageManifest`, `WAVHeaderRepair`, `StorageAnalyzer`), `Production/Store/**` (`ProjectDatabase`, `ProductionMigration` v1, `SQLiteProductionStore`, `InMemoryProductionStore`).

**Test** `ProjectPackageTests`, `AssetStoreTests`, `SchemaMigrationTests`, `ProductionStoreTests`, `StorePerformanceTests`.

**Accept** Create/open/move/copy/verify a project; the 10,000-¶ fixture saves and reloads; `counts()` matches a brute-force count; copy excludes caches.

### S3 — Text pipeline

**Add** `Production/Text/**`: `TextNormalizer`, importers (TXT, Markdown, minimal ZIP reader, EPUB, DOCX), `Segmenter`, `ParagraphReidentifier`, `TextDriftDetector`, `ParagraphSplitter`, script generators (§10) and `ScriptApplier`.

**Test** `ImporterTests`, `SegmenterTests`, `ReidentificationTests`, `TextDriftTests`, `SplitMergeTests`, `ScriptGeneratorTests`.

**Accept** Re-importing an edited EPUB preserves IDs for unchanged paragraphs, marks semantic edits `needsPickup`, and never silently loses a recorded paragraph.

### S4 — Studio shell, library, wizard, source import

**Add** `VoxglassStudio/App/**` (`StudioApp`, `StudioEnvironment`, launch-arg seeding, `StudioCommands`), `Features/Library`, `Features/NewProject`, `Features/SourceImport`. Recents store with security-scoped bookmarks.

**Test** `ProjectLibraryModelTests`, `NewProjectModelTests`, `SourceImportModelTests`.

**Accept** The macOS smoke test (§19.6) passes as far as the Dashboard; a project created by the wizard opens cleanly after relaunch.

### S5 — Recording and takes

**Add** `Production/Audio/**` (protocols, `AudioMetricsCalculator`, `SilenceSegmenter`, ReplayGain), `VoxglassStudio/Services/AVAudioEngineCapture`, `AVMetricsCalculator`, `Features/Record` (`RecordingModel`, `RecordingMeter`, workspace view), `Features/ImportAudio`, `Features/TakeCompare`, autosave/recovery.

**Test** `MetricsCalculatorTests`, `SilenceSegmenterTests`, `ReplayGainTests`, `RecordingFlowTests`, `RenderCountProbeTests`, `ImportAssignmentTests`, `AIOriginLabelTests`.

**Accept** 100 sequential paragraphs recorded without loss (automated with `FakeAudioCapture`, then verified manually per M-1); forced termination recovers the last take; importing an AI-labeled file flips eligibility.

### S6 — Assembly, render, playback, Mac review

**Add** `Production/Assembly/**`, `Production/Review/**`, `VoxglassStudio/Services/AVSegmentPlayer`, `AVChapterRenderer`, `Features/Assemble`, `Features/Review`, `Features/Dashboard`.

**Test** `SegmentQueueTests`, `RenderCacheKeyTests`, `AssemblyDurationTests`, `ReviewQueueResolverTests`, `ReviewEventFoldTests`.

**Accept** A flagged queue plays hands-free across chapters; prev/next always means paragraph; changing one paragraph invalidates exactly one chapter render.

### S7 — Validation and destinations

**Add** `Production/Destinations/**` (profiles, thresholds, legal strings, `FilenameSanitizer`, `IdentifierSuggester`), `Production/Validation/**`, `Features/Validate`, `Features/Metadata`.

**Test** `DestinationProfileTests`, `ValidationRuleEngineTests` (one per code), `ValidationDeterminismTests`, `ValidationPerformanceTests`, `FilenameSanitizerTests`, `IdentifierSuggesterTests`.

**Accept** Every rule in §15.3 has a passing test; validation of the `typical()` fixture for all five destinations completes in < 2 s and is deterministic.

### S8 — Encoders and packaging

**Add** `Tools/encoders/build-encoders.sh`, the LAME/FLAC xcframeworks and Swift wrappers, `VoxTranscoder`, `ID3Writer`, MPEG-4/Vorbis/RIFF tagging, `MasteringChain`, the three package builders, `ChecksumWriter`, checklist and manifest generators, `ThirdPartyNotices.md`.

**Test** `TranscoderCBRTests`, `TranscoderFLACTests`, `TranscoderAvailabilityTests`, `TaggingTests`, `MasteringChainTests`, `PackageBuilderTests`, `ChecksumWriterTests`, `ExportEndToEndTests`.

**Accept** A `librivoxReady()` fixture produces MP3s that decode to 44.1 kHz mono, verify as CBR 128 by frame-header inspection, carry correct ID3 tags and filenames, and pass a re-validation of the *output*.

### S9 — Export wizard and the Pro gate

**Add** `Production/License/**`, `StoreKitLicenseProvider`, `Features/Export`, `Features/Settings` (all five tabs), the purchase and restore flows, the StoreKit configuration file for local testing.

**Test** `LicenseGateTests`, `ExportModelTests` (gate checked exactly once, at step 2→3; selections preserved across purchase), plus grep gate G-2 green.

**Accept** LibriVox and IA exports complete with a `FakeLicenseProvider` that fails on any access (proving the free path never consults it); retail export requires Pro and resumes after purchase.

### S10 — CloudKit projection and the iPhone

**Add** `Production/Sync/**`, `CloudKitProductionSync` (Mac + phone), `ProjectionPublisher`, `EventIngestor`, `Features/DevicePreview` (Mac), `Voxglass/Features/Production/**` (phone screens 01–07), `ProductionPreviewStore`, phone outbox.

**Test** `ProjectionBuilderTests`, `ProjectionPolicyTests`, `ProjectionRoundTripTests`, `OfflineEventQueueTests`, `SyncTokenRecoveryTests`, `SyncConflictTests`; the iPhone smoke test.

**Accept** A newly accepted take on the Mac appears on the phone without an export; offline review notes sync exactly once; a stale change token recovers silently.

### S11 — Watch relay

**Add** `Production/WatchLink/**`, `WatchConnectivityTransport` (both sides), `VoxglassWatch/Production/**` (screens 01–10), `WatchSegmentPlayer`, watch outbox and storage cap, dictation flow.

**Test** `WatchPayloadTests`, `WatchEventRelayTests`, `WatchNoCloudKitTests` (+ gate G-5); the watch smoke test.

**Accept** An offline watch action reaches the Mac via the phone exactly once; the watch never initializes CloudKit; the offline queue plays with the phone powered off.

### S12 — CarPlay, hardening, and release prep

**Add** CarPlay production templates and `CarPlayReviewController`; audio-confirmation cues; accessibility audit fixes; migration matrix tests; performance harness; diagnostics bundle; `RELEASE_CHECKLIST.md`; App Store metadata and screenshots.

**Test** `CarPlayTemplateTests` + the CarPlay smoke test; `MigrationMatrixTests`; `PerformanceBudgetTests`; `AccessibilityAuditTests`.

**Accept** All five UI smoke tests green; all Core suites green via `swift test`; all eighteen grep gates passing; the three walkthroughs in §20.13 executed on hardware.

### 20.13 End-to-end acceptance walkthroughs (human)

**W-1 — LibriVox, free.** Create a project from a Gutenberg `.txt`; accept structure; apply LibriVox disclaimers; record chapter 1 including intro and outro; review one paragraph on the phone and flag it; fix it on the Mac; validate for LibriVox (expect clean); export chapter 1 only; verify the MP3 is 128 kbps CBR / 44.1 kHz / mono, correctly named and tagged; confirm the checklist lists every section with its duration. **No purchase prompt may appear at any point.**

**W-2 — Internet Archive, free.** Same project; set an identifier and license URL; export with FLAC masters and MP3 derivatives and the test-collection profile; verify the manifest, the checksum file, and the generated `ia upload` command; manually upload to `test_collection` and confirm the item derives.

**W-3 — Retail, Pro.** Switch the purpose to commercial; add credits via the generator and record them; set a retail sample; validate for ACX (expect specific failures on a deliberately hot take); fix; purchase Pro in the sandbox; export; verify every chapter file measures RMS in [−23, −18], true peak ≤ −3, noise floor ≤ −60; verify the M4B's chapter marks in a player; verify the retail sample's duration and that it does not begin with credits.

---

## 21. Release and operations

### 21.1 Versioning

- `MARKETING_VERSION` is shared across all targets (currently `1.1`); the Studio app ships as `1.0` at first release with its own `MARKETING_VERSION` override, since it is a new product.
- `CURRENT_PROJECT_VERSION` increments per submission. The TestFlight job derives it from the commit history (`.github/workflows/ios.yml`: `build_number="$(git rev-list --count HEAD)"`, stamped as `CURRENT_PROJECT_VERSION` under the single marketing version `1.1`), so every TestFlight build groups under version 1.1, newest on top.
- **Build-number correlation.** The `.githooks/commit-msg` hook appends `Build <n>` to every commit message, where `<n>` is the commit's position in history (`count(HEAD) + 1`). A push's TestFlight build number therefore equals the number stamped on the pushed tip commit's message — look at the commit on GitHub to find the TestFlight build, and vice versa. (Commits created outside the local hooks, e.g. GitHub web merges, still get a CI-derived number but no stamped message.)
- The `.voxproject` `packageFormatVersion` and the DB `schemaVersion` are independent of marketing version and change only on real format changes.

### 21.2 App Store considerations

- **Two apps or one?** VoxglassStudio is a separate macOS app with its own App Store listing and its own IAP. The iOS Voxglass app gains production preview for free. Cross-purchase between them is not attempted (StoreKit universal purchase would require a single app record across platforms; the Studio's $149 IAP is Mac-only and the phone app never needs Pro).
- **GPLv3 + App Store.** Ship `LICENSE`, `LICENSE-APPSTORE-EXCEPTION.md`, and `ThirdPartyNotices.md` inside the app bundle and link them from Settings → About. Include the written offer for corresponding source with the repository URL.
- **Review notes for Apple:** explain that the app records the user's own narration, that no content is uploaded by the app, and that the $149 IAP unlocks professional export formats. Provide a demo project and a note that microphone access is required.
- **Privacy nutrition label:** Data not collected. Audio and text stay in the user's iCloud private database; no analytics SDK; no third-party network calls.
- **Export compliance:** `ITSAppUsesNonExemptEncryption: false` (matching the existing app).

### 21.3 Destination re-verification checklist (per release)

Because §3's constants are external, verify before each release and update the `// verified <date>` comments and `DestinationProfileTests`:

1. LibriVox Tech Specs page — bitrate, sample rate, channels, volume band.
2. LibriVox disclaimer wiki page — wording changes.
3. LibriVox AI policy page — any change to the prohibition.
4. ACX submission requirements — RMS/peak/noise floor, file length, credits, retail sample.
5. Internet Archive metadata and derivative docs — field names, `test_collection` behavior.
6. Apple Books / aggregator intake requirements — cover size, metadata fields.

Record the verification date and the outcome in `docs/voxglass-mvp/DESTINATION_VERIFICATION_LOG.md`.

### 21.4 `RELEASE_CHECKLIST.md` template

```markdown
# Voxglass Studio release checklist — v{version} ({date})

## Gates
- [ ] All Core suites green (`swift test`)
- [ ] All Studio/phone/watch suites green
- [ ] Five UI smoke tests green (`scripts/test.sh --all`)
- [ ] Eighteen CI grep gates green (`scripts/guard_production.sh`)
- [ ] Guard self-test green (`scripts/test_guards.sh` — proves each gate can fail)
- [ ] Performance budgets met (§19.7) on the reference machine

## Walkthroughs
- [ ] W-1 LibriVox (free)  — no purchase prompt observed
- [ ] W-2 Internet Archive (free) — test_collection item verified
- [ ] W-3 Retail (Pro) — output measured against ACX thresholds

## Destinations
- [ ] §21.3 re-verification completed; log updated

## Legal & licensing
- [ ] ThirdPartyNotices.md current (LAME, FLAC versions)
- [ ] Encoder build recipe reproducible from a clean checkout
- [ ] Legal strings unchanged or reviewed

## Store
- [ ] Screenshots for all screens shipped
- [ ] IAP configured, sandbox-tested, Family Sharing on
- [ ] Privacy label: data not collected
- [ ] Review notes include demo project + mic rationale

## Risk
- [ ] Known issues documented in RELEASE_NOTES.md
- [ ] Rollback plan: previous build ready in App Store Connect
```

### 21.5 Support surface

- **Diagnostics bundle** (§4.6) — a single `.zip` the user can send.
- **Project repair** — Verify Project + repairs is the first support instruction for any "something is wrong" report.
- **Never** ask a user to delete their `.voxproject` or its `Audio/Original` directory. Support instructions must always preserve originals.

---

## 22. Appendices

### 22.1 Accessibility identifier registry

Adding an interactive control requires adding its identifier here **and** to the smoke test if it is on a smoke path.

**macOS Studio**

```
library.newAudiobook · library.openPackage · library.project.<slug> · library.section.<case> · library.activity.<n>
wizard.title · wizard.author · wizard.narrator · wizard.purpose.<case> · wizard.rightsBasis.<case>
wizard.sourceURL · wizard.editionYear · wizard.attest · wizard.continueToImport · wizard.back · wizard.cancel
import.chapterCount · import.warningCount · import.acceptStructure · import.resegment
import.paragraph.<n> · import.splitHere.<n> · import.mergeNext.<n> · import.markSceneBreak
dashboard.recordNext · dashboard.previewOnDevices · dashboard.startReviewQueue · dashboard.openFeedback
dashboard.chapter.<n> · dashboard.progress
script.chapter.<n> · script.paragraph.<n> · script.save · script.find · script.split · script.merge
script.directionNote · script.pronunciation · script.reviewStatus · script.driftBanner
record.teleprompter · record.transport.record · record.transport.playTake · record.transport.playInContext
record.acceptAndNext · record.flagAndNext · record.previousParagraph · record.nextParagraph
record.take.<n> · record.importWAV · record.quality.peak · record.quality.noise · record.inputLevel
import.audio.origin.<case> · import.audio.method.<case> · import.audio.assign · import.originWarning
import.audio.addMarker · import.audio.removeMarker · import.audio.segment.<n>
compare.takeA · compare.takeB · compare.playAB · compare.useSelected
review.queue.item.<n> · review.approveAndNext · review.pickupAndNext · review.keepFlagged
review.note · review.autoAdvance · review.playContext · review.previousFlagged · review.nextFlagged
assemble.paragraphGap · assemble.headSilence · assemble.tailSilence · assemble.renderPreview
assemble.playChapter · assemble.rebuildChanged · assemble.row.<n>
metadata.tab.<case> · metadata.title · metadata.author · metadata.narrator · metadata.language
metadata.description · metadata.subjects · metadata.rightsBasis · metadata.sourceURL · metadata.attest
metadata.originAudit · metadata.artwork · metadata.identifier · metadata.save
preview.syncNow · preview.hideFromDevices · preview.autoSync · preview.includeText
preview.prepareOfflineQueue · preview.storageProfile · preview.openReviewQueue
validate.target.<case> · validate.runAgain · validate.fixNext · validate.issue.<n>
validate.severity.<case> · validate.goToParagraph.<n>
export.scope.<case> · export.destination.librivox · export.destination.internetArchive
export.destination.retail · export.unlockPro · export.run · export.cancel · export.revealInFinder
settings.tab.<case> · settings.inputDevice · settings.recordingFormat · settings.monitoring
settings.preRoll · settings.warnClipping · settings.autoMetrics · settings.recordTest
settings.purchasePro · settings.restorePurchases · settings.thirdPartyNotices · settings.copyDiagnostics
```

**iPhone**

```
shelf.myProductions · production.<slug>
detail.playWholeBook · detail.reviewFlagged · detail.mode.<case> · detail.chapter.<n>
player.flag · player.approve · player.pickup · player.addNote · player.autoAdvance
player.previousParagraph · player.nextParagraph · player.skipBack · player.skipForward · player.queue
paragraphList.filter.<case> · paragraphList.row.<n> · paragraphList.playSelected
queueBuilder.predicate.<case> · queueBuilder.autoAdvance · queueBuilder.skipApproved
queueBuilder.downloadToWatch · queueBuilder.start
note.category.<case> · note.text · note.dictate · note.save · note.cancel
sync.checkForUpdates · sync.downloadAll · sync.removeAudio · sync.refreshWatch · sync.pending
```

**watchOS**

```
watch.production.<slug> · watch.reviewFlagged · watch.queue.<case> · watch.continue
watch.player.flag · watch.player.approve · watch.player.pickup · watch.player.previous · watch.player.next
watch.player.autoNext · watch.paragraphText · watch.confirmation.approved · watch.confirmation.flagged
watch.confirmation.pickup · watch.playNext · watch.dictate · watch.dictation.category.<case>
watch.dictation.save · watch.dictation.redictate · watch.sync.status · watch.offline.start
watch.offline.remove
```

**CarPlay**

```
carplay.tab.<case> · carplay.production.<slug> · carplay.queue.<case>
carplay.approve · carplay.pickup · carplay.keepFlagged · carplay.playNext · carplay.undo
carplay.settings.autoAdvance · carplay.settings.playContext · carplay.settings.audioConfirmations
```

### 22.2 Legal strings

See §3.6 for the canonical table. All live in `Production/Destinations/LegalStrings.swift`:

```swift
public enum LegalStrings {
    public static let noCopyrightDetermination = "Voxglass does not determine copyright status."
    public static let noAcceptanceGuarantee = "Voxglass prepares files; it does not guarantee acceptance or determine copyright."
    public static let librivoxHumanOnly = "LibriVox accepts only recordings made by human volunteers using their own voices. This project contains imported AI-generated audio and is not eligible."
    public static let userSubmits = "You submit these files yourself. Voxglass never uploads on your behalf."
    public static let aiDisclosure = "Contains narration generated or processed with AI voice technology."
}
```

### 22.3 Error and issue code index

Error codes are `<AREA>.<CODE>`: `PKG.*` (package), `STR.*` (store), `CAP.*` (capture), `TRN.*` (transcode), `PKGING.*` (packaging), `SYNC.*`, `LIC.*`.

Issue codes are the `IssueCode` raw values from §15.3, grouped: metadata/rights (16), origin (3), structure (17), audio quality (16), loudness (1) — **53 rules total**. Every one has a test.

### 22.4 Deviations from the mockups

Recorded deliberately; update the mockups when convenient.

| Mockup | Mockup says | Implementation | Why |
|---|---|---|---|
| `08-carplay-review-settings` | "Voice confirmations — Speak 'approved,' 'flagged,' or 'pickup.'" | "Audio confirmations" — three bundled tones | Speech synthesis is banned by the product's non-AI rule and CI gate G-1 (§18.3 rule 6) |
| `07-import-audio` | "Assign entire file to chapter" | "Split file across this chapter" | Spanning takes break paragraph addressing (§11.5) |
| `14-export-wizard` | Retail card says "Pro · $149" | unchanged | — |
| `12-device-preview` | "AAC mono · 80 kbps" | configurable 48/64/80/128, default 80 | quota control (§13.4) |
| `03-source-import` | "312 sections detected" | shows both section and paragraph counts | the smoke test keys on `import.chapterCount` |
| `13.6 WatchTransport` | protocol has no `sendEvents` member | `sendEvents(_ events: [ReviewEvent])` added | the watch outbox must have a defined way to transfer offline events to the phone; the transport-mapping table (§13.6) already routes events watch→phone via `transferUserInfo`, so the protocol now names it |
| `01-productions-list` | card shows short title "Roger Ackroyd" | card shows the full `ProjectSummary.title` ("The Murder of Roger Ackroyd"); the a11y slug stays `rogerAckroyd` | `ProjectSummary` carries only one title; the smoke contract keys on `watch.production.rogerAckroyd` (§19.6) |
| `07-dictation-category` | "Tap to dictate" uses `.dictation` input mode | uses `WKTextInputMode.plain` via `WKInterfaceController.presentTextInputController` | current WatchKit SDKs have no `.dictation` mode; plain text input is already dictation-based on watchOS |
| `19.3 timing budgets` | absolute wall-clock budgets (e.g. 30 s metrics < 150 ms) | ratio-based: large-vs-small workload ratio ≤ 12× plus a 3× absolute ceiling | an absolute budget on a shared dev machine fails under unrelated-process load regardless of engine speed; the ratio is load-independent and still catches superlinear regressions (§19.3) |
| §22.1 registry | `script.chapter.`/`script.save`/`script.directionNote`/`script.pronunciation`/`script.reviewStatus` identifiers | not shipped as controls | the Script Editor's chapter list is a plain `List`; text is debounce-flushed (no explicit save); direction/pronunciation/review-status are shown by state chips, not controls |
| §22.1 registry | `record.acceptAndNext`/`record.flagAndNext`/`record.transport.playTake`/`record.transport.playInContext` identifiers | not shipped as on-screen buttons | the §11.4 keyboard table drives these (Return / ⌘Return / ⌥Space / ⇧Space) with no visible button; a keyboard shortcut is not an accessibility control |
| §22.1 registry | `import.resegment`/`import.paragraph.`/`import.splitHere.`/`import.mergeNext.`/`import.markSceneBreak` identifiers | not implemented | re-segmentation, per-paragraph editing, and split/merge/scene-break gestures at import are post-MVP; the F-26 marker workflow (add/remove marker, segment table) is the shipped slice |
| §22.1 registry | `library.activity.` identifier | not implemented | the Production Activity feed (§18.1.2) is not shipped; the sidebar sections ship without the feed |
| §22.1 registry | `dashboard.openFeedback`/`dashboard.chapter.`/`dashboard.progress` identifiers | not shipped as controls | the dashboard's feedback feed, per-chapter rows, and progress ring carry no identifiers (visual-only) |
| §22.1 registry | `metadata.subjects`/`metadata.rightsBasis` identifiers | not shipped as controls | the subjects field and rights picker exist but carry no identifier; the Artwork tab (F-28) is the shipped new surface |
| §22.1 registry | `note.dictate` identifier | not shipped | dictation is a watch-only affordance; the phone note sheet has no dictation control |
| §22.1 registry | `carplay.playNext`/`carplay.undo` identifiers | not shipped | `CPAlertTemplate` actions expose no identifiers |

> **§22.4 enforcement.** `AccessibilityAuditTests.documentedAbsences` is the
> executable copy of the rows above: each entry must exist here (with its
> reason) before the test will ignore it, and adding the control requires
> deleting the row from both places.

### 22.5 Deferred backlog (post-MVP, in rough priority order)

1. Direct upload integrations (archive.org S3-like API first, since it has a clean token model).
2. Proof-listener sharing via CloudKit shared database (a second person reviews your project without a Mac).
3. Punch-in recording within a take.
4. Multi-narrator projects and dramatic readings.
5. Forced alignment for automatic paragraph splitting of long imported files.
6. iPad Studio.
7. Per-language narration-rate estimates.
8. Chapter-level M4B for very long books; audiobook series metadata.
9. Noise reduction as an explicit, disclosed processing step.
10. Swift 6 migration of the existing consumer targets.

### 22.6 Risk register

| Risk | Impact | Mitigation |
|---|---|---|
| Encoder framework build is harder than expected (signing, universal binaries) | Blocks all export | S8 is scheduled before the sync stages so it is discovered early; the ffmpeg-helper fallback (§16.3) is fully specified |
| LibriVox or ACX changes a requirement | Silent non-compliance | `DestinationProfileTests` is the executable copy of the research; §21.3 re-verification per release |
| CloudKit quota on large books | Sync silently stops | Estimates shown before publish; hide-from-devices; bitrate control; explicit quota error copy |
| watchOS UI test flakiness in the local gate | Slows every push | Documented gotchas (§19.6); pre-booted simulator; `test-without-building` |
| Pro gate leaks into free paths during refactors | Product-principle violation | Grep gate G-2 + `LicenseGateTests` asserting zero accesses on free paths |
| Paragraph re-identification mis-matches after a big source edit | Recorded audio attached to the wrong text | Conservative thresholds; retirement is non-destructive; the re-import summary sheet requires explicit confirmation |
| Audio thread violations cause dropouts | Lost or glitched takes | Tap discipline (§11.2 rule 3); ring buffer; overrun counter surfaced |
| App-wide SwiftUI invalidation returns | Unusable recording UI | `RecordingMeter` isolation + `RenderCountProbeTests` |
| GPL/App Store licensing challenge | Distribution blocked | LGPL-only encoders, dynamic linking, notices, written offer (§16.3) |
| Scope creep into AI narration | Product identity and LibriVox eligibility | CI gate G-1; `aiImported` is provenance only, with no generation path |
| A grep gate silently stops matching (broken regex, missing search root, self-defeating exclusion) | The product's defining rules go unenforced | G-19 self-test (`scripts/test_guards.sh`) plants a probe per gate and asserts the guard fails on it |

### 22.7 Reading list for the implementing agent

Repository files worth reading before starting:

- `Voxglass/Core/Database/AppDatabase.swift` and `DatabaseMigrations.swift` — the persistence idiom to copy.
- `Voxglass/Core/BiquadFilter.swift` — reuse for the high-pass filter. **Not reused for ReplayGain** — see the §11.6.8 deviation note (Float vs Double, and the Yule stage is a direct-form section, not a biquad).
- `Voxglass/App/CarPlay/**` and `Voxglass/Core/CarPlay/**` — the existing CarPlay layering to extend.
- `Voxglass/Core/CloudKitSyncEngine.swift` and `CloudKitRecordMapper.swift` — the existing sync idiom, including the stale-token recovery to replicate.
- `VoxglassWatch/WatchAudioRelay.swift`, `WatchPlaybackEngine.swift`, `WatchStorageManager.swift` — the watch relay and storage patterns already in place.
- `scripts/test.sh` and `scripts/guard_wiring.sh` — the local gate and the existing grep-gate style.
- `project.yml` — target definitions and entitlement wiring.

---

### 22.8 First-session quickstart for the implementing agent

Exact commands for the first hour of S1. Run from the repository root.

```bash
# 1. Confirm the toolchain and the existing gates are green before changing anything.
swift build
swift test --filter VoxglassCoreTests
xcodebuild build -project Voxglass.xcodeproj -scheme Voxglass \
  -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO

# 2. Create the new source trees.
mkdir -p Voxglass/Core/Production/{Domain,Package,Store,Text,Audio,Assembly,Review,Validation,Destinations,Packaging,Sync,WatchLink,License}
mkdir -p VoxglassCoreTestSupport/{Fakes,Fixtures}
mkdir -p VoxglassStudio/{App,Services,Features}
mkdir -p VoxglassStudioTests VoxglassStudioUITests

# 3. Edit Package.swift (tools 6.0 + VoxglassCoreTestSupport) and project.yml
#    (VoxglassStudio app + test targets), then regenerate.
xcodegen generate

# 4. Verify the new scheme builds empty.
xcodebuild build -project Voxglass.xcodeproj -scheme VoxglassStudio \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO

# 5. Add the guard script and wire it into CI.
cp scripts/guard_wiring.sh scripts/guard_production.sh   # start from the existing style
./scripts/guard_production.sh
```

Then implement §5 in `Voxglass/Core/Production/Domain/` in this file order, compiling after each: `Clock.swift`, `IDGenerator.swift`, `SHA256Hex.swift`, `AudioAssetReference.swift`, `BookMetadata.swift`, `RightsEvidence.swift`, `SourceDocument.swift`, `Take.swift` (+`AudioOrigin`), `Paragraph.swift`, `Chapter.swift`, `AudiobookProject.swift`, `EligibilityProfile.swift`, `ProjectIntegrity.swift`, `DestinationTypes.swift`.

Write `ProjectFixtures` before writing any test, and make `stress(paragraphs:)` generate deterministic content from a seeded PRNG so failures are reproducible.

### 22.9 Anti-patterns to avoid (observed failure modes in tools of this kind)

1. **Addressing audio by time instead of by paragraph.** Every feature that takes a `TimeInterval` where it could take a `paragraphID` is a future bug. Time offsets are valid only *inside* a take.
2. **Storing derived state.** Drift, eligibility, progress percentages, and queue membership are all derived. Store them only as caches with an explicit invalidation rule (`review_state` is the one deliberate exception, and it has a single writer).
3. **Mutating originals.** Trim, gain, and fades are instructions. The day the app writes over a capture is the day it loses a user's book.
4. **Blocking the audio thread.** Any `Task`, lock, allocation, or log call in a tap will eventually produce a dropout that the user will describe as "the app ate my recording."
5. **Global observation.** A single `@Observable` holding both transport state and durable project state re-renders the whole window at meter rate.
6. **Scattering platform constants.** The moment `192` appears in a view model, the destination profile has stopped being the source of truth (gate G-10).
7. **Gating anything a LibriVox volunteer needs.** The free lane is the product's credibility. Every gate added outside `Export*`/`Packaging*` is a product regression, not a monetization win.
8. **Auto-uploading "as a convenience."** It converts a tool that prepares files into an agent that publishes on a user's behalf, with consequences on platforms that ban automated submissions.
9. **Silent format conversion.** Recording at 48/24 and exporting at 44.1 kHz is correct; resampling the *capture* to 44.1 kHz because export needs it is not.
10. **Treating validation warnings as failures.** Blocking on the LibriVox loudness estimate, or on unapproved paragraphs, would stop legitimate work over a heuristic.

### 22.10 Document provenance

Derived from `VOXGLASS_STUDIO_IMPLEMENTATION_PLAN.md` (2026-07-29) and the four mockup sets in this directory (`voxglass-macos-view-mockups`, `voxglass-iphone-production-mockups`, `voxglass-watch-production-mockups`, `voxglass-carplay-production-mockups`), reconciled against the repository at commit `4d797e4` on `main`. External platform requirements were researched on 2026-07-30 and are cited in §3.7; they are the only part of this document with an expiry date, and §21.3 defines how to renew it.

Where this document and the source plan disagree, this document governs (§0.3). Where this document and the mockups disagree, the deviation is recorded in §22.4 and the mockups should be updated. Where this document is silent, decide with the product principles in §1.6 and record the decision here.

---

*End of specification.*
