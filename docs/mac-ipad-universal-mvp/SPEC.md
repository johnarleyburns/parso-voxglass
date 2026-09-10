# Voxglass — Mac + iPad Universal MVP — Delta Specification

**Status:** implementable specification. **Extends** `docs/iphone-watch-only-revised-mvp/SPEC.md` (the *revised* spec, which remains normative for everything not restated here).
**Date:** 2026-08-11.
**Mockups:** [`mockups/index.html`](mockups/index.html).

---

## 0. How to use this document

### 0.1 What this document is

The revised spec answered the question *"can one person narrate an audiobook on a phone?"* correctly, shipped it across stages P0–P9, and closed thirteen gaps on 2026-08-10. It is implemented. `swift test` is green at 1319 tests / 189 suites.

It answered that question by **deleting the Mac** (correction M-1, decision D-3, stage P0) and by making the iPhone the **sole writer** of every project (§4.2, correction M-2). Both were right for a phone-and-watch MVP. Neither survives the decision to ship a macOS app.

This document is therefore a **delta over a delta**, in the same house style: it inherits the revised spec's conventions verbatim, restates in full only what changes, cites the source section for everything that does not, and carries an explicit corrections table for each decision it reverses. Where the revised spec deleted something this spec restores, the restoration is named, the reason the deletion was correct at the time is recorded, and the CI gate that enforced the deletion is explicitly amended.

**What is new in this MVP:**

1. A **native macOS app**, distributed by **Universal Purchase** under the existing bundle ID, whose reason to exist is *keyboard-driven narration control across multiple audiobooks at once*.
2. **iPad as a first-class narration surface** — full capability, adaptive layout, hardware-keyboard control. Mockups only in this document; the iPad already runs the shipping app.
3. A **two-writer concurrency model** replacing the single-writer model, because a Mac that records is by definition a second writer.
4. The free/Pro boundary **unchanged in substance** and now **shared across all three platforms** by one Universal Purchase.

### 0.2 Reading order for an implementing agent

1. **§0.5–§0.7** — the corrections tables (U-, G-, and R2-series). These are the only places a decision *changes*.
2. **§2** — Universal Purchase and the free/Pro boundary. The bundle-ID constraint in §2.1 is load-bearing and pins a value that cannot be changed after the first Mac sale.
3. **§4** — architecture, and specifically **§4.3, the two-writer merge model**. This is the pivotal change and the largest single piece of work, exactly as §4.3 of the revised spec was for its MVP.
4. **§5** — implementation status inventory, **including §5.3, the per-file disposition of the resurrected macOS tree.** Read this before writing any file. Most of the Mac app already exists in `VoxglassMac/`; much of it is stale in specific, named ways.
5. **§8** — the macOS keyboard and multi-project model. This is the product reason the Mac app exists; it is not chrome.
6. **§17** — stage plan U0–U9. One reviewable commit per stage with a stated acceptance test.
7. §6–§16 as reference while implementing a stage.

### 0.3 Normative language

Inherited unchanged from revised spec §0.3 (**MUST / MUST NOT / SHOULD / MAY / DEFERRED**), and so are the repository conventions: XcodeGen from `project.yml`; bundle prefix `guru.parso`; Core at `Voxglass/Core/<Area>/`; hand-rolled SQLite actors, **no GRDB**; `@Observable` only, `ObservableObject` banned; `Date()`/`UUID()` only through the `Clock`/`IDGenerator` seams; `///` on every `public` symbol; one commit per stage; **Swift 6 language mode with complete strict concurrency, no exceptions** (`CLAUDE.md`).

### 0.4 Precedence

When two documents disagree:

```
this document  >  docs/iphone-watch-only-revised-mvp/SPEC.md
               >  docs/voxglass-mvp/VOXGLASS_STUDIO_SPEC.md
               >  docs/voxglass-narration/NARRATION_NEEDS_SPEC.md
```

If this document and the **repository** disagree on a *fact* — a file path, a type name, an existing behavior — the repository wins and the discrepancy is reported. If they disagree on *intent*, this document wins. Never silently pick one. (Inherited from the revised agent brief.)

### 0.5 Corrections to the revised spec (U-series)

An implementing agent MUST follow the right-hand column.

| # | Revised spec said | Why it was right then | This spec says |
|---|---|---|---|
| **U-1** | M-1 / D-3: "**macOS Studio is out of this MVP.** No Mac app target, no AppKit entitlements, no security-scoped bookmarks, no Finder-first `.voxproject` workflow, no `StudioCommands`." The tree was deleted in P0. | A shipping test (`PerformanceBudgetTests`) imported `VoxglassStudioKit`, so the module could not merely stop building; and a phone-first MVP could not afford a second UI layer. | **Reversed.** A native macOS app ships in this MVP. The tree is **resurrected from `c0c6712^` into `VoxglassMac/`** (§5.3) — not rewritten. AppKit entitlements, security-scoped bookmarks, the Finder-first `.voxproject` workflow, and the menu-bar command set all return, adapted per §5.3. |
| **U-2** | §1.3: the macOS Studio app, Mac project windows, the Finder-first workflow, and the Mac→phone projection are "explicitly **removed** from the MVP". | Same as U-1. | **Restored, with the projection direction inverted a second time** — see U-4. The iPhone→Mac *handoff* (N-1) is **not** restored: length never gates the record action on any platform, and no screen may present the Mac as a prerequisite (§15.6, gate G-U1). |
| **U-3** | §2.2: Pro is one non-consumable IAP, product id `guru.parso.voxglass.narration.pro`, iOS-only. | Correct, and the rename in P0 was the last cheap moment to do it. | **Unchanged product id, now Universal Purchase.** One purchase unlocks Pro on iPhone, iPad, and Mac. This pins the macOS bundle id to **`guru.parso.voxglass`** (§2.1) — the old `guru.parso.voxglass.studio` id is dead and MUST NOT return. |
| **U-4** | §4.2 / M-2: "**The iPhone is the writer.** … There is no second editing surface, therefore **no projection conflict model**: `ProductionSyncEngine`'s conflict path degrades to last-writer-wins-by-revision with the phone always the writer. … A test MUST prove no user-visible conflict UI is reachable." | With one writer, a conflict model is untestable dead weight, and the degraded path was honest about that. | **Reversed.** Mac, iPad, and iPhone are **peer writers** (§4.3). The conflict path is restored to a real merge with a **user-visible resolution surface**, and the test that proved conflict UI unreachable is **inverted**: a test MUST now prove it *is* reachable and correct. The merge is deliberately narrow — §4.3.2 reduces genuine conflict to exactly one case. |
| **U-5** | §1.5.7: "Narration never degrades listening. The Narration tab is additive; the consumer player, downloads, CarPlay, and position sync are untouched." | Correct and still binding. | **Unchanged, and extended to macOS.** The Mac app ships the full Voxglass app — Listen / My Books / Explore / Search **and** Narration (decision D-U3). Losing a user's playback position remains a hard product failure on every platform. |
| **U-6** | §15.1: "There is no second app (R-1). The five-tab glass dock is unchanged." | Correct for iOS. | **Unchanged for iPhone.** There is still no second *iOS* app. The macOS app is the **same app record and the same bundle id** on a different platform — not a second app in the App Store sense (§2.1). On macOS the five tabs become a **source-list sidebar**, not a dock (§15.2); on iPad in regular width they become a sidebar as well (§9.2). |
| **U-7** | §5.1 `Audio/`: "✅ as-is". P4 then added a C-atomics ring buffer (`VoxglassRing` + `Core/Production/Audio/CaptureRingBuffer.swift`). | Correct at the time of writing. | The resurrected `VoxglassMac/Services/CaptureRingBuffer.swift` (219 lines, Swift) is **superseded by Core's** (57 lines over the `VoxglassRing` C target) and MUST be deleted rather than adapted (§5.3). The same applies to every resurrected file marked **superseded** in §5.3. |
| **U-8** | §16.3 / M-7: "**Two** UI smoke tests: iPhone and Watch." | Correct when the Mac was deleted. | **Three**: iPhone, Watch, **Mac**. All three remain a **local pre-commit gate**; CI still boots no simulator. The Mac smoke test needs no simulator, but it needs signing, so it stays local too. CI regains a **compile-only macOS job** (§16.3). |

### 0.6 Corrections to the CI gates (G-series)

The revised spec's gates in `scripts/guard_production.sh` are what actually stop this work at commit time. Stage **U0** amends them, with a matching failable probe in `scripts/test_guards.sh` for every change. **An agent MUST NOT weaken a gate as a side effect of another stage** — gate changes land in U0 and only in U0.

| Gate | Today | This spec |
|---|---|---|
| **G-P5** — no `Mac` word in `Voxglass/Features/Production/**` or `VoxglassWatch/Production/**` | Bans the word outright (N-1, §15.6). | **Replaced by G-U1.** The word "Mac" is now legitimate: device-presence indicators, conflict resolution ("edited on your Mac"), and the Universal Purchase copy all name it. G-U1 keeps the *original intent* by banning the **retired handoff phrasing** instead — the exact strings `Record on Mac`, `Continue on Mac`, and `Requires a Mac` MUST NOT appear anywhere in `Voxglass/`, `VoxglassMac/`, or `VoxglassWatch/`. Length still never gates the record action on any platform. |
| **G-P6** — no `VoxglassStudio` in source, in `project.yml`/`Package.swift`, or as a directory | Greps `Voxglass VoxglassWatch VoxglassCoreTestSupport VoxglassTests`; checks the three old directories are absent. | **Retained and extended to `VoxglassMac VoxglassMacTests VoxglassMacUITests`.** The resurrected tree carries the old name in eleven files (§5.3); U0 renames them. The three old directory names stay banned — the tree lives at `VoxglassMac/`, and a partial revert that recreates `VoxglassStudio/` is still a failure. |
| **G-P7** — `voxglass.studio.pro` MUST NOT appear | Greps the four iOS/watch/test paths. | **Retained and extended to `VoxglassMac`.** The resurrected `StoreKitLicenseProvider.swift`, `SettingsModel.swift`, and `Resources/VoxglassStudio.storekit` all carry the dead id; U0 removes them in favour of `NarrationProProduct.productID` and the shipping `Voxglass/Resources/VoxglassNarration.storekit`. |
| **G-P4** — no `Color(hex:` outside the DesignSystem | Scoped to the two production surfaces. | **Extended to `VoxglassMac/`.** The Mac app uses the same `Palette`; §15.3 rule 7 is platform-independent. |
| **G-P2** — `InternetArchivePackageBuilder` MUST NOT reference `ProFeature`/`LicenseGate` | Unchanged. | **Unchanged and now more important**: the free lanes must stay free on a platform where the user has just been shown a purchase sheet. |
| **G-P3**, **G-W1**, and every other existing gate | — | **Unchanged.** |
| **G-U2** 🆕 | — | Core stays platform-free: `import AppKit` and `import UIKit` MUST NOT appear anywhere under `Voxglass/Core/`. (The rule was previously implicit; a Mac app makes it worth enforcing.) |
| **G-U3** 🆕 | — | Universal Purchase: the `VoxglassMac` target's `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` MUST be exactly `guru.parso.voxglass` (§2.1). A grep on `project.yml` is sufficient and is the cheapest possible guard against a mistake that is irreversible after the first sale. |
| **G-U4** 🆕 | — | `ObservableObject` MUST NOT appear in `VoxglassMac/` (§15.3 rule 1, extended to the new surface). |
| **G-U5** 🆕 | — | `LicenseGate` / `isPro` placement (§2.3) is extended to the Mac: the permitted files list gains the Mac export destination picker, the Mac export runner, and Mac Settings, **and nothing else**. `LicenseGatePlacementTests` is extended rather than duplicated. |

### 0.7 Corrections carried forward, restated (R2-series)

These were correct in the revised spec, are unchanged, and are restated **only because the return of the Mac creates an obvious temptation to break them**.

| # | Rule | Still binding because |
|---|---|---|
| **R2-1** | **`AudiobookProject` in the SQLite production store is the one project model** (revised §4.3.2). | The Mac must not reintroduce a second model, a document type wrapper, or an in-memory "Mac project". `ProjectPackage` + `SQLiteProductionStore` is what a `.voxproject` *is*, on every platform. |
| **R2-2** | **Reuse `.voxproject`** (R-8). No second package format. | The Finder-first Mac workflow returns; the package it opens is byte-identical to what the phone writes. |
| **R2-3** | **Keep the existing CloudKit zone and record types** (R-4): `VGProductionStudioZone`, `VGProductionProject`, `VGProductionChapter`, `VGProductionParagraph`, `VGReviewEvent`, `VGProductionAsset`. | Record types are not renameable in place, and the zone name's "Studio" is now merely historical. The two-writer model adds **fields**, not types (§4.3.4). |
| **R2-4** | **The watch never links CloudKit** (G-W1) and never becomes an editor. | A Mac in the mix does not change what a watch is. |
| **R2-5** | **Free must be complete**; validation is never gated; LibriVox and Internet Archive never hit a Pro gate. | Unchanged on all platforms (§2.2). |
| **R2-6** | **Never lose a take** (§9.4 write ordering) and **never evict before verified** (§6.1). | The Mac gets its own capture path and its own eviction executor; both obey the same MUSTs. |

---

## 1. Product definition

### 1.1 One sentence

Voxglass is an audiobook *listening* app that also lets you **narrate one** — on your phone, on your iPad, or at a desk on your Mac where the keyboard makes narrating several books at once tractable — with your watch as the review and remote-control companion.

### 1.2 What each platform is for

The revised spec's §1.2 job statement is unchanged: a solo LibriVox volunteer, indie author, or semi-pro who wants to finish and submit a real recording. What changes is that this person is no longer assumed to own only a phone.

| Surface | Job | Creates audio? | Writes project state? |
|---|---|---:|---:|
| iPhone — Narration tab | The full flow, one project at a time, anywhere | **Yes** | **Yes — peer writer** |
| iPad — Narration tab | The full flow, with a split-view script/record layout and hardware-keyboard control in regular width | **Yes** | **Yes — peer writer** |
| **macOS — Voxglass** | The full flow **plus** what only a desk affords: keyboard-driven capture, multi-window and cross-project work, a project library, batch export, and a cross-project review queue | **Yes** | **Yes — peer writer** |
| Apple Watch — companion | Offline review queues, playback, approve/flag/pickup, dictated notes, recording remote | No | No — append-only events |
| iCloud private database | Backup, offload, **and now the merge point between writers** | No | Remote mirror + merge substrate |

**Still explicitly removed**, and not restored by this document: the iPhone→Mac long-work handoff (N-1); production CarPlay (M-5); any screen that presents a Mac as a *prerequisite* for anything (gate G-U1).

### 1.3 Why macOS, stated once

So the reason is not re-litigated or diluted into "parity":

A narrator working through a 400-paragraph book performs the same four actions thousands of times — record, listen, accept, advance. On a touch screen each is a look-aim-tap. On a keyboard each is one key, performed without looking away from the text, and a **USB footswitch presents to macOS as a keyboard**, which means the shortcut map in §8.2 is also the hardware-pedal map. That is the whole argument for the Mac app, and §8 is where it is cashed out. A Mac app that merely mirrors the iPhone screens on a bigger canvas would not be worth its maintenance cost.

The second argument is plural: a person narrating **more than one** audiobook has a management problem the phone flow deliberately does not solve. The phone's front door is need-first and wizard-shaped (R-6) and should stay that way. The Mac's front door is a **library** (§8.4).

### 1.4 Distribution lanes

Unchanged from revised §1.4 — and identical on all three platforms. The lane, not the device, decides the tier.

| Lane | Tier | Output |
|---|---|---|
| LibriVox | Free | 128 kbps CBR mono MP3 per section, ID3 tags, durations, checklist |
| Internet Archive | Free | **FLAC** lossless masters + MP3 derivatives, metadata sidecars, checksums, `ia upload` command, checklist |
| Personal master | Free | Lossless WAV chapters |
| Commercial retail | **Pro** | ACX/aggregator MP3, mastered files, M4B, commercial FLAC masters, retail sample, metadata, exported validation reports |

**MUST NOT** introduce a platform-conditional tier. "Free on iPhone, Pro on Mac" for the same lane is forbidden; so is the reverse. A grep gate cannot catch this, so it is called out here and in §2.3.

### 1.5 Product principles

The seven principles of revised §1.5 are inherited verbatim. One is added:

8. **A second device may never cost you work.** Concurrent editing resolves by merge, not by "last device to sync wins the whole project". Takes are append-only and never lost to a merge (§4.3.2); the single case that can genuinely conflict is surfaced to the user rather than silently resolved (§4.3.3).

---

## 2. Universal Purchase and the free / Pro boundary

### 2.1 Universal Purchase — the bundle-id constraint

Universal Purchase requires the macOS app to ship **in the same App Store Connect app record as the iOS app**, which in turn requires it to use the **same bundle identifier**. Therefore:

| | Value |
|---|---|
| iOS app bundle id | `guru.parso.voxglass` *(unchanged, shipping)* |
| **macOS app bundle id** | **`guru.parso.voxglass`** *(same — this is the requirement, not a convention)* |
| watchOS app bundle id | `guru.parso.voxglass.watchkitapp` *(unchanged)* |
| Pro IAP product id | `guru.parso.voxglass.narration.pro` *(unchanged; shared across platforms by the shared record)* |
| StoreKit test config | `Voxglass/Resources/VoxglassNarration.storekit` *(unchanged; the Mac scheme points at the same file)* |

The dead `guru.parso.voxglass.studio` bundle id from the deleted Studio target MUST NOT return (gate G-P7 for the product id; gate **G-U3** pins the bundle id).

> **Verify before submission.** Apple's Universal Purchase requirements are an App Store Connect policy, not a compile-time constraint, and this document's author cannot see the current documentation. Re-read Apple's current Universal Purchase and macOS-app-in-an-iOS-record guidance at submission time and record the result in `RELEASE_CHECKLIST.md` (§16.6). If the bundle-id requirement has changed, **the value above is still the right choice** — one record, one id, one purchase — but the *reason* recorded here should be corrected.

Because entitlement is granted per Apple ID across the shared record, the StoreKit 2 concrete needs **no cross-platform code**: `Transaction.currentEntitlements` already reports the purchase on every platform the account owns. What the Mac needs is the concrete itself and the two purchase entry points — nothing more (§13.5).

### 2.2 Free forever — unchanged, on every platform

Everything in revised §2.1 is free on iPhone, iPad, and Mac: unlimited projects, chapters, paragraphs, takes, and recording time; source import; script editing, split/merge, drift detection, generated LibriVox disclaimers; recording, retakes, take comparison, imported-audio assignment; audio setup and quality metrics; review queues on every device, dictation, offline queue; iCloud backup/offload; **full validation for every destination, including retail**; LibriVox export; Internet Archive export **including FLAC masters**; personal WAV export.

Added to the free tier by this MVP, because they are *navigation*, not *output*:

- The macOS **project library**, multi-window, and native window tabbing (§8.4).
- The macOS **cross-project review queue** (§8.5).
- The full macOS **keyboard map** (§8.2). A shortcut is not a feature you can sell.
- **Two-writer sync and conflict resolution** (§4.3). Never losing work is not a paid feature, for the same reason position sync is deliberately free.

### 2.3 Pro — unchanged, gated in six places

The seven `ProFeature` cases are unchanged: `retailPresets` · `mastering` · `m4bExport` · `flacExport` *(commercial masters only)* · `batchExport` · `commercialMetadata` · `validationReportExport`.

`batchExport` deserves a note: it already existed as a Pro feature and the Mac is the first surface where it is genuinely useful (§8.6). It is **not** re-scoped, re-priced, or moved.

**Gate placement (MUST).** Revised §2.2 permitted `LicenseGate`/`isPro` in exactly three files. This spec permits **six** — the same three roles, once per UI platform:

| Role | iOS file | macOS file |
|---|---|---|
| Export destination picker | shipping | `VoxglassMac/Features/Export/ExportWizardView.swift` |
| Export runner | shipping | `VoxglassMac/Features/Export/ExportModel.swift` |
| Settings | shipping | `VoxglassMac/Features/Settings/SettingsModel.swift` |

**Six, not seven — batch export does not get its own gate site.** The batch runner (§8.6) is a loop over the single-project export path, so it **MUST** route its Pro check through `ExportModel` rather than consulting `LicenseGate` itself. This is not bookkeeping to satisfy a test: one gate check per destination decision means a free lane cannot become gated by being run in a batch, which is exactly the failure mode `batchExport` invites.

`LicenseGate` MUST NOT appear in recording, review, validation, assembly, storage, sync, the project library, the keyboard map, the batch runner, or watch code — on any platform. `LicenseGatePlacementTests` is **extended** with the three Mac paths, not duplicated (gate G-U5).

### 2.4 Pricing — reopened, deliberately not decided here

Decision D-2 set $49 introductory / $79 standard, and its recorded reasoning was explicitly *"The old figure was set for a Mac-class desktop tool. An iPhone-only unlock skews toward less professional narrators."* **That premise no longer holds.** The unlock is no longer iPhone-only.

This document does **not** re-price, because nothing in code depends on the number (revised §2.2: the price lives in App Store Connect and is set at submission) and because the right number depends on market information an implementing agent does not have. It is recorded here as **open item O-1 (§19.1)** so the product owner decides it before submission rather than discovering it at submission. **No code change follows from any answer.**

---

## 3. External requirements

**Inherited unchanged** from revised §3, which inherits from Studio Spec §3. All numeric constants live in `Voxglass/Core/Production/Destinations/` and MUST be imported, never restated. Re-verification before release remains a release gate (§16.6).

The one platform-specific note: destination requirements are **properties of the destination**, not of the recording device. A Mac-recorded chapter and a phone-recorded chapter face identical thresholds, and `ValidationRuleEngine` MUST NOT gain any device-conditional branch. What *is* device-influenced is the capture route (§7.1) — which is already stored per take (`Take.routeClass`) precisely so that validation reads history rather than hardware.

---

## 4. Architecture

### 4.1 Module topology

```
Voxglass/Core/Production/          — pure, platform-free (gate G-U2), CloudKit-free except Sync/CloudKit*
  Domain/ Store/ Text/ Audio/ Assembly/ Review/ Validation/
  Packaging/ Destinations/ Package/ CloudAssets/ Sync/ WatchLink/
  License/ Discovery/
  Merge/        three-way paragraph merge, conflict set, resolution plan     ← 🆕 §4.3
  Presence/     which device is editing what, advisory only                  ← 🆕 §4.4

Voxglass/Features/Production/      — iPhone + iPad UI (one target, adaptive)
  Discovery/    Narration tab, needs shelf, the narration flow
  Adaptive/     size-class routing: compact → flow, regular → split view     ← 🆕 §9
  …             My Productions, production player, paragraph list, review
                queue builder, note sheet, sync & storage, watch transport

VoxglassMac/                       — macOS app (resurrected from c0c6712^, §5.3)
  App/          app entry, menu-bar commands, environment, root window
  Features/     Library, NewProject, SourceImport, Script, Record, Review,
                TakeCompare, ImportAudio, Assemble, Metadata, Validate,
                Export, Settings, Dashboard, Discovery, DevicePreview
  Services/     AVFoundation capture/render/playback, package lock, recents,
                StoreKit, diagnostics
  Support/      undo, UI-test fakes
  Sync/         Mac-side sync coordination

VoxglassWatch/Production/          — watchOS companion (unchanged)
```

**MUST NOT** create `Voxglass/Features/ProductionStudio`, `VoxglassWatch/ProductionStudio` (R-2, gate G-P3), or re-create `VoxglassStudio/` (gate G-P6).

**Core stays platform-free.** Everything the Mac shares with the phone — the store, the text pipeline, metrics, assembly, validation, packaging, sync, merge — lives in `VoxglassCore` and is compiled for macOS by the existing `Package.swift`, which already declares `.macOS(.v14)`. AppKit and UIKit imports are banned from Core by gate G-U2. What is genuinely Mac-only is the *AV concrete*, the *window and menu model*, and the *file-system entry point*.

### 4.2 The two-writer model, stated plainly

Revised §4.2 said "the iPhone is the only writer of project metadata and take selection." **That sentence is repealed.** In its place:

> **Every full-capability device — iPhone, iPad, Mac — is a peer writer. The user's private CloudKit database is the merge point. No device is authoritative. There is no ownership, no lock, no "take over editing" handshake, and no read-only mode.**

Three properties make this tractable rather than terrifying, and each is a design choice, not an accident:

1. **Takes are content-addressed and append-only.** A take is identified by the SHA-256 of its bytes and inserted, never updated in place (revised §9.4). Two devices recording the same paragraph produce two takes, and the merge is a **set union**. **No take is ever lost to a merge.** This alone removes the frightening case.
2. **Review state is already an event fold.** `ReviewEventFolder` folds append-only `ReviewEvent`s and is idempotent by event id — it was built that way for the watch. Two devices producing review events merge by *appending both event streams and re-folding*. This is not new work; it is the existing mechanism used at a second scale.
3. **Assets are content-addressed.** Two devices uploading the same bytes converge by definition.

What remains is the small set of genuinely mutable, genuinely singular values — and that is where §4.3 does its work.

### 4.3 The merge model — the pivotal decision

#### 4.3.1 Granularity

Merge is **per entity and per field**, never per project. A project is not a document with one revision; it is a set of independently-addressed rows that happen to share an id. The unit of identity is the **paragraph** (product principle §1.5.2, "the text is the index"), so the unit of merge is the paragraph too.

Each syncable row gains three columns, added as one append-only numbered migration in `ProductionMigration`:

| Column | Meaning |
|---|---|
| `revision` | monotonic per row, incremented on every local mutation *(already exists on the project record; extended to chapter and paragraph)* |
| `modified_by_device` | stable per-install device id, from a new `DeviceIdentity` seam in `Core/Domain/` (never `UIDevice`/`Host`, never in Core) |
| `synced_text_hash` | **paragraph only.** The text hash last known to be on the server — the common ancestor for three-way merge. Null until first sync. |

#### 4.3.2 The merge rules (MUST)

This is the normative table. An implementing agent implements exactly these and adds none.

| Entity / field | Rule | Can conflict? |
|---|---|---|
| **Take rows** | **Union by take id.** Never updated, never deleted by merge. Archived-state changes merge last-writer-wins by `revision`. | **No — by construction** |
| **Asset rows** | Union by `sha256`. State is device-local; `remote_asset_id` is server truth. | **No** |
| **Review events** | Append both streams; re-fold. Idempotent by event id (existing `ReviewEventFolder`). | **No** |
| **Review state** (derived) | Output of the fold. Never merged directly. | **No** |
| **Selected take** | Last-writer-wins by `(revision, modifiedAt, deviceID)` — deterministic tiebreak, `deviceID` compared lexically only to break exact ties. The losing selection's take still exists (union), so the user can re-pick. | No |
| **Project metadata** (title, author, rights, destination, assembly settings) | **Field-level** last-writer-wins by the same triple. Field-level, not record-level, so editing the title on the Mac cannot revert a rights attestation made on the phone. | No |
| **Chapter set** | Additive union by chapter id, with tombstones for deletion. A chapter deleted on one device and edited on another **survives** (edit wins over delete — the conservative direction). | No |
| **Chapter / paragraph ordering** | `global_ordinal` is renumbered by the existing `renumberGlobalOrdinals()` after merge, from a merged order computed as: chapter order last-writer-wins; within a chapter, paragraph order follows the surviving structural revision. | No |
| **Paragraph text** | **Three-way.** Fast-forward when only one side moved from `synced_text_hash`. **Conflict** when both sides moved *and* the two results differ. | **YES — the only case** |
| **Direction notes, pronunciation** | Field-level last-writer-wins. | No |
| **Export runs** | **Never synced.** Device-local by definition (an export writes files to *this* machine). | No |
| **Working-cache and eviction state** | **Never synced.** Device-local. | No |

**The claim this table makes, and that the tests must prove:** *the only user-visible conflict in Voxglass is a paragraph whose text was edited on two devices since they last agreed.* Everything else converges without asking. That claim is what makes a two-writer model shippable inside one MVP stage rather than three.

#### 4.3.3 Conflict resolution (the one case)

When the merge produces a non-empty conflict set, the project opens normally — **merge never blocks work** — and a persistent, dismissible banner offers *"Review N changed paragraphs."*

The resolution surface (mockup [`mac-08-conflicts.html`](mockups/mac-08-conflicts.html), and the same content in a sheet on iPhone/iPad) shows, per conflicting paragraph:

- the paragraph number and chapter,
- **both texts**, with the differing runs marked,
- which device wrote each and when ("This Mac, 14:02" / "iPhone, 13:58"),
- whether either side has a **selected take** — because choosing the text that does not match the recorded take raises drift (`TextDriftDetector`, existing), and the sheet MUST say so before the choice, not after,
- actions: **Keep this one** (per side) · **Keep both** — retains the winner as the paragraph text and files the loser as a direction note, so nothing is thrown away · **Keep all from this device** as a bulk action at the top.

Rules:

- Resolution is itself a normal local mutation: it bumps `revision`, sets `synced_text_hash` to the resolved hash, and syncs like anything else.
- An **unresolved** conflict is a validation issue, not a hard block: `paragraphTextConflict` (§12), severity **blocking-for-export**, with a `FixAction` opening the resolution surface. A user may keep recording and reviewing with conflicts outstanding; they may not ship a package built from text nobody chose.
- Conflicts MUST survive relaunch. The conflict set persists in the project database (`paragraph_conflict` table, same migration).
- **MUST NOT** auto-resolve by recency. The whole point of the table in §4.3.2 is that everything auto-resolvable already does; what reaches this surface is exactly what needs a human.

#### 4.3.4 What changes in `Sync/`

The revised spec kept the conflict branch but degraded it (§4.2). It is now un-degraded:

- `SyncError.serverRecordChanged(recordName, changeTag, revision)` **already carries what the merge needs** and does not change.
- `ProductionSyncEngine`'s adopt-server-tag-and-retry-once path becomes **fetch-merge-push**: on conflict, fetch the server record, run `ProductionMerger` (🆕, `Core/Production/Merge/`), push the merged result, retry once. A second conflict on the retry means a third writer is racing; back off and re-run on the next sync tick.
- `ProjectionPublisher` publishes **from whichever device changed**, unchanged in shape. The projection remains the watch's food supply and the reinstall path.
- **No new CloudKit record types** (R2-3). The three merge columns become three **fields** on the existing `VGProductionProject` / `VGProductionChapter` / `VGProductionParagraph` records. Adding fields to a CloudKit record type is safe and backward-compatible; renaming a type is not.
- The revised spec's test asserting *no conflict UI is reachable* is **inverted**, not deleted: `ConflictReachabilityTests` now asserts the surface *is* reachable from a two-device divergence fixture, and that no other divergence reaches it.

**Tests (MUST):** `ProductionMergerTests` — one case per row of §4.3.2, plus: concurrent takes on one paragraph both survive; delete-vs-edit on a chapter keeps the chapter; three-way fast-forward in both directions; a true text conflict is detected; resolution is idempotent; a merge of a project with itself is a no-op (the property that catches most merge bugs).

### 4.4 Presence — advisory, never blocking

A soft signal, because two people are not the target but one person with three devices is: the projection carries `activeDevice`, `activeChapterID`, and a timestamp. Another device shows *"Recording chapter 3 on iPhone · 2 min ago"* on the project row.

**MUST NOT** block, lock, or warn on the basis of presence. It expires after 10 minutes without a heartbeat. It is a courtesy, and the merge model is what actually makes concurrency safe.

The Mac's existing `PackageLock` (resurrected, §5.3) is a **different and still necessary** mechanism: it is an advisory lock against *the same package being open twice on the same machine*, where two processes share a filesystem and SQLite. Keep both; do not conflate them.

### 4.5 Where projects live

| Platform | Location | Browsable? |
|---|---|---|
| iPhone / iPad | `Application Support/ProductionProjects/<projectID>/` — a `.voxproject` package | No. Portability is through Files ("Save a copy"). |
| **macOS** | **Wherever the user put it.** Finder-first: `~/Documents`, an external drive, iCloud Drive. Reached by `⌘O`, the project library, double-click in Finder, or drag-and-drop. | **Yes.** This is a Mac. |

A project **participates in iCloud sync when it is registered**, keyed by its project UUID, regardless of where its package sits. The Mac registers a project on first open; the phone registers on creation. So the same book opened from a Mac's Documents folder and created on a phone converge on one project id — and a package copied to two Macs and opened in both is simply two writers, handled by §4.3.

`ProductionProjectLayout` remains the single source of path rules **inside** a package (revised §4.4). The Mac adds only the question of where the package itself lives, which is the user's business.

**MUST NOT** invent a Mac-only project format, a document type beyond the existing `guru.parso.voxglass.project` UTI, or a second manifest (R2-2).

---

## 5. Implementation status inventory

**Read this before writing any file.** Legend: **✅ as-is** · **🔧 rework** (exists; the named change is required) · **🆕 new** · **⛔️ superseded** (exists in the resurrected tree; delete and use the Core replacement) · **☠️ dead** (exists; the model it served is gone).

### 5.1 Core — what the Mac needs that already exists

Since the Mac tree was deleted at `c0c6712`, Core gained **+3,823 lines** across `Voxglass/Core/Production/` over stages P1–P9 and the F1–F8 gap closure. Almost all of it is platform-free and the Mac gets it for free. **This is why the resurrected UI is stale in specific ways rather than uniformly stale: the views are fine, the seams under them moved.**

| Area | Status for the Mac | Note |
|---|---|---|
| `Domain/`, `Text/`, `Review/`, `Destinations/`, `Package/`, `Discovery/` | ✅ as-is | Compiles for macOS today. |
| `Store/` | ✅ as-is | `Take` gained `warning` and `route_class`; `ExportRunRecord` gained `fileDurations`. Both are **defaulted**, so resurrected call sites compile — and are therefore *silently wrong* (§5.3, row `RecordingModel`). |
| `Audio/` | ✅ as-is | Gained `CaptureRingBuffer` (C-atomics over `VoxglassRing`), `CaptureRouteClassifier`, `CaptureRouteInfo`, `CaptureWarning`, `CaptureRecovery`, `TakeComparison`, `AudioImportPlanner`, `WAVFormatReader`. **The Mac's job is to feed these, not to reimplement them.** |
| `Assembly/` | ✅ as-is | Gained `ChunkedRenderCoordinator` (M-4). The Mac uses it; the resurrected `AVChapterRenderer` becomes its executor, not its planner. |
| `Validation/` | 🔧 rework | Add `paragraphTextConflict` (§12) and its `FixAction`. |
| `Packaging/` | ✅ as-is | Gained `ResumableExportRunner`, `ExportPreflight`, `ExportPackageZipper`. The resurrected `ExportModel` predates all three (§5.3). |
| `CloudAssets/` | ✅ as-is | The whole area is post-deletion: repository, SQLite repository, uploader, hydration executor, eviction executor, power policy. **The Mac gets iCloud offload for free** and must not reimplement it. |
| `Sync/` | 🔧 rework | Un-degrade the conflict path to fetch-merge-push (§4.3.4). Add the three merge fields. `SyncTransport` gained `fetchRecords`; `SyncError` gained `LocalizedError`. |
| `WatchLink/` | ✅ as-is | Gained `RecordingRemote`. §14 decides whether the Mac relays. |
| `License/` | ✅ as-is | `NarrationProProduct` is the single source of the product id and display name. The Mac reads it. |
| **`Merge/`** | 🆕 new | `ProductionMerger`, `MergeConflict`, `ConflictSet`, `ResolutionPlan`, `DeviceIdentity` seam. §4.3. |
| **`Presence/`** | 🆕 new | `DevicePresence` value type + projection fields. §4.4. Small. |

### 5.2 iPhone + iPad (`Voxglass/Features/Production/`)

The iOS target already builds for iPad (`TARGETED_DEVICE_FAMILY: "1,2"`, all four orientations, `UIApplicationSupportsMultipleScenes: true`). **The iPad is not an availability gap; it is a layout gap.**

| Surface | Status | Change required |
|---|---|---|
| Every shipping narration surface | ✅ as-is in compact width | The iPhone flow is the compact-width presentation on iPad and needs no change. |
| **Size-class routing** | 🆕 new | `Adaptive/NarrationLayoutRouter` — compact → the existing `fullScreenCover` flow; regular → `NavigationSplitView` (§9.2). One decision point, not a per-screen fork. |
| **Regular-width split layout** | 🆕 new | Sidebar (projects / chapters) · content (paragraph list or script) · detail (recording workspace). §9.2. |
| **Hardware keyboard on iPad** | 🆕 new | The §8.2 shortcut map, minus the menu-bar-only entries. `.keyboardShortcut` + a `KeyboardShortcutMap` shared with the Mac so the two cannot drift (§8.3). |
| **Conflict resolution sheet** | 🆕 new | Same content as the Mac surface, presented as a sheet. §4.3.3. |
| Presence indicator on project rows | 🆕 new | Small. §4.4. |

### 5.3 macOS — disposition of the resurrected tree

The tree was restored **verbatim** from `c0c6712^` into `VoxglassMac/` (58 source files), `VoxglassMacTests/` (19), and `VoxglassMacUITests/` (1). The directories were renamed *only* so gate G-P6's on-disk check stays green; **no file content was altered**. It is inert: no `project.yml` target references it, `Package.swift` does not compile it, and `swift test` does not see it.

It was written against Core as of `c0c6712^` and is Swift 6 already (the old target set `SWIFT_VERSION: "6.0"`), which is why the disposition below is mostly "rework", not "rewrite".

**Global changes to every file in the tree (stage U0):**

- Rename the `Studio*` type and file names to `Mac*` / `Voxglass*` so gate G-P6 passes when it is extended to `VoxglassMac/` — eleven files carry `VoxglassStudio`, `Voxglass Studio`, or `voxglass.studio`.
- Purge `voxglass.studio.pro` (gate G-P7) in favour of `NarrationProProduct.productID`.
- Delete `Resources/VoxglassStudio.storekit`; the Mac scheme points at `Voxglass/Resources/VoxglassNarration.storekit`.
- `Resources/Info.plist`: bundle id → `guru.parso.voxglass` (§2.1), display name → `Voxglass`, keep the `guru.parso.voxglass.project` UTI and document type.
- Entitlements: **already correct and complete** — the restored `.entitlements` carries sandbox, `device.audio-input`, `files.user-selected.read-write`, `files.bookmarks.app-scope`, `network.client`, `icloud-services: CloudKit`, and container `iCloud.guru.parso.voxglass`. Rename the two files and verify against the iOS app's container; do not rewrite them.

| File / group | Disposition | What must change |
|---|---|---|
| `App/StudioApp.swift` | 🔧 rework → `VoxglassMacApp` | `WindowGroup` per project (§8.4), the full app's sidebar root (D-U3), scene restoration. |
| `App/StudioCommands.swift` | 🔧 **rework — expand substantially** | Today: 10 shortcuts. §8.2 specifies the full map. Replace the `NotificationCenter` fan-out with a typed `MacCommand` enum routed through the focused window's model — notifications cannot address the right window when several projects are open, which is the whole point of the Mac app. |
| `App/StudioEnvironment.swift` | 🔧 rework → `MacEnvironment` | Composition root. Rewire to the post-P9 seams: `ProductionAssetRepository`, `CloudAssetUploader`, `AssetHydrationExecutor`, `ProductionEvictionExecutor`, `ResumableExportRunner`, `ChunkedRenderCoordinator`, `CaptureRouteClassifier`, `ProductionMerger`. Carries `voxglass.studio` strings. |
| `App/StudioRootView.swift` | 🔧 rework → `MacRootView` | Becomes the full-app sidebar (Listen / My Books / Explore / Search / Narration) per D-U3, with narration as one source-list section. |
| `Features/Library/*` (`ProjectLibraryModel`, `ProjectLibraryView`) | 🔧 rework — **keep, this is the payload** | The multi-audiobook front door (§8.4). Rework: add iCloud-registered projects alongside `RecentsStore` bookmarks; add per-project status (recorded %, blocking issues, backup state); add presence (§4.4). The `PackageLock` stale-lock flow is correct as written. |
| `Services/RecentsStore.swift` | 🔧 rework — **keep** | Security-scoped bookmarks + cached manifest/summary so the sidebar renders without opening a database. Change: the Application Support directory name (`guru.parso.voxglass.studio` → `guru.parso.voxglass`) **with a one-time migration** — unlike the P0 entitlement keys, this file *was* written by real local builds. |
| `Services/PackageLock.swift` | ✅ as-is — **keep** | Same-machine advisory lock (§4.4). Verify it is not conflated with presence. |
| `Support/StudioUndo.swift` | 🔧 rework → `MacUndo` | `⌘Z`/`⌘⇧Z` over script edits and take selection. Rename only, plus coverage for the new commands. |
| `Features/Record/RecordingModel.swift` | 🔧 **rework — highest risk** | Constructs `Take(...)`. `warning:` and `routeClass:` now exist with defaults, so **it compiles and is silently wrong**: Mac takes would record `.none` and `nil`, defeating §7.1 and §7.4 on the Mac. Must feed `CaptureRouteClassifier` and `CaptureRecovery`. Also predates `CaptureWarning` and the interruption matrix as Core types. |
| `Services/AVAudioEngineCapture.swift` (756 lines) | 🔧 **rework — keep the AV work** | The real macOS capture concrete, and the most valuable single file in the tree. Rework: conform to today's `AudioCapturing` (which gained `currentRouteInfo` and `onInterruption`), and push samples through **Core's** `CaptureRingBuffer`, not its own. |
| `Services/CaptureRingBuffer.swift` (219 lines) | ⛔️ **superseded — delete** | Core's 57-line C-atomics ring over the `VoxglassRing` target replaces it (U-7). `VoxglassMacTests/CaptureRingBufferTests.swift` goes with it; Core's tests already cover it. |
| `Services/AVSegmentPlayer.swift`, `AVChapterRenderer.swift`, `AVAudioDecoder.swift`, `AVMetricsCalculator.swift`, `ArtworkResizer.swift` | 🔧 rework | Sound AVFoundation concretes. Renderer must run **under** `ChunkedRenderCoordinator` (M-4) rather than planning whole-book runs itself. Check each against the iOS concretes that shipped in P4–P7 and **share whatever is genuinely identical** by moving it to Core — do not maintain two copies of the same AVFoundation code. |
| `Services/StoreKitLicenseProvider.swift` | ⛔️ **likely superseded — compare, then delete one** | An iOS StoreKit 2 concrete now ships at `Voxglass/Features/Production/StoreKitLicenseProvider.swift` alongside `NarrationProStore.swift` and `ProPurchaseView.swift` (stage P8). The resurrected Mac copy predates it and carries `voxglass.studio.pro` (gate G-P7). **Default: delete the Mac copy and share the iOS one**, since Universal Purchase needs no platform-specific entitlement logic (§13). Keep the Mac copy only if it does something the iOS one cannot, and say what. |
| `Services/DiagnosticsBundle.swift` | 🔧 rework | Useful; carries studio strings; must not collect anything new the privacy note (§18) does not cover. |
| `Sync/StudioProjectionCoordinator.swift`, `Sync/StudioEventSink.swift`, `Sync/ProxyGenerator.swift` | ☠️ **dead — delete** | All three implement **Mac-as-sole-writer publishing to read-only consumers** (Studio Spec §13), a model this spec does not restore in either direction. Proxy generation now lives in the phone-side relay and Core. Their replacement is `ProductionSyncEngine` + `ProductionMerger` used symmetrically. `VoxglassMacTests/StudioEventSinkTests.swift` goes with them. |
| `Features/Export/ExportModel.swift`, `ExportWizardView.swift` | 🔧 **rework — substantially** | Predates `ResumableExportRunner`, `ExportPreflight`, `ExportPackageZipper`, export **scopes** (F-series), and hydration preflight. Keep the wizard's shape and its Pro gate placement (§2.3); replace its engine. |
| `Features/Validate/*`, `Features/Metadata/*`, `Features/Assemble/*`, `Features/Review/*`, `Features/Script/*`, `Features/TakeCompare/*`, `Features/ImportAudio/*`, `Features/SourceImport/*`, `Features/NewProject/*`, `Features/Dashboard/*` | 🔧 rework | Screen shapes are good and map onto the mockups. Each needs: today's Core seams, the new issue code where relevant, and identifier alignment with `mockups/`. `Assemble` gains the `AssemblySettings` toggles added post-deletion (`trimSilenceAtEdges`, `normalizeLoudness`). |
| `Features/Discovery/*` (`StudioDiscoveryModel`, `StudioURLSessionFetcher`, `DiscoveryViews`) | 🔧 rework | The needs ladder is unchanged (N-4) and Core-side. Rename; check the fetcher against the CI network allow-list. |
| `Features/DevicePreview/*` | 🔧 rework or ⛔️ | Previewed how a project looked on phone/watch, under the Mac-as-writer model. Under peer writers the "preview" is just the other device. **Recommend delete**; if kept, it must not become a second read-only projection surface. |
| `Features/Settings/*` | 🔧 rework | Carries `voxglass.studio.pro`. One of the three permitted `LicenseGate` sites on the Mac (§2.3). Add the production cache limit row (revised §6.5) and the merge/presence rows. |
| `Support/UITestFakes.swift` | 🔧 rework | Fakes for the Mac smoke test (§16.3). Align with `VoxglassCoreTestSupport` fakes rather than duplicating them. |
| `Support/RenderCounter.swift` | 🔧 rework | The performance budget P0 deleted (`PerformanceBudgetTests` measured `RecordingWorkspaceView` render counts). Restore the budget **with the test**, or delete both — do not restore a counter nothing asserts on. |
| `VoxglassMacTests/*` (20 files) | 🔧 rework | Real coverage of the resurrected models. Each must be re-pointed at today's Core. `CaptureRingBufferTests` and `StudioEventSinkTests` are deleted with their subjects. **These tests are the cheapest possible check on whether an adaptation was correct — re-point them before writing new ones.** |
| `VoxglassMacUITests/StudioSmokeUITests.swift` | 🔧 rework | Becomes the Mac smoke test of §16.3. |

### 5.4 The working tree right now

`VoxglassMac/`, `VoxglassMacTests/`, and `VoxglassMacUITests/` are **restored and staged but not adapted**. They compile against nothing because no target references them.

**Provenance.** Git records these as plain additions, not renames — `HEAD` had no `VoxglassStudio` files to rename *from*, and the delete at `c0c6712` is too far back for rename detection to bridge. **`git log --follow` will not reach the pre-deletion history.** To read a file's real history, address it at its old path:

```
git log c0c6712^ -- VoxglassStudio/<path>      # history
git show c0c6712^:VoxglassStudio/<path>        # the original bytes
```

The U0 commit body MUST cite `c0c6712^` as the source, because the commit itself is the only place that provenance will be recorded.

Nothing else in the working tree has been touched by this document. No `project.yml` target, no guard script, no Swift file outside the resurrected tree.

---

## 6. iCloud, storage, and offload

**Inherited from revised §6** in full: asset states, the offload rule (`isEvictable`, SHA-256 verified *and* `remote_asset_id` persisted before any eviction), the `production_asset` table, upload/verify/hydrate, the working set, eviction ordering. All of it is Core and all of it works on macOS today.

Three deltas:

1. **Cache limits are per-device, never synced** (§4.3.2). A Mac with a 4 TB drive and a 128 GB iPhone must not share a number. Default on macOS: **50 GB**, range 2–2000 GB, with the same first-run clamp to ~15% of free space (D-5, applied per device).
2. **The Mac may be the backup that saves the phone.** With peer writers, a project created on the phone and hydrated on the Mac has two verified local copies. This is a consequence, not a feature — do not build a "backup to Mac" surface, and do not weaken the iCloud verification rule because a second local copy exists.
3. **Export staging is device-local** and never merges (§4.3.2).

Mockup: [`mac-09-storage.html`](mockups/mac-09-storage.html).

---

## 7. Audio capture on macOS

### 7.1 Route classification

**Inherited from revised §7.1**: `CaptureRouteClassifier` produces `retailReady` / `communityReady` / `draftOnly`, the class is stored per take (`Take.routeClass`), and `routeNotRetailReady` is computed from history. This is Core and unchanged.

What is Mac-specific is the *input*: macOS reports devices through `AVCaptureDevice` / Core Audio rather than `AVAudioSession`, and the resurrected `AVAudioEngineCapture` already enumerates them (`availableInputDevices()`). The Mac MUST populate `CaptureRouteInfo` from that enumeration and hand it to the same Core classifier. **MUST NOT** write a second classifier with Mac-specific thresholds.

One honest platform difference to reflect in copy: a Mac is more likely to have an interface and less likely to be on Bluetooth, so `retailReady` will be the common case rather than the exception. Bluetooth remains **not blocked** (§1.5.6 honesty principle).

### 7.2 Capture graph

```
AVAudioEngine inputNode -> tap -> Core CaptureRingBuffer -> writer task -> Autosave/takes/<uuid>.wav
                               -> meter accumulator      -> AsyncStream<CaptureLevels>
```

Identical in shape to iOS (revised §7.2) and subject to the same real-time discipline in the tap body: **no allocation, no lock, no `Task`, no `os_log`, no `Date()`**. The Mac uses **Core's** ring buffer (U-7).

macOS additions: input device selection is explicit and persisted per project; sample-rate mismatch between the device and the engine is surfaced rather than silently resampled; **direct/hardware monitoring is preferred**, and software monitoring warns about latency exactly as on iOS.

### 7.3 Interruption matrix

Revised §7.4's iOS matrix has a macOS analogue, and the resurrected `CaptureInterruptionTests` already covers part of it against the `AudioCapturing` fake:

| Event | Required behavior |
|---|---|
| Interface unplugged / device disappears mid-take | stop, finalize, `CaptureWarning.interrupted`, recoverable take |
| Default input device changed by the system | same |
| Sample-rate change on the device | same |
| Sleep / lid close during a take | same |
| Force-quit or power loss during a take | `WAVHeaderRepair` recovery on next launch |
| Disk pressure | stop, finalize, surface the storage issue |
| **App backgrounded** | **not an interruption on macOS** — recording continues. Do not port the iOS rule. |

Write ordering (revised §9.4) is unchanged and MUST-ordered: autosave → finalize → hash → content-addressed store → metadata → upload → metrics.

Mockup: [`mac-04-recording.html`](mockups/mac-04-recording.html).

---

## 8. The macOS narration control model

This section is the reason the Mac app exists (§1.3). It is normative, not aspirational.

### 8.1 Principles

1. **Every action in the record loop has a key.** Record, stop, accept, retake, flag, advance, play, compare, select take. No exceptions — an action reachable only by mouse is a bug in this section.
2. **The eyes stay on the text.** Shortcuts MUST NOT require a visible control to acquire focus first, and MUST NOT move focus as a side effect.
3. **A footswitch is a keyboard.** USB footswitches present as HID keyboards emitting ordinary keystrokes. The map below is therefore also the pedal map, and the three actions a pedal typically sends (`Space`, `⌘R`, `⌘⏎`) are the three most important actions in the loop. No footswitch-specific code is needed or permitted.
4. **Key repeat MUST NOT retrigger transport.** Holding `Space` starts one take, not many. `NSEvent.isARepeat` is checked in the Mac key path; the equivalent guard applies on iPad.
5. **Text fields win.** While a text field is first responder, unmodified keys (`Space`, letters) type; only modified shortcuts fire. `Esc` returns focus to the teleprompter.
6. **Shortcuts address the focused window**, not the app. With four books open, `⌘R` records in the front one (§8.4).

### 8.2 The keyboard map (MUST)

Menu-bar-visible entries appear in the menu that owns them, so the map is discoverable without documentation.

**Transport — the record loop**

| Key | Action | Menu |
|---|---|---|
| `Space` | Record / Stop (teleprompter focused; not while editing text) | Record |
| `⌘R` | Record / Stop (works from anywhere in the window) | Record |
| `⌘⇧A` | Arm / disarm | Record |
| `⌘⏎` | Accept take **and advance** to the next paragraph | Record |
| `⌘⇧⏎` | Accept take and **stay** | Record |
| `⌘\` | Retake — archive the current take, start a new one | Record |
| `⌥Space` | Punch in: retake from the current paragraph without leaving record state | Record |
| `⌘'` | Flag paragraph for review | Review |
| `⌘K` | Mark **needs pickup** | Review |
| `⌘;` | Add a direction note to the current paragraph | Review |
| `⌘.` | Cancel the running operation (render, export, hydration) | — |

**Movement**

| Key | Action |
|---|---|
| `⌘→` / `⌘←` | Next / previous paragraph *(inherited from the deleted `StudioCommands`)* |
| `⌘↓` / `⌘↑` | Next / previous chapter |
| `⌘⌥→` | **Record next** — jump to the first paragraph with no selected take, else the first `needsPickup` (revised §15.5) |
| `⌘F` / `⌘G` / `⌘⇧G` | Find in script / next / previous |
| `⌘J` | Jump to paragraph number |

**Listening and takes**

| Key | Action |
|---|---|
| `⌘P` | Play / pause the selected take |
| `⌥⌘P` | Play **in context** — previous tail, this paragraph, next head |
| `⌘L` | Loop the current paragraph |
| `⌘1`…`⌘9` | Select take 1…9 for the current paragraph |
| `⌥⌘[` / `⌥⌘]` | A/B: previous / next take at matched loudness (§9.5 of the revised spec) |

**Project and windows**

| Key | Action | Menu |
|---|---|---|
| `⌘N` | New audiobook project *(inherited)* | File |
| `⌘O` | Open project… *(inherited)* | File |
| `⌘⇧O` | Show the **project library** | File |
| `⌘⇧I` | Import source… *(inherited)* | File |
| `⌘⌥I` | Import existing audio… | File |
| `⌘S` | Flush pending edits | File |
| `⌘⇧S` | Save a copy… | File |
| `⌘W` / `⌘⌥W` | Close window / close all | File |
| `⌘Z` / `⌘⇧Z` | Undo / redo | Edit |
| `⌘⇧R` | Start review queue *(inherited)* | Project |
| `⌘⇧V` | Validate | Project |
| `⌘E` | Export… *(inherited)* | Project |
| `⌘⇧E` | **Batch export** across selected projects (Pro) | Project |
| `⌘⇧C` | Review conflicts (§4.3.3) | Project |
| `⌘,` | Settings | Voxglass |
| `` ⌘` `` | Cycle open project windows | Window |

**Reserved to the system and MUST NOT be rebound:** `⌘Q`, `⌘H`, `⌘M`, `⌘Tab`, `⌘Space`, `⌃⌘F`.

**Test (MUST):** `MacKeyboardMapTests` — the map is a **single declarative table** in `VoxglassMac/App/KeyboardShortcutMap.swift`, and the test asserts (a) no duplicate `(key, modifiers)` pair, (b) no collision with the reserved set, (c) every action in §9.2 of the revised spec ("Record / Stop · Accept & Next · Retake · Flag · Play take · Play in context · Previous / Next paragraph · Select take") has a binding. A table, not scattered `.keyboardShortcut` modifiers, is what makes this testable — and it is what §8.3 shares with iPad.

Mockup: [`mac-05-shortcuts.html`](mockups/mac-05-shortcuts.html).

### 8.3 Sharing the map with iPad

`KeyboardShortcutMap` is a **plain value table** with no AppKit or SwiftUI types in it, so it lives in Core (`Core/Production/Domain/`) and both apps read it. Each entry declares whether it is `menuOnly` (iPad has no menu bar) or available on both. The iPad applies the non-`menuOnly` entries through `.keyboardShortcut`; the Mac applies all of them through `Commands`.

This is the mechanism that keeps a user's muscle memory intact between an iPad in a case and a Mac at a desk, and it is why the map is a table rather than a set of modifiers scattered across views.

### 8.4 Multiple audiobooks — windows and the library

**One window per project.** `WindowGroup(for: ProjectReference.self)`. Native macOS window tabbing is enabled, so a user may keep four books as four tabs of one window or four separate windows — their choice, not the app's. The `Window` menu lists open projects by title.

**The project library** (`⌘⇧O`, mockup [`mac-01-library.html`](mockups/mac-01-library.html)) is the Mac's front door — deliberately different from the phone's need-first shelf (R-6), because the phone's problem is *"what should I read?"* and the Mac's problem is *"where was I on each of these four?"*. Each row shows:

- title, author, destination lane,
- progress (paragraphs recorded / total) and per-chapter breakdown on expand,
- blocking validation issues, unresolved conflicts (§4.3.3),
- backup state — `localOnly` count, verified count, `remoteOnly` count (§6),
- presence — *"Recording chapter 3 on iPhone · 2 min ago"* (§4.4),
- where the package lives, with a Finder reveal.

Sources merged into one list: `RecentsStore` security-scoped bookmarks (resurrected) **and** iCloud-registered projects not present locally, which offer *"Download"* rather than *"Open"*.

**MUST NOT** make the library modal, make it the only way to open a project (Finder double-click and drag-and-drop both work), or let it become a second project model (R2-1).

### 8.5 The cross-project review queue

The one review surface that cannot exist on a phone: *"everything flagged, across every project."* One queue, sorted by project then chapter then ordinal, with the project name on each row. Approving or flagging writes a `ReviewEvent` into that project's store — the existing fold, addressed across stores.

Free (§2.2). Mockup: [`mac-06-review-queue.html`](mockups/mac-06-review-queue.html).

### 8.6 Batch export (Pro — `batchExport`)

Select N projects in the library, choose one destination, run once. Sequential, not parallel — encoding is CPU-bound and a parallel run would make the progress UI lie. Per-project rows show queued / running / done / failed, and a failure does not abort the batch.

Preflight is the union of each project's preflight (revised §13.2): total hydration bytes, total free-space requirement, and every blocking validation issue across all selected projects, shown **before** the run starts and before the Pro gate.

The batch runner **MUST NOT** consult `LicenseGate` itself; it routes each project's destination decision through `ExportModel`, which is already a permitted gate site (§2.3). A free lane must not become gated by being run in a batch.

Mockup: [`mac-07-batch-export.html`](mockups/mac-07-batch-export.html).

---

## 9. iPad

Per the user's direction, this MVP specifies iPad and **ships mockups for it**; the implementation is stage U8.

### 9.1 Capability

**iPad narrates in full.** Everything the iPhone can do, the iPad can do — no reduced mode, no "review only", no handoff prompt. The iOS target already builds and runs on iPad; §9.2 is about layout and input, not availability.

### 9.2 Layout by size class

| Size class | Presentation |
|---|---|
| **Compact** (portrait on smaller iPads, Slide Over, narrow Stage Manager) | **The shipping iPhone flow, unchanged** — `NarrationFlowRoot` as a `fullScreenCover`, the five-tab dock. Zero new code; this is the fallback that makes the whole feature safe. |
| **Regular** (landscape, full-screen, wide Stage Manager) | `NavigationSplitView`: **sidebar** — the five sections plus, within Narration, the project and chapter list · **content** — paragraph list or script editor · **detail** — recording workspace, review player, or validation report. |

One routing decision in `Adaptive/NarrationLayoutRouter`, not a per-screen fork. A size-class change mid-session MUST preserve the current paragraph, take selection, and any in-flight recording — **an in-flight take is never interrupted by a rotation or a Stage Manager resize.**

### 9.3 Input

- **Hardware keyboard**: the shared map (§8.3), minus `menuOnly` entries. Holding `⌘` shows the iPadOS shortcut HUD, so the map is discoverable there too.
- **Trackpad/mouse**: pointer effects on paragraph rows and transport controls; right-click context menus mirror the phone's long-press menus.
- **Apple Pencil / Scribble** (MAY): handwritten direction notes in the note field. Genuinely nice, genuinely optional; do not stub toward it if it is not built.
- **Multiple scenes** (MAY): `UIApplicationSupportsMultipleScenes` is already true. Two projects side by side on iPad is a natural extension of §8.4 and is **not required** by this MVP.

### 9.4 What the iPad does *not* get

The menu bar, `PackageLock` (no Finder-located packages), the project library window (the Narration tab's My Narrations is the iPad's library), and batch export — all Mac-shaped. This is not a tier distinction; it is a platform-shape distinction, and none of it is behind Pro.

Mockups: [`ipad-01-split-narration.html`](mockups/ipad-01-split-narration.html), [`ipad-02-recording.html`](mockups/ipad-02-recording.html), [`ipad-03-review.html`](mockups/ipad-03-review.html).

---

## 10. Text, scripts, recording, assembly, import

**Inherited unchanged** from revised §8–§11 in substance. Everything in `Core/Production/Text/`, `Audio/`, and `Assembly/` is platform-free and already used by iOS.

Mac-shaped deltas, all UI:

- **Script editor** — the Mac affords the dense multi-pane editor the phone deliberately refused (revised §8.4: *"a phone-shaped editor, not a dense multi-pane one"*). Chapter outline · paragraph list with state chips · inspector, all visible at once. Same Core operations: split, merge, drift, direction notes.
- **Source import** — drag-and-drop onto the window, plus Finder open. Progressive parse (revised §8.2) still applies; a Mac is faster, not infinitely fast, and a 400-page EPUB must still show a preview before the parse completes.
- **Import existing audio** — drag a folder of WAVs onto a chapter. Origin declaration remains **mandatory** and compliance-relevant (revised §10, Studio Spec C-6); a non-human or unknown origin on a selected take still blocks LibriVox export.
- **Assembly** — the same `ChunkedRenderCoordinator`, chunked by chapter and cancellable (`⌘.`), plus the `AssemblySettings` toggles that landed after the Mac tree was deleted.

Mockups: [`mac-02-script.html`](mockups/mac-02-script.html), [`mac-03-import.html`](mockups/mac-03-import.html).

---

## 11. Validation

**Inherited from revised §12.** Validation is ungated on every platform, runs locally, and is identical across devices (§3).

**One new issue code (🆕, add to `IssueCode`):**

| Code | Severity | Meaning | `FixAction` |
|---|---|---|---|
| `paragraphTextConflict` | **blocking-for-export**, not a quality failure | One or more paragraphs have unresolved two-device text conflicts (§4.3.3). Carries the conflict count. | Open conflict resolution |

The four codes added by the revised spec (`assetRemoteOnlyForExport`, `localStorageInsufficient`, `backupNotVerified`, `routeNotRetailReady`) are unchanged and apply on macOS as written.

---

## 12. Packaging and export

**Inherited from revised §13** — pipeline, scopes, hydration and storage preflight, resumable runs, output. All Core, all platform-free, all shipping.

macOS deltas:

- **Output destination is a real folder.** No zip-by-default: `NSSavePanel` writes the package directory where the user asks. Zip remains available for upload convenience. (Revised §13.4's zip preference was an iOS document-picker workaround and MUST NOT be inflicted on a Mac.)
- **Reveal in Finder** after a successful export, and **Copy `ia upload` command** on the Internet Archive lane.
- **Batch export** (§8.6).
- Resumable runs (`ResumableExportRunner`) work as on iOS; a Mac export additionally survives sleep.

Free destinations MUST NOT touch `LicenseGate` at any step (gate G-P2), including in the batch runner.

Mockups: [`mac-07-batch-export.html`](mockups/mac-07-batch-export.html), [`mac-10-export.html`](mockups/mac-10-export.html).

---

## 13. Pro purchase on macOS

Two StoreKit concretes now exist: the shipping iOS one from P8 (`Voxglass/Features/Production/StoreKitLicenseProvider.swift`, with `NarrationProStore` and `ProPurchaseView`) and the older resurrected Mac one. **Keep one** — by default the iOS one, promoted to a shared app-layer file — behind the existing `LicenseProvider` seam. Core stays StoreKit-free. Universal Purchase requires no platform-conditional entitlement code, so a second concrete would be two copies of the same logic.

- Non-consumable, one-time, **shared by Universal Purchase** (§2.1). No Mac-specific product, no upgrade path, no cross-grade.
- **Restore Purchases always visible** on macOS as on iOS.
- Entry points: the export destination picker and Settings. **Nowhere else** (§2.3).
- Refund or revocation returns the app to free **while preserving every project and file**.
- A user who bought on iPhone opens the Mac app and is already Pro, with **no restore step**. If a restore is ever required, that is a bug in the entitlement read, not a UX to design around.

---

## 14. Watch companion

**Unchanged.** The watch remains a companion to the **iPhone** over `WatchConnectivity`: summaries and proxies out, `ReviewEvent`s and recording-remote commands back (revised §14).

**Decision D-U4: the Mac does not talk to the watch.** A Mac has no `WatchConnectivity` peer relationship, and routing watch traffic through iCloud to reach a Mac would add a second transport for a case — recording on a Mac while reviewing on a watch — that is better served by the Mac's own keyboard. Watch review of a Mac-recorded project still works, because the *project* syncs through iCloud to the phone, which relays as it always has.

The watch's `RecordingRemote` remains phone-only. **Do not stub toward a Mac relay** (§0.3, DEFERRED).

---

## 15. UI specification

### 15.1 Visual language

**Inherited verbatim from revised §15.2** and binding on macOS and iPad: background `#0A0B0D`, ink `#F2F4F6`, brass `#E3A44B` / deep `#B97F2E`, ok `#4CD471`, danger `#FF6B5E`, hairline white-10%, glass panel = material blur + `#1E2026` at 35% + 1 px white-16% border, radius 26.

**Both renderings remain mandatory.** `AdaptiveGlass` branches on reduce-transparency on every platform; every new mockup page carries the **Glass / Solid** toggle and must be legible in both. Colors come from `Voxglass/DesignSystem`; **no new color literals** (gate G-P4, extended to `VoxglassMac/`).

macOS-specific rendering notes, none of which change a token:

- Window chrome is standard macOS; the app does not draw its own title bar.
- The sidebar uses the system source-list appearance over the app's background, not a custom translucent panel.
- Hover states exist on macOS and iPadOS-with-pointer and do not exist on touch. A control that is only discoverable on hover fails §15.3 rule 2 of the revised spec.
- Focus rings MUST be visible for full-keyboard-access users. This follows directly from §8.1 and is not optional.

### 15.2 macOS screen inventory

| # | Screen | Mockup | Entry | Owning file |
|---|---|---|---|---|
| mac-01 | Project library | [`mac-01-library.html`](mockups/mac-01-library.html) | `⌘⇧O`, launch | `Features/Library/ProjectLibraryView.swift` 🔧 |
| mac-02 | Script editor | [`mac-02-script.html`](mockups/mac-02-script.html) | window sidebar | `Features/Script/ScriptEditorView.swift` 🔧 |
| mac-03 | Source import | [`mac-03-import.html`](mockups/mac-03-import.html) | `⌘⇧I`, drag-and-drop | `Features/SourceImport/SourceImportView.swift` 🔧 |
| mac-04 | Recording workspace | [`mac-04-recording.html`](mockups/mac-04-recording.html) | `⌘R`, sidebar | `Features/Record/RecordingWorkspaceView.swift` 🔧 |
| mac-05 | Keyboard shortcuts | [`mac-05-shortcuts.html`](mockups/mac-05-shortcuts.html) | Help menu | 🆕 `App/KeyboardShortcutMap.swift` + a reference sheet |
| mac-06 | Cross-project review queue | [`mac-06-review-queue.html`](mockups/mac-06-review-queue.html) | `⌘⇧R` | 🆕 |
| mac-07 | Batch export | [`mac-07-batch-export.html`](mockups/mac-07-batch-export.html) | `⌘⇧E` from the library | 🆕 |
| mac-08 | Conflict resolution | [`mac-08-conflicts.html`](mockups/mac-08-conflicts.html) | `⌘⇧C`, banner | 🆕 |
| mac-09 | Storage & iCloud | [`mac-09-storage.html`](mockups/mac-09-storage.html) | Settings | `Features/Settings/` 🔧 |
| mac-10 | Export wizard | [`mac-10-export.html`](mockups/mac-10-export.html) | `⌘E` | `Features/Export/ExportWizardView.swift` 🔧 |

### 15.3 iPad screen inventory

| # | Screen | Mockup | Note |
|---|---|---|---|
| ipad-01 | Split-view narration | [`ipad-01-split-narration.html`](mockups/ipad-01-split-narration.html) | Regular width: sidebar / paragraphs / detail |
| ipad-02 | Recording workspace | [`ipad-02-recording.html`](mockups/ipad-02-recording.html) | Script and teleprompter side by side; keyboard HUD |
| ipad-03 | Review | [`ipad-03-review.html`](mockups/ipad-03-review.html) | Queue and player in one view |

Compact-width iPad reuses the iPhone mockups unchanged (§9.2) — there are deliberately no compact iPad pages.

### 15.4 Identifiers

**Inherited rule (revised §15.3 rule 2, and the contract `AccessibilityAuditTests` enforces):** HTML `id` attributes in the mockups are the `.accessibilityIdentifier` values the implementation must use.

`AccessibilityAuditTests` currently parses **only** `docs/iphone-watch-only-revised-mvp/mockups`. Stage **U0** extends it to this directory as well, with the Mac and iPad ids resolved against `VoxglassMac/` and `Voxglass/Features/Production/` respectively. Until that extension lands, the new mockups are **not** yet a test-enforced contract — which is exactly why extending the test is a U0 task and not an afterthought.

Identifiers already shipping on iOS — `record.*`, `player.*`, `paragraphList.*`, `queueBuilder.*`, `note.*`, `import.*`, `export.*`, `review.*`, `script.*`, `newProject.*`, `settings.*`, `validation.*` — are **reused** on Mac and iPad wherever the control means the same thing. New prefixes introduced by this MVP: `library.*`, `batch.*`, `conflict.*`, `shortcut.*`, `sidebar.*`, `queue.*`, `presence.*`, `window.*`.

**No identifier may name a device** (MUST). The same control carries the same id on every platform — `record.recordNext` is `record.recordNext` on Mac and iPad alike. A platform-prefixed id makes one shared control look like two to `AccessibilityAuditTests` and to VoiceOver review, and it rots the moment the control moves.

### 15.5 What is removed from the UI

- Any screen labelled "Voxglass Studio" — the Mac app is **Voxglass** (§2.1, D-1).
- The phrases `Record on Mac`, `Continue on Mac`, `Requires a Mac` (gate G-U1). The Mac is an option, never a prerequisite.
- Any production CarPlay entry point (M-5, unchanged).
- The `DevicePreview` surface, unless §5.3's recommendation is overridden with a reason.

---

## 16. Testing and acceptance

### 16.1 Core suites (`swift test` — this is what CI runs)

Everything in revised §16.1, plus:

**merge rules (one suite per row of §4.3.2)** · **conflict detection and resolution idempotency** · **self-merge is a no-op** · **keyboard map uniqueness and coverage** · **device identity stability across relaunch** · **presence expiry**.

### 16.2 New test files

`ProductionMergerTests` · `ConflictResolutionTests` · `ConflictReachabilityTests` *(inverted from the revised spec's version)* · `MacKeyboardMapTests` · `DeviceIdentityTests` · `PresenceExpiryTests` · `CrossProjectQueueTests` · `BatchExportTests` · `MacCaptureRouteTests`.

Core suites go in `VoxglassTests/Production/`; Mac-target suites go in `VoxglassMacTests/`.

### 16.3 UI smoke tests and CI

**Three** local pre-commit smoke tests (U-8): iPhone, Watch, **Mac**.

The Mac smoke test: open the project library → create a project from a need → import a short source → record two paragraphs with the fake capture → **drive the whole loop from the keyboard only** (`⌘R`, `⌘⏎`, `⌘→`) → validate → LibriVox export → verify the produced package bytes. The keyboard-only leg is the point; a Mac smoke test that clicks buttons tests nothing this MVP added.

**CI**: unchanged in principle — `macos-latest` (`compile`, `logic-tests`, `testflight`) plus `ubuntu-latest` (`guarded-tests`); **no CI job boots a simulator**. U0 restores a **compile-only macOS job** (the `build-mac` job P0 deleted), which needs no simulator and no signing and catches the most common breakage cheaply.

Watch UI test gotchas remain binding (revised §16.3). Mac additions learned from the deleted `StudioSmokeUITests`: the app must be terminated between runs or `PackageLock` will report the project already open; seeders must be idempotent; `NSOpenPanel` cannot be driven from a UI test, so the seeded fixture path must be injectable.

### 16.4 CI grep gates

The amended and new gates are in **§0.6**. Every gate change lands in stage U0 with a matching failable probe in `scripts/test_guards.sh`. **A gate without a probe is not a gate.**

### 16.5 Manual matrix — macOS and iPad additions

M-1…M-14 of revised §16.5 remain and are re-run per platform where they are platform-sensitive. Added:

| # | Scenario | Pass condition |
|---|---|---|
| **U-M1** | Record a 60-paragraph chapter on macOS **using only the keyboard and a USB footswitch** | no take lost; no action required the mouse; no key-repeat double-trigger |
| **U-M2** | Unplug the audio interface mid-take on macOS | take preserved, route error shown, recovery works |
| **U-M3** | Sleep the Mac during a take | take preserved and recoverable |
| **U-M4** | Four projects open in four windows | `⌘R` records in the front window only; the `Window` menu lists all four |
| **U-M5** | Edit the same paragraph's text on Mac and iPhone while both are offline, then reconnect | exactly one conflict is raised; both texts are shown; neither take is lost |
| **U-M6** | Record the same paragraph on Mac and iPhone offline, then reconnect | **two takes survive**; no conflict is raised |
| **U-M7** | Buy Pro on iPhone, then launch the Mac app | Pro is active with no restore step |
| **U-M8** | Batch-export three projects; fail one deliberately | the other two complete; the failure is reported per project |
| **U-M9** | iPad: rotate and resize through Stage Manager during a take | recording is never interrupted; position and take selection survive |
| **U-M10** | iPad with a hardware keyboard | every non-`menuOnly` shortcut fires; the `⌘` HUD lists them |
| **U-M11** | macOS full keyboard access + VoiceOver | every narration surface is reachable; focus rings visible |
| **U-M12** | Reduce Transparency on macOS and iPadOS | every screen renders the solid fallback (§15.1) |

### 16.6 Release gates

Everything in revised §16.6, plus: **Universal Purchase verified in App Store Connect sandbox** (§2.1, and the documentation re-read recorded there) · the **three walkthroughs re-run on macOS** with a real microphone · **U-M1** signed off, because it is the feature.

---

## 17. Stage plan

One reviewable commit per stage; the body names the acceptance criterion. **U**-numbered to distinguish from P-stages. **Stop after each stage and report.**

### U0 — Amend the gates, adapt the resurrected tree, add the target

The gate work is first for the same structural reason P0 was first: the pre-commit hook runs `guard_production.sh`, so until G-P6/G-P7/G-P4 are amended (§0.6), **no commit that adapts the Mac tree can land at all.**

1. Amend gates G-P5→G-U1, G-P6, G-P7, G-P4; add G-U2…G-U5; add a failable probe for each in `scripts/test_guards.sh`.
2. Global renames across `VoxglassMac*` (§5.3): `Studio*` → `Mac*`, purge `voxglass.studio.pro`, delete `Resources/VoxglassStudio.storekit`.
3. Delete the ⛔️ and ☠️ files of §5.3: `CaptureRingBuffer.swift`, `StudioProjectionCoordinator.swift`, `StudioEventSink.swift`, `ProxyGenerator.swift`, and their tests.
4. Add the `VoxglassMac` and `VoxglassMacUITests` targets and the Mac scheme to `project.yml` — **bundle id `guru.parso.voxglass`** (§2.1, gate G-U3) — then `xcodegen generate`. Info.plist and entitlements per §5.3.
5. Restore the compile-only macOS CI job.
6. Extend `AccessibilityAuditTests` to this document's mockups (§15.4) and `LicenseGatePlacementTests` to the three Mac sites (§2.3).

**Acceptance:** `swift test` green; every amended and new gate green **and proven failable**; the Mac target compiles; the iPhone and Watch smoke tests still pass. The Mac app need not yet *work*.

### U1 — The merge model

`Core/Production/Merge/`: `ProductionMerger`, the conflict set, `DeviceIdentity`. The three migration columns and the `paragraph_conflict` table. Un-degrade `ProductionSyncEngine` to fetch-merge-push (§4.3.4).

**Acceptance:** `ProductionMergerTests` green for every row of §4.3.2, including self-merge-is-a-no-op and concurrent-takes-both-survive. No UI yet.

### U2 — Conflict resolution UI + `paragraphTextConflict`

The resolution surface on Mac and iOS (§4.3.3), the validation code (§11), presence (§4.4). `ConflictReachabilityTests` inverted.

**Acceptance:** a two-device divergence fixture raises exactly one conflict, resolves idempotently, survives relaunch, and blocks export until resolved.

### U3 — The Mac app shell

`VoxglassMacApp`, `MacRootView` with the full-app sidebar (D-U3), `MacEnvironment` rewired to today's Core seams, window-per-project, the `Window` menu.

**Acceptance:** four projects open in four windows; each reads its own store; `PackageLock` prevents the same package opening twice.

### U4 — The keyboard map

`KeyboardShortcutMap` in Core (§8.3), the `Commands` tree, typed `MacCommand` routing to the focused window (replacing the `NotificationCenter` fan-out), key-repeat and text-field-focus guards, the shortcut reference sheet.

**Acceptance:** `MacKeyboardMapTests` green; manual **U-M1** and **U-M4** pass.

### U5 — Mac capture

`AVAudioEngineCapture` adapted to today's `AudioCapturing`, feeding Core's ring buffer, `CaptureRouteClassifier`, and `CaptureRecovery`. Per-take `warning` and `routeClass` actually populated. The §7.3 interruption matrix.

**Acceptance:** `CaptureInterruptionTests` green for every row of §7.3; manual **U-M2** and **U-M3** pass; a Mac-recorded take carries a non-nil `routeClass`.

### U6 — Mac authoring surfaces

Script editor, source import with drag-and-drop, take comparison, audio import, assembly, metadata/rights, validation, dashboard — each adapted to today's Core seams, identifiers aligned with the mockups, and its resurrected test suite re-pointed and green.

**Acceptance:** the full authoring loop works on the Mac from import to a validated project; every re-pointed `VoxglassMacTests` suite is green.

### U7 — Library, cross-project queue, export, batch export

The project library (§8.4), the cross-project review queue (§8.5), the export wizard on `ResumableExportRunner` + `ExportPreflight`, batch export behind `batchExport` (§8.6), Finder-shaped output (§12).

**Acceptance:** a LibriVox export from the Mac verifies as 128 kbps CBR / 44.1 kHz / mono; an IA export runs with **no** license check on the path (gate G-P2); manual **U-M8** passes.

### U8 — iPad

`NarrationLayoutRouter`, the regular-width split layout, the shared keyboard map on iPad, the conflict sheet, presence.

**Acceptance:** manual **U-M9** and **U-M10** pass; compact width is byte-for-byte the shipping iPhone flow.

### U9 — Universal Purchase, hardening, release

One StoreKit concrete for both platforms (§13), sandbox verification of Universal Purchase, the Mac smoke test (§16.3), the §16.5 additions, VoiceOver and full-keyboard-access passes, Reduce Transparency on both new platforms, notarization, and the walkthroughs re-run on macOS.

**Acceptance:** the §16.5 matrix passes on all platforms; **U-M7** passes; this spec and its mockups are synchronized with the shipped UI.

---

## 18. App Store notes

**Review note (updated):** "Voxglass is an audiobook player that also lets users record their own narration, on iPhone, iPad, and Mac. The app records the user's own voice and creates local export packages for audiobook distribution. It does not upload content to retailers and does not determine copyright status. The in-app purchase unlocks commercial export formats and mastering and is a Universal Purchase across all three platforms; LibriVox and Internet Archive exports are free on every platform."

**Privacy:** unchanged. No analytics required; iCloud backup, offload, **and cross-device merge** use the user's own private CloudKit database; manuscript text and audio stay on device and in the user's iCloud unless the user exports them; microphone use is explained in-context before the first recording on each platform. The device identity of §4.3.1 is a random per-install UUID and MUST NOT be derived from any hardware identifier.

**macOS specifics:** sandboxed; user-selected-file read/write for Finder-located `.voxproject` packages; microphone entitlement; the app's own iCloud container; notarized. **No new privacy-relevant data is collected by the Mac app** — verify `DiagnosticsBundle` against this claim during U0 (§5.3).

---

## 19. Decisions taken

Resolved with the product owner on **2026-08-11**. An implementing agent follows these without re-asking.

| # | Decision | Why | Lands in |
|---|---|---|---|
| **D-U1** | **Full two-writer conflict model**, not per-project ownership and not a Finder-only Mac. | Ownership-with-transfer would have been cheaper, but it makes the common case — one person, three devices, one book — feel like a checkout system, and every transfer is a chance to be locked out of your own work. The cost is bounded by §4.3.2: takes, assets, and review events cannot conflict by construction, so the merge surface is exactly one field on one entity. | U1, U2 |
| **D-U2** | **Native macOS target**, not Mac Catalyst. | The reason for the Mac app is keyboard and window behavior (§1.3). Catalyst's menu bar, multi-window, and key handling are approximations of exactly the things being bought, and the resurrected tree — 58 files, already Swift 6 — is a native SwiftUI-for-macOS app, so native is also the cheaper path from where the repository actually stands. Cost accepted: a second UI layer to maintain forever. | U0, U3 |
| **D-U3** | **The Mac app is the whole of Voxglass** — Listen, My Books, Explore, Search, and Narration — not a narration-only tool. | Universal Purchase pins it to bundle id `guru.parso.voxglass` (§2.1); an app that *is* Voxglass and cannot play an audiobook would be incoherent to a user who owns it on both platforms. Narration is where the AppKit and keyboard investment goes; the listening surfaces are ported plainly. | U3 |
| **D-U4** | **The Mac does not talk to the Apple Watch.** | No `WatchConnectivity` peer relationship exists, and routing through iCloud would add a second transport for a case the Mac's own keyboard serves better. Watch review of Mac-recorded work still works via iCloud → phone → watch. | Not built; DEFERRED |
| **D-U5** | **The resurrected tree is adapted, not rewritten**, and lives at `VoxglassMac/`. | It is 58 files of working, already-Swift-6 macOS code with 20 test suites, and §5.3 names exactly what drifted. Rewriting would discard `AVAudioEngineCapture` (756 lines of real capture work) and every test that could verify the adaptation. The directory rename is forced by gate G-P6's on-disk check and is also the right final name. | U0 |
| **D-U6** | **iPad narrates in full**, with the iPhone flow as the compact-width fallback. | Reduced-capability iPads were exactly the N-1 mistake — length and device were never allowed to gate the record action again. Making compact width the *shipping iPhone flow verbatim* means iPad support cannot regress iPhone support. | U8 |

### 19.1 Open items

- **O-1 — Pro pricing.** D-2's $49/$79 was justified by "an iPhone-only unlock" (§2.4). That premise is void. Decide before submission; **no code change follows**.
- **O-2 — Universal Purchase mechanics.** Re-read Apple's current documentation at submission and record the result (§2.1). The bundle-id choice stands regardless.
- **O-3 — `DevicePreview`.** §5.3 recommends deleting it. Confirm during U0.
- **O-4 — Mac window tabs vs. a single multi-project window.** §8.4 ships window-per-project with native tabbing, which lets the user choose. If real use shows people always tab, a single-window-with-tabs default is a small follow-up. Do not pre-build it.

### 19.2 Deliberately deferred

Watch complication / Smart Stack (unchanged, revised §19.1) · a second Pro tier (unchanged) · Mac↔Watch anything (D-U4) · iPad multiple scenes (§9.3, MAY) · Apple Pencil notes (§9.3, MAY) · user-customizable keyboard shortcuts (§8.2 ships one fixed, tested map; customization is a settings surface and a persistence format, and neither is worth an MVP stage).
