# Voxglass — iPhone + Watch Narration MVP — Revised Specification

**Status:** implementable specification. Supersedes `docs/iphone-watch-only-mvp/SPEC.md` (the *speculative* spec).
**Date:** 2026-08-07.
**Mockups:** [`mockups/index.html`](mockups/index.html).

---

## 0. How to use this document

### 0.1 What this document is

The speculative spec (`docs/iphone-watch-only-mvp/SPEC.md`) answered one question correctly — *drop the Mac, make iPhone the writer* — and then described a **separate "Voxglass Studio" iPhone app** built from scratch, with its own tab bar, its own light-themed flat visual language, and a greenfield S1–S9 stage plan.

Neither of those survives contact with the repository. The repository already contains:

- ~100 files of production Core under `Voxglass/Core/Production/` (domain, SQLite store, text pipeline, audio metrics, assembly, review fold, validation engine, packaging/encoders, destination profiles, CloudKit sync, watch link, license seam);
- a **shipping Narration tab inside the Voxglass app** (`VoxglassTab.narration`, `mic.fill`, 5th slot in `GlassTabBar`) with an end-to-end flow: import → review source → record → review → assemble → metadata → validate/export → submit;
- a **My Productions** review surface on iPhone (`Voxglass/Features/Production/ProductionViews.swift`) and a **full watch Production companion** (20 files under `VoxglassWatch/Production/`) with review player, dictation, offline queue, and sync status;
- an uncommitted first cut of the speculative spec's §4–§5 storage kernel (`Voxglass/Core/Production/CloudAssets/`).

So this document is a **delta and reconciliation spec**, in the house style of `docs/voxglass-narration/NARRATION_NEEDS_SPEC.md`: it inherits the Studio Spec's conventions verbatim, restates in full only what changes, cites the source section for everything that does not, and carries an explicit corrections table for each document it overrides.

### 0.2 Reading order for an implementing agent

1. §0.4–§0.6 — the corrections tables. These are the only places where a decision *changes*; everything else is either inherited or new detail.
2. §1–§2 — product definition and the free/Pro boundary. Getting the economic boundary wrong leaks `isPro` checks into recording and review code that must stay free forever.
3. §4 — architecture, and specifically **§4.3, the single project model decision**. This is the pivotal change and the largest single piece of work in the plan.
4. §5 — implementation status inventory. Read this before writing any file; most of what you need already exists.
5. §17 — stage plan. Implement stage by stage. Each stage is one reviewable commit with a stated acceptance test.
6. §6–§16 as reference while implementing a stage.

### 0.3 Normative language

Inherited verbatim from Studio Spec §0.2:

- **MUST / MUST NOT** — a CI gate, a test, or a reviewer will reject the change if violated.
- **SHOULD** — deviate only with a comment in the code explaining why.
- **MAY** — genuinely optional; implement the simplest thing.
- **DEFERRED** — explicitly out of this MVP. Do not build it, do not stub toward it, do not add a protocol method "for later."

Repository conventions are inherited from Studio Spec §0.6 without change: XcodeGen from `project.yml` (never hand-edit the `.xcodeproj`); bundle prefix `guru.parso`; Core lives at `Voxglass/Core/<Area>/`; hand-rolled SQLite via `AppDatabase`-style actors (**no GRDB**); `@Observable` only, `ObservableObject` banned; `Date()`/`UUID()` only through the `Clock`/`IDGenerator` seams; `///` doc comments on every `public` symbol; one commit per stage.

### 0.4 Corrections to the speculative spec (R-series)

An implementing agent MUST follow the right-hand column.

| # | Speculative spec said | Reality | This spec says |
|---|---|---|---|
| **R-1** | A separate **"Voxglass Studio"** iPhone app with its own tab bar (Projects / Record / Review / Settings) and its own bundle. | The Voxglass app already has a **Narration tab** (`VoxglassTab.narration`, `Voxglass/App/RootView.swift:96`) wired into `GlassTabBar` (`Voxglass/Features/Chrome/GlassDock.swift:75`), and a working flow root at `NarrationFlowRoot`. | **No second app.** Every production surface lives inside the existing Voxglass iPhone app, entered from the Narration tab. No new bundle ID, no new app target, no second tab bar. The five-tab glass dock (Listen / My Books / Explore / Search / **Narration**) is unchanged. §15.1. |
| **R-2** | New module `Voxglass/Features/ProductionStudio` and `VoxglassWatch/ProductionStudio`. | The real trees are `Voxglass/Features/Production/` (incl. `Discovery/`) and `VoxglassWatch/Production/`. | Use the **existing paths**. Do not create `…/ProductionStudio`. New iPhone production UI goes under `Voxglass/Features/Production/`; new Core goes under `Voxglass/Core/Production/<Area>/`. §4.1. |
| **R-3** | Light-themed, flat mockups (`--page:#eef1f3`, `--panel:#fff`, `--blue:#2f6fed`) shipped as `docs/iphone-watch-only-mvp/mockups/style.css`. | The app is dark, glass-based, brass-accented: `Palette` in `Voxglass/DesignSystem/VoxglassTheme.swift` and the `AdaptiveGlass` modifier in `Voxglass/DesignSystem/AdaptiveGlass.swift`. | Mockups are **regenerated against the app's own tokens**, including the *reduce-transparency fallback* that `AdaptiveGlass` implements. §15.2 and `mockups/style.css`. The speculative mockup set is superseded wholesale. |
| **R-4** | Invents CloudKit zone `VGProductionStudioZone` and record types `VGProject` / `VGChapter` / `VGParagraph` / `VGTake` / `VGAsset` / `VGReviewEvent`. | `CloudKitProductionSync.zoneName` is already `"VGProductionStudioZone"` (working tree) and `ProductionRecordType` already defines `VGProductionProject`, `VGProductionChapter`, `VGProductionParagraph`, `VGReviewEvent`. | **Keep the existing zone and record-type names.** The only schema change is **additive**: one new record type `VGProductionAsset` (§6.3). Do not rename `VGProductionProject` → `VGProject`; CloudKit record types are not renameable in place and the rename buys nothing. |
| **R-5** | Greenfield stage plan S1–S9 in which S1 is "extract iPhone production core". | Core extraction is done; the storage kernel is partly done (uncommitted `CloudAssets/`); recording, review, watch review, dictation, and offline queue ship today. | The stage plan is **rewritten against the inventory in §5**. See §17. Stages are named **P0–P9** to avoid confusion with the speculative S-numbers. |
| **R-6** | "`Features/ProductionStudio` becomes the iPhone implementation … project library, new project, source import, script editor…" — i.e. a project-manager UI as the front door. | The shipping front door is a **need-first discovery shelf** (`NarrationHomeShelf`) plus **My Narrations**, and the flow is a `fullScreenCover` wizard, not a document browser. | Keep the **need-first, wizard-shaped** front door. A project library exists as *My Narrations* (a section of the Narration tab), not as the app's primary surface. §15.3. |
| **R-7** | "Watch cannot … touch CloudKit directly" listed as a new rule. | Already true and already enforced: Core is CloudKit-free by construction and `CloudKitProductionSync` lives behind `ProductionSyncTransport`; the watch links Core without CloudKit. | Restated as an **existing invariant with a CI gate** (§16.4 G-W1), not new work. |
| **R-8** | `.voxmobileproject` backup bundle as a new portable format. | `Voxglass/Core/Production/Package/ProjectPackage.swift` + `PackageManifest.swift` already implement the `.voxproject` package and its manifest. | **Reuse `.voxproject`.** Do not invent a second package format. iPhone writes and reads the same package; §4.4. |
| **R-9** | Free tier includes "iCloud backup/offload for all project data". Pro includes FLAC. | `NARRATION_NEEDS_SPEC` D-6 already shipped **FLAC on the free Internet Archive lane** (lossless master + MP3 derivative). | FLAC is **free for the Internet Archive lane** and Pro only for *commercial* FLAC masters. The `ProFeature.flacExport` gate MUST NOT be consulted on the IA path. §2. |
| **R-10** | Watch cache "evict least-recently-**queued**". | Working tree already changed `WatchProductionStoragePolicy` to prefer `lastReviewedAt`, falling back to `lastQueuedAt`. | Least-recently-**reviewed** first, falling back to queued time when never reviewed. Matches the working tree; keep it. §14.4. |

### 0.5 Corrections to the Studio Spec (M-series)

These override `docs/voxglass-mvp/VOXGLASS_STUDIO_SPEC.md` for this MVP. Everything not listed here is inherited unchanged.

| # | Studio Spec said | This spec says |
|---|---|---|
| **M-1** | §4/§18.1: a macOS `VoxglassStudio` app is the authoring surface; §20 stages build it. | **macOS Studio is out of this MVP.** No Mac app target, no AppKit entitlements, no security-scoped bookmarks, no Finder-first `.voxproject` workflow, no `StudioCommands`. The Mac source tree, its targets, and its tests are **deleted** in stage **P0** (decision D-3, §19). The Studio Spec document itself is retained as the inherited reference — no docs are deleted. |
| **M-2** | §13: the Mac is the writer; it *publishes a projection* to CloudKit; the phone and watch are read-only consumers; conflicts resolved by server change tag + revision. | **The iPhone is the writer.** The projection is retained but inverted: the phone publishes a projection **of its own project** for (a) durable review-state backup and (b) reinstall/second-device recovery. There is no second editing surface, therefore **no projection conflict model**: `ProductionSyncEngine`'s conflict path degrades to last-writer-wins-by-revision with the phone always the writer. §6.2. |
| **M-3** | §13.6: phone relays Mac projections to watch. | Phone relays **its own** projection to watch, over the same `WatchConnectivity` transport and the same payload types (`WatchLinkPayloads.swift`). Direction of `PhoneProductionSync` inverts; payloads do not change. §14.2. |
| **M-4** | §12/§16: rendering and export are desktop-shaped (whole-book runs, no storage preflight). | Render and export are **chunked by chapter**, cancellable between chapters, preceded by a **free-space preflight** and a **hydration plan** (§11.2, §13.2). |
| **M-5** | §3.4 CarPlay production review is part of the destination/review surface. | **Production CarPlay is DEFERRED.** Consumer CarPlay is a separate, free, standalone surface (`docs/CARPLAY_DESIGN.md`) and is untouched by this spec. |
| **M-6** | §2: Pro is "Voxglass **Studio** Pro", product ID `guru.parso.voxglass.studio.pro`, $99 intro / $149. | **Renamed and repriced** (decisions D-1, D-2 in §19). Product ID `guru.parso.voxglass.narration.pro`, display name "Voxglass Narration Pro", **$49 intro / $79 standard**. Entitlement semantics are unchanged. The rename is safe because no purchase has ever existed (§19 D-1). |
| **M-7** | §19: five UI smoke tests (iPhone, Watch, three macOS). | **Two** UI smoke tests: iPhone and Watch. Both are a **local pre-commit gate**; CI runs no simulator. CI runs on `macos-latest` (compile, logic tests, TestFlight) plus one `ubuntu-latest` job (`guarded-tests`: source + grep gates); no CI job boots a simulator. Inherited from repo practice, not changed by this document. §16.3. |

### 0.6 Corrections to NARRATION_NEEDS_SPEC (N-series)

| # | NARRATION_NEEDS_SPEC said | This spec says |
|---|---|---|
| **N-1** | D-2: iPhone narrates **short works only** (≤ 1 hour); longer works are surfaced on iPhone as aspirational **Mac handoff** cards. | **Reversed.** There is no Mac. Long works are narratable on iPhone. The short-work ceiling survives only as a *discovery* signal ("finishable in one sitting"), never as a gate on the record action. `LongWorkHandoffSheet` and mockup `n04-iphone-long-work-mac-handoff.html` are **retired**; the sheet is replaced by a **multi-session project** affordance (§8.3, §15.6). |
| **N-2** | §11.4: phone narration projects persist as **JSON** via `NarrationProjectStore` under `Application Support/Voxglass/Narrations/`. | **Superseded.** One project model, `AudiobookProject` in the SQLite production store (§4.3). `NarrationProjectStore` survives for exactly one release as a **one-way migration source** (§4.3.3), then is deleted. |
| **N-3** | §0.5: Mac discovery code lives in `VoxglassStudio/Features/Discovery/`. | Not built. iPhone-only: `Voxglass/Core/Production/Discovery/` (pure) + `Voxglass/Features/Production/Discovery/` (UI). |
| **N-4** | The discovery ladder L0–L3 and the featured slot. | **Inherited unchanged.** The needs ladder, the bundled seed floor, and `FeaturedSelector` are correct and shipping; this spec changes nothing about them. |

---

## 1. Product definition

### 1.1 One sentence

Voxglass is an audiobook *listening* app that also lets you **narrate one, on your phone**, with your watch as the review and remote-control companion — from "what should I read?" through recording, review, validation, and a submission-ready package.

### 1.2 The job

The narrator is a solo LibriVox volunteer, indie author, or semi-pro who owns a phone, maybe a USB-C interface, and no desktop studio. They want to finish and submit a real recording. Voxglass organizes, records, validates, masters, and packages. It cannot make a noisy room sound treated, and it MUST say so plainly (§7.1).

The product is **not a DAW** and **not a timeline editor**. It is manuscript-addressed: the text is the index, and recording, retakes, notes, review, and validation are all addressed by paragraph.

### 1.3 Platform surfaces

| Surface | Job | Creates audio? | Owns project state? |
|---|---|---:|---:|
| iPhone — Narration tab | Discovery, project creation, source import, script edit, recording, takes, review, assembly, metadata/rights, storage, validation, export, Pro purchase | **Yes** | **Yes — sole writer** |
| Apple Watch — Production companion | Offline review queues, playback, approve/flag/pickup, dictated notes, recording remote | No | No — append-only events |
| iCloud private database | Backup/offload of project metadata and narration assets | No | Remote mirror only |

Explicitly **removed** from the MVP: the macOS Studio app; Mac project windows; the Finder-first `.voxproject` workflow; the Mac→phone projection model; the iPhone→Mac long-work handoff (N-1); production CarPlay (M-5).

### 1.4 Distribution lanes

| Lane | Tier | Output | Notes |
|---|---|---|---|
| LibriVox | Free | 128 kbps CBR mono MP3 per section, ID3 tags, durations, checklist | Human narration only. No paywall anywhere on this path. |
| Internet Archive | Free | **FLAC** lossless masters + MP3 derivatives, metadata sidecars, checksums, `ia upload` command, checklist | No auto-upload; the user submits. (R-9) |
| Personal master | Free | Lossless WAV chapters | The user always has access to their own recording. |
| Commercial retail | **Pro** | ACX/aggregator MP3, mastered files, M4B, commercial FLAC masters, retail sample, metadata, exported validation reports | One-time purchase. |

### 1.5 Product principles

1. **Never lose a take.** In-flight audio is written incrementally and is recoverable after force-quit, interruption, route change, and disk pressure. (§7.4)
2. **The text is the index.** Every recordable, reviewable, and reportable unit is a paragraph with stable identity across re-imports.
3. **Local storage is a working cache, not the only copy** — but *only after* the remote copy is SHA-256-verified. (§6.1)
4. **Free must be complete.** LibriVox and Internet Archive contribution never hits a Pro gate. Validation is free for every destination, including retail, so the value is visible before purchase.
5. **The app prepares files; the human submits.** Voxglass MUST NOT upload to LibriVox, archive.org, ACX, or any retailer. (Studio Spec C-7)
6. **Hardware truth beats marketing.** Retail readiness checks tell the user when their mic or room cannot meet a destination requirement. (§7.1)
7. **Narration never degrades listening.** The Narration tab is additive; the consumer player, downloads, CarPlay, and position sync are untouched.

---

## 2. The free / Pro boundary

### 2.1 Free forever

Unlimited projects, chapters, paragraphs, takes, and recording time. Source import (EPUB, TXT, Markdown, DOCX, paste, Gutenberg). Script editing, split/merge, drift detection, generated LibriVox disclaimers. Recording, retakes, take comparison, imported-audio assignment. Audio setup test and quality metrics. Review queues on iPhone and Watch, dictation, offline queue. iCloud backup/offload for all project data, subject to the user's own iCloud quota. **Full validation for every destination, including retail.** LibriVox export. Internet Archive export **including FLAC masters** (R-9). Personal WAV export.

### 2.2 Pro

A single non-consumable IAP, **"Voxglass Narration Pro"**, product ID **`guru.parso.voxglass.narration.pro`**, **$49 introductory / $79 standard** (decisions D-1, D-2).

Both strings MUST be read from one constant each in `Voxglass/Core/Production/License/`, never inlined at a call site. The price is **not** in code — it lives in App Store Connect and is set at submission.

Renaming touches four places, all of which MUST move together in stage P0 while no entitlement exists anywhere:

| Place | From | To |
|---|---|---|
| Product ID constant | `guru.parso.voxglass.studio.pro` | `guru.parso.voxglass.narration.pro` |
| `EntitlementCache.proSinceKey` | `voxglass.studio.pro.since` | `voxglass.narration.pro.since` |
| `EntitlementCache.transactionIDKey` | `voxglass.studio.pro.transaction` | `voxglass.narration.pro.transaction` |
| StoreKit test config | `VoxglassStudio/Resources/VoxglassStudio.storekit` (deleted with the Mac tree) | `Voxglass/Resources/VoxglassNarration.storekit` |

No migration shim is needed for the two `UserDefaults` keys: nothing has ever written them, because no StoreKit concrete exists yet (§5.1). **If that stops being true before P0 lands, add a read-through fallback to the old keys rather than renaming.**

Pro unlocks exactly the seven `ProFeature` cases already declared in `LicenseTypes.swift`:

`retailPresets` · `mastering` · `m4bExport` · `flacExport` *(commercial masters only — see below)* · `batchExport` · `commercialMetadata` · `validationReportExport`

**Gate placement rules (MUST):**

- `LicenseGate` is consulted **only** in the export destination picker, the export runner, and Settings. It MUST NOT appear in recording, review, validation, assembly, storage, or watch code.
- The Internet Archive builder MUST NOT consult `ProFeature.flacExport`. FLAC gating applies to `RetailMasterPackageBuilder` only. A CI grep gate enforces this (§16.4 G-P2).
- Validation is never gated. A free user MUST be able to run and read a full ACX report.

**Test:** `LicenseGatePlacementTests` — greps the built source set for `LicenseGate`/`isPro` references outside the three permitted files and fails on any other occurrence. This test already has a home in the validation/licensing suite; extend it rather than adding a new one.

---

## 3. External requirements

All numeric constants are **inherited from Studio Spec §3** and already live in code at `Voxglass/Core/Production/Destinations/` (`DestinationProfiles.swift`, `ValidationThresholds.swift`, `LegalStrings.swift`). Do not restate thresholds in new code; import them.

Re-verification before release is tracked in `docs/voxglass-mvp/DESTINATION_VERIFICATION_LOG.md` and is a release gate (§16.6).

Summary for orientation only — **the code, not this table, is normative**:

- **LibriVox:** MP3 128 kbps CBR, 44.1 kHz, mono; ~89 dB perceived volume (warning-only); spoken intro/outro disclaimers generated as paragraphs and recorded **by the human narrator**; AI/synthetic narration ineligible.
- **Internet Archive:** FLAC or WAV masters, MP3 derivatives, metadata sidecars, checksums, generated checklist and suggested `ia upload` command, no auto-upload.
- **Commercial (ACX baseline):** MP3 ≥ 192 kbps CBR, 44.1 kHz, one file per chapter/section, < 120 min per file; RMS ∈ [−23, −18] dBFS; peak ≤ −3 dBFS; noise floor ≤ −60 dBFS RMS; room tone at head and tail; opening/closing credits; retail sample; cover art ≥ 2400 × 2400 px.
- **Legal strings** are fixed text in `LegalStrings.swift` and MUST be used verbatim: "Voxglass does not determine copyright status." · "Voxglass prepares files; it does not guarantee acceptance or determine copyright." · "You submit these files yourself. Voxglass never uploads on your behalf." · "LibriVox accepts only recordings made by human volunteers using their own voices."

---

## 4. Architecture

### 4.1 Module topology (real paths)

```
Voxglass/Core/Production/          — pure, platform-free, CloudKit-free except Sync/CloudKit*
  Domain/       project, chapter, paragraph, take, rights, destinations, review events
  Store/        SQLite production store + migrations + export-run records
  Text/         importers (EPUB/DOCX/MD/TXT), segmenter, re-identification, drift, generated scripts
  Audio/        AudioCapturing seam, metrics, silence, ReplayGain, autosave session, WAV repair
  Assembly/     segment queues, render plans, cache keys, segment player
  Review/       events, fold, queue resolver
  Validation/   issue codes, rule engine, report + renderer, fix actions
  Packaging/    builders (LibriVox, IA, retail), transcoding, tags, checksums, mastering
  Destinations/ profiles, thresholds, legal strings, filename/identifier rules
  Package/      .voxproject package, manifest, content-addressed store, artwork, storage analyzer
  CloudAssets/  project layout, asset state, eviction planner, hydration planner     ← partly new
  Sync/         sync engine, transport seam, CloudKit transport, projection, outbox
  WatchLink/    phone↔watch payloads, watch storage policy, watch outbox
  License/      ProFeature, LicenseGate seam, entitlement cache
  Discovery/    needs ladder L0–L3, PD checks, featured selector, caches

Voxglass/Features/Production/      — iPhone UI (inside the Voxglass app)
  Discovery/    Narration tab, needs shelf, the narration flow (import→…→submit)
  …             My Productions, production player, paragraph list, review queue builder,
                note sheet, sync & storage, phone-side sync + watch transport

VoxglassWatch/Production/          — watchOS companion
                productions list, home, review queue, review player, paragraph text,
                confirmation, dictation, sync status, offline queue, segment player
```

**MUST NOT** create `Voxglass/Features/ProductionStudio` or `VoxglassWatch/ProductionStudio` (R-2).

### 4.2 The single-writer model

The iPhone is the only writer of project metadata and take selection.

- iCloud is a **remote mirror and asset store**, never a second editing surface.
- Watch actions are append-only `ReviewEvent`s relayed to the phone; the fold is idempotent by event id, so a retry can never duplicate an action.
- If the phone is unreachable, watch events accumulate in the file-backed `WatchReviewOutbox` and flush on reachability.
- There is **no publish/preview step**. The phone edits the real project; the projection is a backup artifact, not a handoff artifact (M-2).

Consequence for `ProductionSyncEngine`: the conflict branch that existed to reconcile a Mac writer against a phone consumer is now unreachable in normal operation. It MUST be retained (a reinstall racing an in-flight upload can still produce a server change tag mismatch) but degrades to **adopt-server-tag, retry-once, phone wins**. A test MUST prove no user-visible conflict UI is reachable.

### 4.3 One project model — the pivotal decision

#### 4.3.1 The problem

The repository currently has **two** phone-side project models:

| | `NarrationProject` | `AudiobookProject` |
|---|---|---|
| File | `Voxglass/Features/Production/Discovery/NarrationProjectStore.swift` | `Voxglass/Core/Production/Domain/AudiobookProject.swift` |
| Persistence | JSON blob per project + loose take files under `Application Support/Voxglass/Narrations/` | SQLite (`SQLiteProductionStore`) inside a `.voxproject` package |
| Used by | the shipping Narration flow (short works) | the production Core: validation, assembly, packaging, sync, watch projections |
| Reaches the watch? | **No** | Yes |
| Gets iCloud offload? | **No** | Yes (once §6 lands) |
| Can be exported to retail? | No | Yes |

They exist because the narration flow was built as a fast lane for short works (NARRATION_NEEDS_SPEC §11.4) while the Studio model was built for the Mac. With the Mac gone and long works now narratable on iPhone (N-1), the split is no longer defensible: a JSON narration can never be reviewed on the watch, never offload to iCloud, never be validated by the rule engine, and never be exported commercially.

#### 4.3.2 The decision

**`AudiobookProject` in the SQLite production store is the one project model (MUST).**

- Every narration created by the Narration flow — short or long — creates an `AudiobookProject` in a `.voxproject` package under the layout in §4.4.
- `NarrationProject`, `NarrationParagraph`, `NarrationTake`, and `NarrationProjectStore` become **migration-only** types (§4.3.3) and are deleted at the end of stage P2.
- **The flow UI is kept.** This is a storage change, not a UX change. `NarrationFlowRoot`, its `NarrationStep` enum, and every screen in `NarrationFlowScreens.swift` keep their shape, their accessibility identifiers, and their pacing. What changes is what they read and write.

Rationale, stated once so it is not re-litigated: two models cannot both be "the single writer". Unifying costs one stage; not unifying costs the watch companion, iCloud offload, retail export, and the validation engine for every project the user actually creates through the front door.

#### 4.3.3 Migration (MUST)

A one-way, idempotent migration runs once at first launch of the release that lands stage P2:

1. Enumerate `Application Support/Voxglass/Narrations/*.json`.
2. For each, create an `AudiobookProject` with a **new** project id; carry `title`, `author`, `sourceText`, `sourceURL`, `needID`, `metadata`, `rightsAttested`, `createdAt`.
3. Segment `sourceText` through the existing `Segmenter` **only if** the JSON has no paragraphs; otherwise map `NarrationParagraph` → `Paragraph` preserving order and text so paragraph identity is stable.
4. For each `NarrationTake`, copy (do not move) the take file into the content-addressed store, stream-hash it, and insert a `Take` with `origin` carried over and `CaptureWarning` empty.
5. Preserve review state: `.approved` → approved, `.flagged` → flagged, `.notRecorded` → no selected take.
6. Write a migration receipt (`Narrations/.migrated-<date>.json`) listing old id → new id.
7. Only after every project's receipt is written, delete the `Narrations/` tree.

Failure of any single project MUST NOT abort the others; a failed project stays on disk and is retried next launch, and the user sees nothing.

**Tests:** `NarrationMigrationTests` — round-trip a fixture directory of three JSON narrations (one empty, one partly recorded, one fully approved with two takes on one paragraph); assert paragraph order, take hashes, review states, dedupe-by-`needID` behavior, idempotency across two runs, and that a corrupt JSON is skipped without loss.

### 4.4 Project layout on iPhone

Projects live under `Application Support/ProductionProjects/<projectID>/`, which **is** a `.voxproject` package (R-8) — the same manifest and content-addressed store the Mac spec defined, now written by the phone:

```
project.sqlite
manifest.json
Audio/Original/<sha fanout>.<wav|caf|m4a>
Audio/Render/<cacheKey>.caf
Audio/Proxy/<paragraphID>.m4a          ← watch/review proxies
Audio/ExportStaging/<runID>/
Text/source/<sha>.<ext>
Text/extracted/<sha>.json
Artwork/
Autosave/session.json
Autosave/takes/<uuid>.wav
Trash/
```

`Voxglass/Core/Production/CloudAssets/ProductionProjectLayout.swift` owns these path rules and MUST be the only place they are spelled.

Users never browse this tree. Portability is through **Files**:

- "Save a copy" writes the `.voxproject` package (zipped on iOS, since `UIDocumentPickerViewController` round-trips a single file most reliably).
- Export packages are written as `.zip`, with "Save folder to Files" offered when the chosen destination accepts directories.

**MUST NOT** invent `.voxmobileproject` (R-8).

---

## 5. Implementation status inventory

This is the honest read of the working tree at the time of writing (commit `75cd8c7` plus the staged changes listed in §5.4). **Read this before writing any file.**

Legend: **✅ as-is** — use unchanged. **🔧 rework** — exists, needs the change named. **🆕 new** — does not exist.

### 5.1 Core (`Voxglass/Core/Production/`)

| Area | Files | Status | Change required |
|---|---|---|---|
| `Domain/` | 15 files incl. `AudiobookProject`, `Chapter`, `Paragraph`, `Take`, `ReviewEvent`, `RightsEvidence`, `EligibilityProfile`, `Clock`, `IDGenerator`, `SHA256Hex` | ✅ as-is | none |
| `Store/` | `SQLiteProductionStore`, `ProjectDatabase`, `ProductionMigration`, `ExportRunRecord`, `InMemoryProductionStore` | 🔧 rework | add migrations for the asset table (§6.1) and the capture-route field (§7.1) |
| `Text/` | 14 files: EPUB/DOCX/MD/TXT importers, `Segmenter`, `ParagraphReidentifier`, `TextDriftDetector`, `ParagraphSplitter`, `ScriptGenerator`, `ScriptApplier` | ✅ as-is | progressive-parse *call pattern* is a UI concern (§8.2), not a Core change |
| `Audio/` | `AudioCapturing` seam, `AudioMetrics`, `AutosaveSession`, `SilenceSegmenter`, `ReplayGainCalculator`, `WAVHeaderRepair`, `DirectFormFilter`, `AudioDecoding` | ✅ as-is | none |
| `Assembly/` | `SegmentQueueBuilder`, `RenderPlan`, `AssemblyDuration`, `SegmentPlayer`, `AssemblyTypes` | 🔧 rework | chunk render plans by chapter and make them cancellable (M-4) |
| `Review/` | `ReviewEventFolder`, `ReviewQueueResolver`, `ReviewTypes` | ✅ as-is | none |
| `Validation/` | `ValidationRuleEngine`, `IssueCode`, `ValidationIssue`, `ValidationReport`, `ValidationReportRenderer`, `FixAction` | 🔧 rework | add the four iPhone issue codes in §12.2 |
| `Packaging/` | 12 files incl. `LibriVoxPackageBuilder`, `InternetArchivePackageBuilder`, `RetailMasterPackageBuilder`, `AudioTranscoding`, `ID3Writer`, `MP3FrameParser`, `MasteringChain`, `ChecksumWriter`, `ChapterExportPipeline` | 🔧 rework | resumable export runs on iOS (§13.3); verify LAME/libFLAC iOS device + simulator slices |
| `Destinations/` | `DestinationProfiles`, `ValidationThresholds`, `LegalStrings`, `FilenameSanitizer`, `IdentifierSuggester` | ✅ as-is | re-verify constants before release (§16.6) |
| `Package/` | `ProjectPackage`, `PackageManifest`, `ContentAddressedStore`, `FileAssetStore`, `ArtworkStore`, `StorageAnalyzer`, `PackageError` | ✅ as-is | none |
| `CloudAssets/` | `ProductionProjectLayout` (26 lines), `ProductionStoragePolicy` (asset state, cache limits, eviction planner, hydration planner) | 🔧 rework | **uncommitted.** Pure planners are correct and complete; they need a persistence layer, an executor, and upload/verify (§6) |
| `Sync/` | `ProductionSyncEngine`, `SyncTransport`, `CloudKitProductionSync`, `SyncRecords`, `ProjectionPublisher`, `SyncProjection`, `SyncStateStore`, `EventIngestor`, `ReviewEventOutbox` | 🔧 rework | invert direction (M-2); add `VGProductionAsset` record type + asset upload/verify/hydrate (§6.3) |
| `WatchLink/` | `WatchLinkPayloads`, `WatchTransport`, `WatchProductionStoragePolicy`, `WatchReviewOutbox`, `ProductionWatchFixtures` | 🔧 rework | add the recording-remote command payload (§14.3) |
| `License/` | `LicenseTypes` (`ProFeature`, `LicenseGate`), `EntitlementCache` | 🔧 rework | **no StoreKit concrete exists.** Add one in the app target (§13.5); rename the product ID and the two `EntitlementCache` keys in P0 (§2.2) |
| `Discovery/` | needs ladder, PD checks, featured selector, caches, parsers | ✅ as-is | none (N-4) |

### 5.2 iPhone (`Voxglass/Features/Production/`)

| Surface | File(s) | Status | Change required |
|---|---|---|---|
| Narration tab shell | `Discovery/NarrationTabView.swift` | 🔧 rework | remove the handoff sheet (N-1); My Narrations reads the production store |
| Needs shelf & browser | `Discovery/DiscoveryViews.swift` (730 lines) | 🔧 rework | drop "Record on Mac" affordances; every need is narratable |
| Flow root & steps | `Discovery/NarrationFlow.swift` (931), `NarrationFlowScreens.swift` (1042) | 🔧 rework | **repoint storage to the production store (§4.3)**; steps and identifiers unchanged |
| Phone narration store | `Discovery/NarrationProjectStore.swift` (276) | 🔧 → delete | becomes migration source, then deleted at end of P2 |
| iOS capture | `Discovery/AudioSessionCapture.swift` (302) | 🔧 rework | real; uses `AVAudioEngine` + `AVAudioFile`. Needs: incremental autosave to `Autosave/takes/`, route classification (§7.1), the full interruption matrix (§7.4) |
| Fake capture (UI tests) | `Discovery/UITestAudioCapture.swift` | ✅ as-is | none |
| My Productions / review | `ProductionViews.swift`, `ProductionModels.swift`, `ProductionPreviewStore.swift` | 🔧 rework | source of truth flips from "projection received from Mac" to "projection derived from local store" |
| Phone sync + watch relay | `PhoneProductionEnvironment.swift`, `PhoneProductionSync.swift`, `WatchConnectivityTransport.swift` | 🔧 rework | invert (M-3); add recording-remote command receive |
| Smoke seed | `ProductionSmokeSeed.swift` | 🔧 rework | seed production-store projects, idempotently |
| **Script editor** (split/merge, drift) | — | 🆕 new | §8.4 |
| **Take comparison** (A/B, select take) | — | 🆕 new | §9.5 |
| **Import existing audio** | — | 🆕 new | §10 |
| **Assembly controls** | partial (`AssembleView` in flow) | 🔧 rework | gaps, room tone, render cache surface (§11) |
| **Audio setup / route readiness** | — | 🆕 new | §7.1 |
| **Storage & iCloud settings** | — | 🆕 new | §6.5, §15.8 |
| **Export run + resume UI** | partial (`ValidateExportView`) | 🔧 rework | scopes, hydration preflight, resumable run (§13) |
| **Pro purchase** | — | 🆕 new | §13.5 |

### 5.3 Watch (`VoxglassWatch/Production/`, 20 files)

| Surface | File(s) | Status |
|---|---|---|
| Productions list, home | `ProductionsListView`, `ProductionHomeView`, `WatchProductionsModel`, `WatchProductionHomeModel` | ✅ as-is |
| Review queue + player | `WatchReviewQueueListView`, `WatchReviewPlayerView`, `WatchReviewModel`, `WatchSegmentPlayer`, `WatchParagraphTextView`, `WatchReviewConfirmationView` | ✅ as-is |
| Dictation | `WatchDictationCategoryView`, `WatchDictationModel`, `WatchDictationResultView` | ✅ as-is |
| Offline queue + storage | `WatchOfflineQueueView`, `WatchProductionAudioStore` | ✅ as-is |
| Sync status + transport | `WatchSyncStatusView`, `WatchSyncModel`, `WatchConnectivityTransport` | 🔧 minor — copy changes from "Mac" to "iPhone" |
| Navigation, environment, a11y, smoke | `ProductionNavigation`, `ProductionWatchEnvironment`, `ProductionWatchAccessibility`, `ProductionWatchSmoke` | ✅ as-is |
| **Recording remote** | — | 🆕 new (§14.3) |

### 5.4 Uncommitted work already on disk

The working tree contains a first pass at this direction, staged but not committed. Treat it as the starting point of stage P1, not as something to redo:

- `CloudAssets/ProductionProjectLayout.swift`, `CloudAssets/ProductionStoragePolicy.swift` — **new**, and correct as far as they go (asset states, `isEvictable`, cache limits with the 2–100 GB clamp, eviction ordering, hydration planning).
- `Sync/CloudKitProductionSync.swift` — zone renamed to `VGProductionStudioZone`, doc comments re-pointed to the iPhone-writer model.
- `Sync/{ProductionSyncEngine,ProjectionPublisher,SyncRecords,SyncTransport}.swift` — doc-comment re-pointing only; **behavior has not been inverted yet**.
- `WatchLink/WatchProductionStoragePolicy.swift` — least-recently-**reviewed** eviction (R-10).
- `WatchLink/WatchReviewOutbox.swift` — doc comment.
- `Features/Production/Discovery/*`, `ProductionViews.swift` — small copy edits.

**Note for the implementing agent:** the zone rename in `CloudKitProductionSync` is a live-schema change. Since no build has shipped writing `VGProductionZone` to users' private databases, the rename is safe; if that ever stops being true, add a one-time migration instead of renaming. State this in the commit body.

---

## 6. iCloud backup and offload

First-class requirement, not a later sync feature. Pure planning logic already exists in `CloudAssets/ProductionStoragePolicy.swift`; §6 specifies the persistence, the transport, and the executor around it.

### 6.1 Asset states

Every asset has exactly one state (`ProductionAssetState`, already defined):

| State | Meaning |
|---|---|
| `localOnly` | Exists only on iPhone. **Never evict.** |
| `uploading` | Upload in progress. **Never evict.** |
| `localAndRemote` | Local file exists **and** the iCloud copy is SHA-256-verified **and** `remoteAssetID` is persisted. Evictable if not pinned and not in the working set. |
| `remoteOnly` | Metadata local, blob in iCloud, file hydrated on demand. |
| `stagedForExport` | Hydrated for a running export. Never evict until the run completes or is canceled. |
| `missing` | Metadata references an unavailable blob. Blocks export and deep verify. |

**The offload rule (MUST):** no original recording may be evicted until its iCloud asset upload is verified by SHA-256 **and** the local project database has recorded the remote asset id. `ProductionAssetRecord.isEvictable` already encodes exactly this; the executor MUST call it rather than re-deriving the condition.

**Persistence (🆕):** a new `production_asset` table in the project SQLite, added as an append-only numbered migration in `ProductionMigration`. Columns mirror `ProductionAssetRecord` one-for-one: `id`, `sha256`, `byte_count`, `state`, `chapter_id`, `chapter_ordinal`, `is_pinned`, `is_working_set`, `last_accessed_at`, `remote_asset_id`.

**Test:** `ProductionAssetStateTests` — every legal transition, and an assertion that `.localOnly`, `.uploading`, `.stagedForExport`, and pinned/working-set records are never returned by the eviction planner regardless of pressure.

### 6.2 What goes to iCloud

Private CloudKit database, zone `VGProductionStudioZone` (existing).

| Record type | Constant | Status | Carries |
|---|---|---|---|
| `VGProductionProject` | `ProductionRecordType.project` | ✅ exists | project metadata, counts, modified date, revision, offload policy *(new field)* |
| `VGProductionChapter` | `.chapter` | ✅ exists | chapter metadata |
| `VGProductionParagraph` | `.paragraph` | ✅ exists | text hash, state, selected take id, review state, proxy `CKAsset` |
| `VGReviewEvent` | `.event` | ✅ exists | watch-generated queued events relayed by the phone |
| **`VGProductionAsset`** | `.asset` | 🆕 **new** | content-addressed original: `CKAsset`, `sha256`, `byteCount`, `ext`, `contentType`, `takeID`, `chapterID` |

Only the user's private iCloud is used. **There is no Voxglass server.**

### 6.3 Upload, verify, hydrate

Upload path (per asset, resumable):

1. Mark `uploading` in SQLite before any network work.
2. Push `VGProductionAsset` with the `CKAsset` payload through `ProductionSyncTransport`.
3. On success, **re-read the server record's `sha256` field and compare to the local hash**. A byte-count match is not sufficient.
4. Persist `remoteAssetID` and flip to `localAndRemote` in a single SQLite transaction. If the app dies between 3 and 4, the next launch re-verifies and re-flips; the state stays `uploading` and the asset stays un-evictable, which is the safe failure.

Hydration path (`ProductionHydrationPlanner` already builds the plan):

1. Show metadata immediately; never block the UI on audio.
2. Queue hydration with a byte estimate shown to the user.
3. Allow text editing and review-state changes while audio hydrates.
4. **Disable playback and export of that paragraph until the selected take is local and hash-verified.**

Hydration MUST be resumable across launches and MUST content-address-verify before playback or export.

**Tests:** `CloudAssetUploadTests` (fake transport: success, mid-upload kill, hash mismatch → stays `uploading`, duplicate upload is a no-op), `HydrationPlanTests` (blocking vs non-blocking purposes, byte totals, resume after partial).

### 6.4 Working set

The app pins locally: the current recording chapter; the previous and next chapter when they exist; the current review queue and its next 20 items; any paragraph with unsynced review or take state; export staging inputs for the active run; and anything the user pinned.

Everything else is evictable once the production cache is over limit.

### 6.5 Cache limits and eviction

The consumer audiobook download cache and the production narration cache are **separate budgets and separate settings rows**. Conflating them would let a narration project evict the user's offline listening library, or vice versa.

| Budget | Default | Range |
|---|---|---|
| Audiobook downloads (existing listener cache) | unchanged | unchanged |
| Production local working cache | 10 GB | 2–100 GB (`ProductionCacheLimits.isValidWorkingCacheSize`) |
| Watch production queue cache | 200 MB | fixed |
| Export staging reserve | "ask each time" | preflight warns if space is unavailable |

Eviction order (already encoded in `ProductionEvictionPlanner.candidates`): render cache → completed/canceled export staging → proxy/review cache → remote-verified non-working original takes, **oldest chapter ordinal first**. Never `localOnly`, `uploading`, current chapter, or pinned.

Mockup: [`12-storage-icloud.html`](mockups/12-storage-icloud.html).

---

## 7. Audio capture on iPhone

### 7.1 Route classification and readiness

`AudioSessionCapture` records today but does not classify the route. Add a `CaptureRouteClassifier` (🆕, Core — pure, fed by a value type the app populates from `AVAudioSession.currentRoute`) producing:

| Class | Condition | Consequence |
|---|---|---|
| `retailReady` | USB or wired route, stable sample rate, sufficient input level, noise floor below threshold in a 10-second test | no warnings |
| `communityReady` | acceptable for LibriVox/IA but misses a retail threshold | retail export shows a warning |
| `draftOnly` | Bluetooth or built-in route, high latency, or failed noise-floor target | retail export shows a blocking-strength warning; LibriVox/IA unaffected |

Recommended for retail: USB-C class-compliant interface, or a USB microphone with hardware gain, plus wired headphones or interface direct monitoring. Allowed **with warnings**: built-in microphone; Bluetooth microphones; AirPods high-quality Bluetooth recording where the OS and hardware support it.

**Bluetooth MUST NOT be blocked.** The product's honesty principle (§1.5.6) is served by telling the truth at export time, not by refusing to record.

The classification of the route used for each take is stored on the take (`Store/` migration, §5.1) so `routeNotRetailReady` (§12.2) can be computed from history rather than from the route at export time.

Mockup: [`06b-audio-setup.html`](mockups/06b-audio-setup.html).

### 7.2 Capture graph

`AVAudioSession` category `.playAndRecord`.

```
inputNode -> tap -> lock-free ring buffer -> writer task -> Autosave/takes/<uuid>.wav
          -> meter accumulator -> AsyncStream<CaptureLevels>
```

The existing implementation writes through `AVAudioFile` directly from the tap. Stage P4 MUST introduce the ring buffer + writer task so the tap body obeys the real-time discipline the Studio Spec already requires and CI already reviews for: **no allocation, no lock, no `Task`, no `os_log`, no `Date()` in the tap body.**

Monitoring: prefer hardware/direct monitoring; software monitoring is optional and MUST warn about latency; the watch remote never streams audio.

### 7.3 Recording defaults

- Capture at 48 kHz, 24-bit mono WAV when the hardware supports it.
- Retail export resamples to 44.1 kHz. LibriVox export resamples to 44.1 kHz and encodes 128 kbps CBR MP3.
- If the hardware refuses the requested format, **record the actual hardware format** and preserve it in take metadata. Never fail a take to satisfy a preference.

### 7.4 Interruption matrix (MUST preserve a playable take)

Phone call / Siri / system interruption · route change · USB unplug · headphones removed · disk pressure · app backgrounded or locked · force-quit during a take.

On any of these:

1. Stop recording.
2. Finalize the file as far as possible (`WAVHeaderRepair` exists for the force-quit case).
3. Write or update `Autosave/session.json`.
4. After restart, insert a recoverable take **if the file is valid**.
5. Mark the take `CaptureWarning.interrupted`.

**Tests:** `CaptureInterruptionTests` against the `AudioCapturing` fake — one case per row above, each asserting a playable take and a correct warning. Hardware cases are additionally in the manual matrix (§16.5).

Mockups: [`06-recording-workspace.html`](mockups/06-recording-workspace.html), [`06c-capture-interruption.html`](mockups/06c-capture-interruption.html).

---

## 8. Text, scripts, and project creation

### 8.1 Inherited pipeline

Unchanged from Studio Spec §9–§10 and already implemented in `Core/Production/Text/`: import EPUB/TXT/Markdown/DOCX (plus paste and Gutenberg fetch from the Discovery layer); segment into chapters and paragraphs; preserve paragraph identity across re-import (`ParagraphReidentifier`); detect text drift against selected takes (`TextDriftDetector`); split and merge paragraphs (`ParagraphSplitter`); generate LibriVox disclaimer and retail credit paragraphs (`ScriptGenerator`).

### 8.2 iPhone-specific import behavior

- Large documents parse **progressively**, with a preview available before the parse completes. The import screen MUST NOT block on a full parse of a 400-page EPUB.
- Source Import shows chapter counts and warnings first; drilling into individual chapters is a second step.
- Re-import summaries are bite-sized: reused / new / drifted / orphaned counts with drill-down, not a diff view.

### 8.3 Long works on iPhone (replaces the Mac handoff)

Per N-1, the record action is offered for every need regardless of length. What length changes is **framing, not capability**:

- Needs under the one-hour LibriVox short-work ceiling are labeled "finishable in one sitting."
- Longer works are created as **multi-session projects**: the project dashboard leads with "Record next" (§15.5) resolving to the first paragraph with no selected take, or the first `needsPickup` if everything is recorded; progress is per chapter; and the storage card is prominent because a long work is the case where offload matters.
- `LongWorkHandoffSheet` and its mockup are deleted. No screen may mention a Mac.

### 8.4 Script editor (🆕)

A phone-shaped editor, not a dense multi-pane one:

- Chapter list → paragraph list with state chips (`Recorded`, `Text changed`, `Unrecorded`, `Needs pickup`).
- Tapping a paragraph opens an inline inspector: edit text, direction note, pronunciation, review status, **Split here** / **Merge next**.
- Text edits debounce at 400 ms; an explicit Save flushes immediately.
- Editing the text of a paragraph that has a selected take raises the drift indicator immediately (the rule engine already computes it).

Mockups: [`02-new-project.html`](mockups/02-new-project.html), [`03-source-import.html`](mockups/03-source-import.html), [`05-script-editor.html`](mockups/05-script-editor.html).

---

## 9. Recording workflow

The recording workspace is the product's center.

### 9.1 States

`idle → preparing → armed → preRoll → recording → finalizing → idle`

### 9.2 Actions

Record / Stop · Accept & Next · Retake · Flag · Play take · Play in context · Previous / Next paragraph · Select take.

### 9.3 External controls

- Hardware keyboard shortcuts when a keyboard is connected.
- Bluetooth media button / headset stem maps to Record/Stop **when armed** (and only when armed, so a stray press cannot start a take).
- The watch remote can start/stop, accept, retake, and flag. It **never records audio itself** (§14.3).

### 9.4 Write ordering (MUST, in this order)

1. Write into the autosave directory.
2. Stop and finalize.
3. Stream-hash the file.
4. Move into `Audio/Original/` via the content-addressed store.
5. Insert take metadata into SQLite.
6. Schedule the iCloud upload if backup is enabled.
7. Compute metrics in the background.

Metadata is never mutated before the bytes are durable. **No take is ever auto-deleted**; a retake archives by state, not by file removal.

### 9.5 Take comparison (🆕)

A/B two takes for one paragraph with matched loudness (ReplayGain values already computed), per-take metrics (peak, RMS, noise floor, duration), and a single **Use this take** action that sets the selected take. Selecting a take is a project mutation and therefore phone-only.

Mockups: [`06-recording-workspace.html`](mockups/06-recording-workspace.html), [`08-take-comparison.html`](mockups/08-take-comparison.html), [`watch-04-recording-remote.html`](mockups/watch-04-recording-remote.html).

---

## 10. Importing existing audio

Supported: WAV, AIFF, CAF, M4A/AAC, MP3, FLAC (decode paths already exist in `Audio/AudioDecoding.swift` + the encoder wrappers).

Assignment options: assign the whole file to one paragraph; split the file across a chapter by silence markers (`SilenceSegmenter`); assign detected segments sequentially.

On iPhone, large-file import MUST be explicit about storage before it starts: original size, estimated slice size, local cache impact, and an offer to "trash the original after verified slices."

**Origin declaration is mandatory** and is compliance metadata, not a UI nicety (Studio Spec C-6): *recorded by me* / *external human recording* / *AI-generated or AI-processed* / *unknown*. It MUST survive round-trips through SQLite, CloudKit, the packaging manifest, and the validation report. A non-human or unknown origin on a selected take **blocks LibriVox export**.

Mockup: [`07-import-audio.html`](mockups/07-import-audio.html).

---

## 11. Assembly, rendering, and playback

### 11.1 Inherited

Paragraph-based assembly (Studio Spec §12, implemented): trim take head/tail silence, insert configured gaps, render lossless chapter masters into the content-addressed render cache, preserve paragraph offsets, and build review queues **without rendering whole chapters**.

### 11.2 iPhone rules (M-4)

- Render and export are **chunked by chapter**.
- Long operations are cancellable between chapters and between major file units.
- A **free-space preflight** runs before rendering or export.
- If any required asset is `remoteOnly`, a **hydration plan** is built and shown before work begins.
- If the app backgrounds, the current file finalizes if possible and the remaining steps resume later.

Mockup: [`10-assembly.html`](mockups/10-assembly.html).

---

## 12. Validation

Validation is **ungated** (§2.2) and runs entirely locally.

### 12.1 Levels

Live paragraph checks after each take → chapter checks when a chapter completes → whole-project checks before export → retail readiness preflight before the Pro purchase prompt.

### 12.2 Rules

Inherited from Studio Spec §15 and implemented in `ValidationRuleEngine`: missing metadata/rights; missing selected takes; unresolved needs-pickup; text drift after recording; AI/unknown origin selected for LibriVox; missing disclaimers/credits; clipping, peak, RMS, noise floor, leading/trailing silence; missing metrics; chapter over max duration; artwork too small or not square.

**Four new iPhone codes (🆕, add to `IssueCode`):**

| Code | Severity | Meaning |
|---|---|---|
| `assetRemoteOnlyForExport` | blocking-for-export, **not** a quality failure | export cannot start until the listed assets hydrate; carries the byte estimate |
| `localStorageInsufficient` | blocking | export blocked until the user frees space or reduces scope; carries required vs available bytes |
| `backupNotVerified` | warning | a long project still has `localOnly` originals |
| `routeNotRetailReady` | warning | selected takes were recorded on `draftOnly` routes (§7.1) |

Each MUST carry a `FixAction`: hydrate now / manage storage / back up now / open audio setup.

Mockup: [`13-validation.html`](mockups/13-validation.html).

---

## 13. Packaging and export

### 13.1 Pipeline

```
Choose scope → Choose destination → Hydration + storage preflight → Validate
  → Pro gate (retail only) → Render → Master → Transcode → Tag → Package
  → Checksums → Checklist → Save to Files / Share
```

Free destinations MUST NOT touch `LicenseGate` at any step (§2.2).

### 13.2 Scopes and preflight

Scopes: current chapter · selected chapters · whole book · review-queue range.

Hydration is explicit and stated in bytes, e.g. *"12 chapters are in iCloud. Download 3.4 GB to export."* The user can export only local chapters, hydrate all, or cancel.

### 13.3 Resumable runs (🔧)

`ExportRunRecord` already exists in `Store/`. Stage P7 wires it so a run survives backgrounding and relaunch: the run records completed chapters, and resume restarts at the first incomplete chapter rather than from zero. A canceled run's staging becomes eviction candidate class 2 (§6.5).

### 13.4 Output

Prefer a `.zip` for iPhone sharing; also support "Save folder to Files" where the system destination accepts directories. After a package is saved to Files, offer to evict local staging immediately.

### 13.5 Pro purchase (🆕)

No StoreKit concrete exists today — only the `ProFeature` enum, the gate seam, and `EntitlementCache`. Stage P8 adds a StoreKit 2 implementation in the app target (Core stays StoreKit-free, same pattern as CloudKit):

- Non-consumable, one-time purchase; **Restore Purchases always visible**.
- Purchase entry points: the export destination picker and Settings. Nowhere else.
- Refund or revocation returns the app to free **while preserving every user project and file**.

Mockups: [`14-export-wizard-free.html`](mockups/14-export-wizard-free.html), [`14b-export-run-resume.html`](mockups/14b-export-run-resume.html), [`14c-pro-purchase.html`](mockups/14c-pro-purchase.html).

---

## 14. Watch companion

The watch is a companion, not an editor. Most of it already ships (§5.3).

### 14.1 Capabilities

**Can:** browse production summaries · download review queues · play paragraph audio · approve, flag, mark needs-pickup · dictate notes · act as a recording remote for the active iPhone session.

**Cannot (MUST NOT):** create projects · edit scripts · record primary narration · export · link or touch CloudKit.

### 14.2 Transport

| Direction | Mechanism | Payload |
|---|---|---|
| iPhone → Watch | `updateApplicationContext` | summaries, active queue metadata (`ResolvedQueuePayload`) |
| iPhone → Watch | `transferFile` | paragraph proxy audio, artwork (`WatchAudioItem`) |
| Watch → iPhone | `transferUserInfo`, or `sendMessage` when reachable | `ReviewEvent`s, recording-remote commands |
| Watch, offline | file-backed `WatchReviewOutbox` | append-only, idempotent by event id |

Payload types in `WatchLink/WatchLinkPayloads.swift` do not change (M-3); only the phone-side producer changes.

### 14.3 Recording remote (🆕)

A new command payload in `WatchLink/`: `RecordingRemoteCommand { sessionID, sequence, action }` where `action ∈ {record, stop, accept, retake, flag}`.

- Commands are **idempotent by `(sessionID, sequence)`** — a duplicated `transferUserInfo` MUST NOT produce a second take.
- Commands are only honored while the phone's capture state is `armed` or `recording`; otherwise they are acknowledged and dropped, and the watch shows "iPhone isn't recording."
- The watch shows current paragraph number, elapsed take time, and input level relayed from the phone. **No audio crosses the link.**

**Test:** `RecordingRemoteTests` — replay the same command twice and assert exactly one take; assert a command in `idle` produces no state change.

### 14.4 Storage

200 MB default production queue cache. Queues can be prepared offline before leaving the phone. Eviction is **least-recently-reviewed first**, falling back to queued time for never-reviewed items (R-10, already implemented).

Mockups: [`watch-01-productions.html`](mockups/watch-01-productions.html), [`watch-02-review-player.html`](mockups/watch-02-review-player.html), [`watch-03-offline-queue.html`](mockups/watch-03-offline-queue.html), [`watch-04-recording-remote.html`](mockups/watch-04-recording-remote.html), [`watch-05-dictation.html`](mockups/watch-05-dictation.html).

---

## 15. UI specification

### 15.1 Placement — everything is inside the Voxglass app

There is no second app (R-1). The five-tab glass dock is unchanged:

| Tab | Icon | Label |
|---|---|---|
| `.home` | `headphones` | Listen |
| `.library` | `books.vertical.fill` | My Books |
| `.browse` | `square.grid.2x2.fill` | Explore |
| `.search` | `magnifyingglass` | Search |
| **`.narration`** | `mic.fill` | **Narration** |

Top-level narration surfaces (the tab itself, My Narrations) show the dock. The production flow is a `fullScreenCover` (`NarrationFlowRoot`) and therefore **has no tab bar** — it has its own back/step chrome. The mockups follow this rule exactly: dock on `01` and `15`, no dock inside the flow.

### 15.2 Visual language — glass with fallback

The mockups are drawn from the app's own tokens. **These are the normative values; the mockup CSS is generated from them, not the other way round.**

| Token | Value | Source |
|---|---|---|
| Background | `#0A0B0D`; library gradient `#101216 → #0B0C0F`; warm gradient `#241A10 → #12100C → #0B0C0F` | `VoxglassTheme` |
| Ink | `#F2F4F6` | `Palette.ink` |
| Ink secondary / tertiary | white 92% at 58% / 34% opacity | `Palette.ink2` / `ink3` |
| Accent (brass) | `#E3A44B`, deep `#B97F2E` | `Palette.brass` / `brassDeep` |
| Success / danger | `#4CD471` / `#FF6B5E` | `Palette.ok` / `danger` |
| Hairline | white at 10% | `Palette.hairline` |
| Glass panel | material blur + `#1E2026` at 35% + 1 px white-16% border, radius **26**, shadow `0 10px 18px rgba(0,0,0,.45)` | `AdaptiveGlass` |
| **Fallback panel** | solid `#1E2026` + 1 px white-16% border, radius 26, **no blur, no shadow** | `AdaptiveGlass` reduce-transparency branch |

**Both renderings are mandatory.** `AdaptiveGlass` branches on `accessibilityReduceTransparency`, so every mockup page carries a **Glass / Solid toggle** that flips `data-render` on the root element and shows the exact fallback the app produces. A design that only looks right with blur is not compliant.

Note for anyone diffing against older mockup sets: `docs/voxglass-narration/p0*.html` used gold `#d8ad67`, and `docs/voxglass-mvp/voxglass-iphone-production-mockups/*` used blue `#84b5ff`. Neither matches the app. **The app's brass `#E3A44B` is the compliance target.**

### 15.3 Universal rules (inherited from Studio Spec §18, still binding)

1. All view models are `@Observable` and `@MainActor`. `ObservableObject` fails a CI gate.
2. Every interactive element sets `.accessibilityIdentifier`. The mockups carry the identifiers as HTML `id` attributes so the two stay in sync; adding a control means adding its identifier.
3. Every screen defines four states: loading, empty, content, error. No screen may show an indefinite spinner without a cancel or retry.
4. Dynamic Type is honored everywhere, including accessibility sizes. Fixed-height rows are forbidden in lists that show user text.
5. VoiceOver labels are written for meaning: "Flag paragraph 218 for review", not "flag".
6. Reduced Motion disables the waveform animation and queue transitions.
7. Colors come from `Voxglass/DesignSystem`. **No new color literals.**

### 15.4 iPhone screen inventory

| # | Screen | Mockup | Entry point | Presentation | Owning file |
|---|---|---|---|---|---|
| 01 | Narration tab | [`01-narration-tab.html`](mockups/01-narration-tab.html) | tab bar | tab root | `Discovery/NarrationTabView.swift` |
| 02 | New narration | [`02-new-project.html`](mockups/02-new-project.html) | "Start narrating" on a need, or ＋ | flow step `.importWork` | `Discovery/NarrationFlow.swift` |
| 03 | Source import | [`03-source-import.html`](mockups/03-source-import.html) | after 02 | flow step `.reviewSource` | `Discovery/NarrationFlowScreens.swift` (`SourceReviewView`) |
| 04 | Project dashboard | [`04-project-dashboard.html`](mockups/04-project-dashboard.html) | tap a project in My Narrations | push | 🆕 |
| 05 | Script editor | [`05-script-editor.html`](mockups/05-script-editor.html) | dashboard → Script | push | 🆕 |
| 06 | Recording workspace | [`06-recording-workspace.html`](mockups/06-recording-workspace.html) | Record next / flow step `.record` | flow step | `NarrationFlowScreens.swift` (`RecordView`) |
| 06b | Audio setup | [`06b-audio-setup.html`](mockups/06b-audio-setup.html) | recording toolbar, Settings | sheet | 🆕 |
| 06c | Capture interruption | [`06c-capture-interruption.html`](mockups/06c-capture-interruption.html) | automatic on recovery | banner + sheet | 🔧 in `RecordView` |
| 07 | Import audio | [`07-import-audio.html`](mockups/07-import-audio.html) | recording toolbar → Import | sheet | 🆕 |
| 08 | Take comparison | [`08-take-comparison.html`](mockups/08-take-comparison.html) | take chip → Compare | sheet | 🆕 |
| 09 | Review queue | [`09-review-queue.html`](mockups/09-review-queue.html) | dashboard → Review / flow step `.reviewList` | flow step + push | `ProductionViews.swift`, `ReviewView` |
| 10 | Assembly | [`10-assembly.html`](mockups/10-assembly.html) | flow step `.assemble` | flow step | `AssembleView` |
| 11 | Metadata & rights | [`11-metadata-rights.html`](mockups/11-metadata-rights.html) | flow step `.metadata` | flow step | `MetadataView` |
| 12 | Storage & iCloud | [`12-storage-icloud.html`](mockups/12-storage-icloud.html) | Settings, dashboard storage card | push | 🆕 |
| 13 | Validation | [`13-validation.html`](mockups/13-validation.html) | flow step `.validateExport` | flow step | `ValidateExportView` |
| 14 | Export (free) | [`14-export-wizard-free.html`](mockups/14-export-wizard-free.html) | Validation → Export | sheet | 🔧 |
| 14b | Export run / resume | [`14b-export-run-resume.html`](mockups/14b-export-run-resume.html) | during a run | full-screen progress | 🆕 |
| 14c | Pro purchase | [`14c-pro-purchase.html`](mockups/14c-pro-purchase.html) | retail destination, Settings | sheet | 🆕 |
| 15 | Settings — Narration | [`15-settings.html`](mockups/15-settings.html) | Settings tab → Narration | push | 🔧 |

### 15.5 Dashboard behavior (04)

"Record next" resolves to the first paragraph in document order with no selected take, or — if everything is recorded — the first `needsPickup`. The dashboard leads with that one action, then progress, then review counts, then the storage card, then chapters. For a long work the storage card is expanded by default (§8.3).

### 15.6 What is removed from the UI

- Every "Record on Mac", "Continue on Mac", and handoff affordance (N-1).
- The `LongWorkHandoffSheet` and mockup `n04`.
- Any production CarPlay entry point (M-5).
- Any screen labelled "Voxglass Studio". The paid tier is "Voxglass Narration Pro" everywhere (D-1).

---

## 16. Testing and acceptance

### 16.1 Core suites (Swift Testing, run by `swift test` — this is what CI runs)

Domain coding · eligibility · **asset storage state transitions** · **iCloud manifest and `VGProductionAsset` round-trips** · text import and drift · recording flow with the `AudioCapturing` fake · autosave recovery · metrics and ReplayGain · assembly cache keys · validation rule catalogue (incl. the four new codes) · transcoder CBR/FLAC/M4B · export end-to-end with fake assets · **export run resume** · license gate placement · watch payload and outbox · **recording-remote idempotency** · **`NarrationProject` → `AudiobookProject` migration**.

### 16.2 New test files this MVP adds

`ProductionAssetStateTests` · `CloudAssetUploadTests` · `HydrationPlanTests` · `CaptureRouteClassifierTests` · `CaptureInterruptionTests` · `ExportRunResumeTests` · `RecordingRemoteTests` · `NarrationMigrationTests` · `ChunkedRenderCancellationTests`.

All go in `VoxglassTests/Production/` per repo convention.

### 16.3 UI smoke tests (local pre-commit gate only — **CI runs no simulator**)

CI itself runs on `macos-latest` (`compile`, `logic-tests`, `testflight`) and `ubuntu-latest` (`guarded-tests`); none of them boot a simulator, so the UI smoke tests below are a local pre-commit gate and never run in CI.

**Two**, not five (M-7):

1. **iPhone** — Narration tab → create a project from a need → record two paragraphs with the fake capture → review → validate → LibriVox export path. Folds in My Narrations reachability.
2. **Watch** — review queue → play → approve → dictate a note → offline event reaches the phone exactly once.

Watch UI test gotchas that already cost this repo time and MUST be respected: row taps need `.contentShape`; sheets are **not** `NavigationPath` destinations; the simulator must be pre-booted; use build-then-`test-without-building`; seeders must be idempotent.

### 16.4 CI grep gates (ubuntu-latest, no simulator)

Existing gates in `scripts/guard_production.sh` continue to apply. This MVP adds:

| Gate | Rule |
|---|---|
| G-W1 | `VoxglassWatch/**` MUST NOT reference `CloudKit` (R-7 — restating an existing invariant as an enforced one) |
| G-P2 | `InternetArchivePackageBuilder.swift` MUST NOT reference `ProFeature` or `LicenseGate` (R-9) |
| G-P3 | No file under `Voxglass/Features/` or `VoxglassWatch/` may contain the string `ProductionStudio` (R-2) |
| G-P4 | No new color literals: `Color(hex:` MUST NOT appear outside `Voxglass/DesignSystem/` (§15.3 rule 7) |
| G-P5 | No user-facing string in `Voxglass/Features/Production/**` or `VoxglassWatch/Production/**` may contain "Mac" (N-1, §15.6) |
| G-P6 | No source file and no `project.yml` target may reference `VoxglassStudio` or `VoxglassStudioKit` (D-3). Prevents the deleted tree from being reintroduced by a partial revert. |
| G-P7 | The string `voxglass.studio.pro` MUST NOT appear in any source file (§2.2 rename) |

Every gate MUST have a matching entry in `scripts/test_guards.sh` proving it can fail.

### 16.5 Manual hardware matrix

| # | Scenario | Pass condition |
|---|---|---|
| M-1 | Record 100 paragraphs with a USB mic/interface | no take lost; memory stable; metrics complete |
| M-2 | Unplug the USB interface mid-take | take preserved, route error shown, recovery works |
| M-3 | Lock the phone during a take | recording continues **or** stops with a preserved take; no silent loss |
| M-4 | Force-quit during a take | recovery offers valid audio |
| M-5 | Fill the production cache | remote-verified old chapters evict; `localOnly` takes remain |
| M-6 | Hydrate a remote-only chapter | playback and export work after SHA verification |
| M-7 | Watch offline review | events sync exactly once to the iPhone |
| M-8 | Watch recording remote | start/stop/accept from the wrist; duplicate command produces one take |
| M-9 | LibriVox export | MP3s verify as 128 kbps CBR / 44.1 kHz / mono |
| M-10 | Internet Archive export | FLAC masters + MP3 derivatives, metadata, checksums, checklist complete |
| M-11 | Retail export | an external ACX-style checker agrees with the RMS/peak/noise results |
| M-12 | Pro purchase and restore | entitlement returns after reinstall; projects survive a revocation |
| M-13 | VoiceOver pass | every production flow is reachable |
| M-14 | Reduce Transparency on | every production screen renders the solid fallback correctly (§15.2) |

### 16.6 Release gates

`docs/voxglass-mvp/DESTINATION_VERIFICATION_LOG.md` re-verified · `ThirdPartyNotices.md` current (LAME LGPL-2.1, libFLAC BSD-3) · encoder build reproducible from a clean checkout with **iOS device + iOS simulator + watchOS** slices · the three end-to-end walkthroughs (LibriVox free, Internet Archive free, Retail Pro) executed on real hardware with a real microphone.

---

## 17. Stage plan

Each stage is one reviewable commit whose body names the acceptance criterion it satisfies. Stages are **P**-numbered to distinguish them from the speculative S-numbers (R-5).

### P0 — Remove the macOS Studio surface and rename Pro

Decision D-3 makes this the first stage, not a cleanup at the end: `VoxglassTests/Performance/PerformanceBudgetTests.swift` does `@testable import VoxglassStudioKit`, so the Mac module cannot simply stop building — the coupling has to be cut before anything else moves.

Delete, in one reviewable commit:

- The `VoxglassStudio/`, `VoxglassStudioTests/`, and `VoxglassStudioUITests/` trees (58 source + 20 test files).
- The `VoxglassStudio`, `VoxglassStudioUITests`, and Studio scheme entries in `project.yml`; then `xcodegen generate`.
- `VoxglassStudio/Resources/VoxglassStudio.storekit`, replaced by `Voxglass/Resources/VoxglassNarration.storekit` carrying the new product ID (§2.2).

Repair the two couplings the deletion exposes:

- `VoxglassTests/Performance/PerformanceBudgetTests.swift` — drop `@testable import VoxglassStudioKit`. The budgets it asserts are Core budgets; retarget it at `VoxglassCore`. If any single budget genuinely measured Mac-only code, delete that budget rather than preserving the import.
- `VoxglassTests/Production/AccessibilityAuditTests.swift` — remove `case studio = "VoxglassStudio"` from its directory enum so the audit scans only shipping surfaces.

Then apply the Pro rename table in §2.2, and add gates G-P6 and G-P7 with their `scripts/test_guards.sh` counterparts.

Do **not** delete any document. `docs/voxglass-mvp/VOXGLASS_STUDIO_SPEC.md` remains the inherited normative reference for everything this spec does not restate (§3, §8.1, §11.1, §12.2).

**Acceptance:** `swift test` green with no `VoxglassStudio*` target in `project.yml`; gates G-P6 and G-P7 green and proven failable; the iPhone and Watch smoke tests still pass.

### P1 — Land and finish the storage kernel

Commit the uncommitted `CloudAssets/` work. Add the `production_asset` SQLite migration, the asset repository, and the eviction **executor** (the planner already exists). Wire `ProductionProjectLayout` as the single source of path truth.

**Acceptance:** a 20-chapter fake project evicts non-working chapters under a 1 GB cap, never touches `localOnly`/`uploading`/pinned assets, and the state survives a relaunch.

### P2 — One project model + migration

Repoint `NarrationFlow` and `NarrationFlowScreens` at `SQLiteProductionStore`. Implement and ship the `NarrationProject` migration (§4.3.3). Delete `NarrationProjectStore` and its types once the migration is proven.

**Acceptance:** `NarrationMigrationTests` green; the iPhone UI smoke test creates a project through the flow and the resulting project is visible to `ProductionPreviewStore` and to the watch.

### P3 — Invert sync; asset upload and hydration

Flip `PhoneProductionSync` and `ProjectionPublisher` to phone-as-writer. Add the `VGProductionAsset` record type, upload-with-SHA-verification, resumable hydration, and the degraded conflict path (§4.2).

**Acceptance:** upload survives a mid-flight kill without ever becoming evictable; a `remoteOnly` chapter hydrates and verifies; no conflict UI is reachable.

### P4 — Capture hardening and audio setup

Introduce the ring buffer + writer task, the full interruption matrix, `CaptureRouteClassifier`, per-take route storage, and the Audio Setup screen.

**Acceptance:** `CaptureInterruptionTests` green for every row of §7.4; manual M-1 and M-2 pass on real hardware.

### P5 — Long works, dashboard, script editor

Remove the Mac handoff, add the project dashboard (04) and script editor (05), multi-session framing, and "Record next" resolution.

**Acceptance:** a 12-chapter TXT import reaches a dashboard with correct per-chapter counts; gate G-P5 green.

### P6 — Take comparison, audio import, assembly

Add take comparison (08), external audio import with origin declaration (07), and the assembly controls with chunked, cancellable rendering.

**Acceptance:** an imported non-human-origin take blocks LibriVox validation; a chapter render cancels cleanly mid-run and resumes.

### P7 — Validation, free export, resumable runs

Add the four iPhone issue codes and their fix actions; wire hydration and storage preflight into the export pipeline; make export runs resumable; ship the LibriVox and Internet Archive lanes end to end with Save to Files.

**Acceptance:** a LibriVox fixture exports verified 128 kbps CBR MP3 from the device; an IA export produces FLAC + MP3 + checksums + checklist with **no** license check on the path (gate G-P2).

### P8 — Watch recording remote + Pro retail

Add the recording-remote command path (phone and watch). Add the StoreKit 2 concrete, retail profiles, mastering, M4B, and validation-report export.

**Acceptance:** `RecordingRemoteTests` green and manual M-8 passes; a retail export hydrates remote chapters, resumes after interruption, and produces ACX-compliant files from fixture audio.

### P9 — Hardening and release

Storage stress, iCloud quota behavior, route changes, low power, VoiceOver, Reduce Transparency pass, App Store review notes, third-party notices, the three walkthroughs.

**Acceptance:** the §16.5 matrix passes and this spec and its mockups are synchronized with the shipped UI.

---

## 18. App Store notes

**Review note:** "Voxglass is an audiobook player that also lets users record their own narration. The app records the user's own voice and creates local export packages for audiobook distribution. It does not upload content to retailers and does not determine copyright status. The in-app purchase unlocks commercial export formats and mastering; LibriVox and Internet Archive exports are free."

**Privacy:** no analytics required; iCloud backup and offload use the user's own private CloudKit database; manuscript text and audio stay on device and in the user's iCloud unless the user exports them; microphone use is explained in-context before the first recording.

**IAP:** digital functionality uses StoreKit; non-consumable one-time purchase; Restore Purchases always visible; refund or revocation returns the app to free **while preserving user projects**.

---

## 19. Decisions taken

Resolved with the product owner on **2026-08-07**. These are no longer open; an implementing agent follows them without re-asking. Each records the reasoning so a future reader can tell a decision from an accident.

| # | Decision | Why | Lands in |
|---|---|---|---|
| **D-1** | **Rename Pro.** Product ID `guru.parso.voxglass.studio.pro` → **`guru.parso.voxglass.narration.pro`**; display name → **"Voxglass Narration Pro"**. The two `EntitlementCache` `UserDefaults` keys move with it. | The IAP has never been configured in App Store Connect — it exists only in a local `.storekit` sandbox file and two key strings, and no StoreKit concrete has ever written an entitlement. Renaming is free today and permanent after the first sale, so this was the last cheap moment. | P0 (§2.2) |
| **D-2** | **Reprice to $49 introductory / $79 standard**, down from $99 / $149. | The old figure was set for a Mac-class desktop tool. An iPhone-only unlock skews toward less professional narrators, and $149 sits at the very top of what a one-time iOS IAP bears. Nothing in code depends on the number — it is an App Store Connect value set at submission. | Submission, not code |
| **D-3** | **Delete the macOS Studio tree outright** — `VoxglassStudio/`, `VoxglassStudioTests/`, `VoxglassStudioUITests/`, their `project.yml` targets, and the Studio `.storekit`. | "Leave it unbuilt" was not actually free: `PerformanceBudgetTests` imports `VoxglassStudioKit`, so the module could not stop building without breaking a shipping test, and `AccessibilityAuditTests` kept auditing dead code. Recovery is via git history. **Docs are not deleted** — the Studio Spec remains the inherited reference. | P0 |
| **D-4** | **The Narration tab is always visible** in the 5-tab dock. No hiding, no user toggle. | Narration is the bet this MVP makes; hiding the front door contradicts the bet, and a conditional dock is a surface that has to be tested in both states forever. Cost accepted: one of five dock slots for listen-only users. | Unchanged from current behavior |
| **D-5** | **Working-cache limit stays 10 GB default, adjustable 2–100 GB**, but the *initial* value is clamped at first run to about 15% of free space. | The preflight warning is a safety net that only fires after the user has already filled the disk. A first-run clamp costs one line and prevents a 128 GB device from adopting a 10 GB narration cache it cannot afford. The user can still raise it to 100 GB deliberately. | P1 |

### 19.1 Still genuinely undecided

Nothing blocking. Two items are deliberately deferred because they cannot be answered before the product is in hands:

- **Watch complication / Smart Stack presence.** Not in scope, not stubbed toward (DEFERRED per §0.3). Revisit after P9 with real usage.
- **Whether the retail lane needs a second tier** (e.g. mastering without the full retail profile set). `ProFeature` is already an enum precisely so a future tier split is mechanical; do not pre-build it.
