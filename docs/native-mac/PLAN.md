# Voxglass Native Mac — new implementation plan

**Status:** implemented in the native `VoxglassMac` target; audit recorded below

**Date:** 2026-09-20

**Scope:** a fully native macOS application target, while preserving the existing
iPhone, iPad, Watch, and CarPlay product surfaces.

This is a new plan for the repository as it exists today. It is not a continuation
of the deferred `docs/mac-ipad-universal-mvp/` implementation plan, and it does not
restore the deleted `VoxglassStudio` source tree. That directory remains useful as
historical evidence only.

## 1. Decision summary

Build a native macOS target named `VoxglassMac` with a SwiftUI-first interface and
small AppKit adapters where macOS behavior is materially better: window commands,
menus, file panels, audio-device discovery, and document/window lifecycle.

The native Mac app should feel like the same Voxglass product, not like a Mac port
of a phone tab bar:

- one primary window with a persistent sidebar;
- Listen, My Books, Discover, and Narration remain the four product destinations;
- a selected audiobook opens into one focused narration workspace rather than a
  collection of unrelated dashboards;
- keyboard and microphone workflows are first-class on Mac;
- advanced controls appear in inspectors, sheets, menus, and contextual actions;
- iPhone and iPad remain fully capable of narration;
- the Mac is an optional peer, never a prerequisite or a handoff gate;
- existing local books and production packages remain the source of truth;
- cache clearing can never delete durable local books or local-only recordings.

The first release should optimize for a narrator who wants to sit at a Mac with a
custom microphone, read a script, record many paragraphs quickly, and review or
export without understanding storage, sync, or audio-engine internals.

## 2. Current repository baseline

The following facts are the baseline for this plan and must be rechecked before
implementation begins:

| Area | Current implementation | Native-Mac implication |
| --- | --- | --- |
| Product shell | `Voxglass/App/RootView.swift` uses compact `TabView` and regular-width `NavigationSplitView`; the iOS target supports iPad and Mac Catalyst | Reuse product destinations and state ownership, but give native Mac its own shell, commands, menus, and window behavior |
| App composition | `Voxglass/App/AppServices.swift` owns library, playback, CloudKit, downloads, stats, folders, playlists, backup, and the production environment | Extract shared construction seams; do not copy the iOS `UIApplication` composition root into the Mac target |
| Narration environment | `Voxglass/Features/Production/PhoneProductionEnvironment.swift` owns preview, sync, Watch transport, and `NarrationProjectRepository` | Reuse repository and production state; replace phone/watch-specific composition with a shared production environment and keep Watch as an iPhone companion |
| Project persistence | `NarrationProjectRepository` stores one project per `Application Support/ProductionProjects/<UUID>/` package through `SQLiteProductionStore` and `ProductionProjectLayout` | Native Mac opens the same package layout and schema; no new Mac project database or format |
| Production model | `AudiobookProject`, `ProductionChapter`, `Paragraph`, `Take`, `ReviewEvent`, `ProjectDashboard`, `ProjectSummary`, `ProjectCounts` | These are the model for the Mac library, workspace, review, and progress surfaces |
| Storage | `FileAssetStore`, `ProductionAssetRecord`, `ProductionStoragePolicy`, `ProductionEvictionExecutor`, `AssetHydrationExecutor` | Reuse exact durable/cache boundaries and expose them in a Mac storage inspector |
| Sync | `CloudKitProductionSync`, `ProductionSyncTransport`, `ProductionSyncEngine`, `ProjectionPublisher`, `PhoneProductionSync` | Generalize the current phone-oriented coordinator into a shared peer-capable coordinator before release; preserve existing record types and idempotent event folding |
| Capture | `AudioCapturing` is a platform-neutral protocol; current `AudioSessionCapture` uses iOS/ Catalyst `AVAudioSession`; Core has `CaptureRingBuffer`, `CaptureRecovery`, `CaptureRouteClassifier`, `CapturedTake`, and `AudioMetrics` | Add a native macOS concrete implementation using Core Audio/AVAudioEngine, not another copy of the phone model |
| Narration flow | `NarrationFlow`, `NarrationFlowScreens`, `NarrationProjectRepository`, `ScriptEditorView`, `ParagraphReviewView`, `TakeComparisonView`, `ValidationReportView`, and `ProjectDashboardView` already cover the production workflow | Reuse workflow models and operations; redesign the Mac presentation around a workspace and inspector |
| Assembly/export | `ChunkedRenderCoordinator`, `ResumableExportRunner`, `ExportPreflight`, `ExportPackageZipper`, destination profiles, and validation are in Core | Mac export must call these current APIs, not the deleted old export engine |
| Playback | `PlaybackCoordinator`, `AVPlayerAudioEngine`, positions, bookmarks, downloads, and stats are constructed by the iOS app layer | Create a Mac composition adapter for the same playback services; no separate playback database |
| Package platform | `Package.swift` already declares iOS 17, macOS 14, and watchOS 10; `VoxglassCore` already builds for macOS | Core platform availability is not the blocker; target wiring and app-only dependencies are |
| Current Mac support | `project.yml` has only an iOS application target with `SUPPORTS_MACCATALYST: YES`; no native Mac target exists | Add a genuinely macOS target and scheme; Catalyst remains a compatibility surface, not the native product |

## 3. Historical work: keep, replace, reject

### Keep and adapt

- the historical decision that the Mac uses the same Universal Purchase and
  production capability boundary;
- the existing CloudKit zone and production record types, subject to a current
  sync audit;
- the old recognition that Mac needs keyboard-first recording and a wide script
  workspace;
- the old recognition that iPad should use regular-width layout rather than a
  separate reduced product;
- the old test intent around capture interruption, autosave recovery, export
  resume, and keyboard coverage, after re-pointing those tests to current APIs;
- the current project package, content-addressed asset, hydration, offload, and
  validation architecture that was added after the deleted Mac tree.

### Replace completely

- the old Mac mockups and their visual language;
- the old Mac-as-writer composition root;
- the old export model, in favor of current resumable export and preflight APIs;
- the old recording model, in favor of the current `AudioCapturing` contract and
  `CapturedTake` fields including route class and interruption warning;
- the old device-preview/projection UI, in favor of the same shared project state
  rendered by each platform;
- the old “Mac project library” as a separate data model, in favor of the current
  `ProjectSummary` and `NarrationProjectRepository`.

### Explicitly rejected in this plan

These concepts must not be copied back into code, copy, mockups, or tests:

- `VoxglassStudio`, “Studio”, or any resurrection of the deleted source tree;
- a Mac prerequisite, handoff prompt, or phrases such as “Record on Mac”,
  “Continue on Mac”, or “Requires a Mac”;
- a platform-conditional Pro tier or separate Mac purchase;
- a second project/package format, second production database, or renamed CloudKit
  record family;
- a Mac-to-Watch direct transport; Watch remains connected through the iPhone;
- the historical two-writer/conflict UI as a speculative feature. The current
  sync implementation is phone-oriented, so the first engineering task is to
  prove the smallest peer-write semantics against the current transport and event
  model. Do not add a large conflict center until a real supported conflict case
  exists and is covered by tests;
- a mandatory window-per-project workflow, cross-project review queue, or batch
  export dashboard as part of the first native Mac release;
- old `StudioProjectionCoordinator`, `PackageLock`, `DevicePreview`, or old
  export/recording services merely because their filenames exist in Git history;
- a phone-shaped bottom tab bar as the primary Mac navigation model.

## 4. Product experience

### 4.1 Front door: one library, four destinations

The Mac window opens to the same four user-facing destinations already named by
the app. The sidebar is persistent and the content area is wide:

- **Listen** shows current playback, continue listening, and the mini-player;
- **My Books** shows the user's listening library and local files;
- **Discover** searches and browses the catalog;
- **Narration** shows started narration projects and the single action to start a
  new one.

These destinations are deliberately distinct. Listen answers “what should I
resume right now?”, My Books answers “what do I own or keep locally?”, Discover
answers “what could I listen to next?”, and Narration answers “what am I making?”
The Mac shell must not collapse all four into one dashboard just because the
window is larger.

The detailed screen proposals are:

| Surface | Default focus | Primary action | Complexity moved off the main path |
| --- | --- | --- | --- |
| Listen | Current session and one-tap resume | Resume listening | Recommendation tuning, queue editing, playback diagnostics, and download management |
| My Books | Searchable local library | Open or resume a book | Secondary filters, sort, storage state, import, and destructive actions |
| Discover | Search first, collections second | Search catalog / open a result | Catalog source details, advanced filters, and collection explanation |
| Narration | Projects already started | Record next | Sync, asset state, validation detail, and audio setup |

Native Mac users should not have to know which service owns a book or which store
owns a take. The sidebar and title bar expose user tasks, not implementation
layers.

### 4.2 Narration entry

Narration starts from one list of current projects. Each row shows title, author,
recorded progress, review attention, and sync/storage state only when it needs the
user's attention. A new narration starts from the existing New Narration flow.

There is one primary action: **Record next**. The Mac workspace should make the
next paragraph obvious without requiring the user to understand chapter, take,
proxy, or projection terminology.

### 4.3 Workspace

When a project is opened, the main window becomes:

1. a narrow chapter/paragraph navigator on the left;
2. a large script and recording surface in the center;
3. an optional inspector on the right for take selection, review, notes, route,
   project metadata, validation, and storage details.

The inspector is hidden when it is not needed. The center surface never shrinks
to make room for every possible control.

The selected paragraph is the unit of work. Next/previous, record, stop, accept,
retry, flag, note, and play are all available without leaving the workspace.

### 4.4 Mac recording

The recording surface prioritizes:

- current paragraph text with comfortable reading width;
- mic and monitoring device in a compact route control;
- route quality and warning only when relevant;
- level meter, elapsed time, and capture state;
- one large record/stop control;
- take actions after stop: listen, keep, retry, compare, flag;
- keyboard equivalents that do not fire while focus is inside an editor.

The user does not see a graph of the whole audio pipeline. Diagnostics remain in
the inspector and support bundle.

### 4.5 Review and export

Review starts from the selected paragraph or the project's attention counts. The
Mac surface uses the current review states and notes. Validation and export are
progressive disclosure:

- the primary action is **Export** when the project is ready;
- if blocked, the interface names the one most useful next action;
- a details disclosure lists all remaining blockers;
- preflight, hydration, render, package, and checksum progress are shown only
  while work is running or when recovery is needed;
- interrupted export offers **Resume** from the persisted export run.

### 4.6 Storage and sync

Settings and the project inspector show separate totals for:

- durable local book/project data;
- regenerable render and proxy cache;
- export staging;
- local recordings that are not yet verified remotely;
- remote-only originals available to hydrate.

Clear-cache actions must be scoped and cannot touch durable local books or
local-only originals. A destructive action must state the exact category and
byte count before it runs.

### 4.7 Listen / home

Listen is the app's action-oriented home, not a generic recommendation wall. Its
vertical order is fixed:

1. current playback card with title, chapter, position, and Resume/Play;
2. a compact “Continue listening” row for the next two recently played books;
3. downloaded/offline books when the user has any;
4. recommendations and listening history below the fold.

When nothing is playing, the empty state gives the user exactly two useful
choices: open My Books or Discover. It does not expose audio-engine state, sync
queues, or a large explanatory listening section.

The mini-player is persistent while navigating and expands into Now Playing. A
Mac keyboard command can focus playback without changing the selected sidebar
destination. Playback actions use the existing `PlaybackCoordinator`, position
store, bookmarks, stats, and offline download manager.

### 4.8 My Books

My Books is the user's durable listening library. It is not the narration project
library and must not mix the two models in one list.

The title bar contains Search, Add/import, and a compact filter/sort control. The
search field is revealed on demand and searches title, author, and narrator using
the current `LibraryStore`/`LibraryRepository` paths. The default list is recently
used, with a visible progress bar and offline/download state on each row.

Each row supports the direct action Open/Resume. Secondary actions—download,
remove download, edit metadata, add to playlist, share, and remove from library—
live in a contextual menu or inspector. Removing a downloaded cache copy must not
remove a local book file or a narration project's original take.

The Mac layout uses rows rather than large cards so many books remain visible at
once. Covers are supportive, not the navigation structure. Empty, searching,
filtering, and failed-download states each have a single next action.

### 4.9 Discover

Discover starts with a title-bar search button. Clicking it reveals a search field
and keeps the results in the same page; pressing Escape dismisses search without
losing the result list. Search covers title, author, and narrator. The adjacent
filter button opens a popover for source, language, narration style, and other
secondary filters rather than taking over the page.

Below the header is a compact mode bar: **All / Collections**. All shows search
results and curated shelves. Collections shows the featured collection list. When
a collection is chosen, the featured list collapses and a selected-collection
pill appears with an X to clear it. Searching while a collection is selected
searches within that collection; searching without one automatically uses All.

Every result has one direct action—open its book page—and secondary actions in a
context menu. Collection explanation is behind an info button on the collection
card; it is never a tall block that pushes the catalog below the fold. Catalog
source, rights, and narrator details remain available in the book page or info
popover.

Discover reuses the current `BrowseView`, catalog store, collection preferences,
Internet Archive/LibriVox/Project Gutenberg integration, and saved catalog
preview behavior. It does not add a second catalog model for Mac.

## 5. Native Mac architecture

### 5.1 Target layout

Add a new target and source tree, without restoring historical files:

```text
VoxglassMac/
  App/
    VoxglassMacApp.swift
    MacAppServices.swift
    MacCommands.swift
    MacWindowState.swift
  Audio/
    MacAudioCapture.swift
    MacAudioDevices.swift
    MacAudioNotifications.swift
  Features/
    Shell/
    Library/
    Narration/
    Settings/
  Resources/
    Info.plist
    VoxglassMac.entitlements
VoxglassMacTests/
VoxglassMacUITests/
```

The names above are a new proposal, not a request to restore `VoxglassStudio`.
The native target may use SwiftUI views and AppKit representables, but no UIKit
or Catalyst-only APIs may be required for the Mac target.

### 5.2 Shared and native boundaries

Keep in `VoxglassCore` or existing shared app modules:

- project domain and summaries;
- SQLite production stores and migrations;
- file/package layout;
- asset state, upload, hydration, eviction, and storage policy;
- source import and script application;
- capture protocol, route value types, recovery, ring buffer, and metrics;
- review events, notes, counts, validation, assembly, and export;
- CloudKit-neutral production transport/projection types;
- StoreKit product identity and entitlement decisions.

Keep in `VoxglassMac`:

- AppKit lifecycle, menu commands, scenes, windows, toolbar, inspectors, and
  native file panels;
- native macOS microphone enumeration and route observation;
- Mac playback/capture composition adapters;
- Mac-specific error presentation and permission handling;
- Mac UI state such as selected project, selected paragraph, inspector visibility,
  and keyboard focus.

Do not put the new Mac UI in `Voxglass/Features/Production/` and do not make the
iOS app import the Mac target.

### 5.3 Composition root

Create `MacAppServices` as a native composition root. It should construct or
receive shared services for:

- `AppDatabase` and library repositories;
- playback coordinator and positions/bookmarks/stats;
- `NarrationProjectRepository`;
- a generalized production sync coordinator;
- asset upload/hydration/eviction services;
- download and folder-watch services where the macOS sandbox permits them;
- StoreKit entitlement state;
- the native Mac capture implementation.

The generalized production coordinator should be extracted from the current
`PhoneProductionSync` in small, tested steps. It must preserve:

- existing CloudKit zone and record names;
- content-addressed asset identity and SHA-256 verification;
- idempotent review-event folding;
- offline local writes;
- non-blocking local project reads;
- explicit hydration before playback/export when an original is remote-only;
- current low-power behavior where applicable.

The extraction must not introduce a speculative conflict center or a second
merge product. First define the actual current mutation ordering and add fixtures
for two devices saving non-overlapping takes, review events, metadata, and the
same paragraph. Only then decide whether a narrowly scoped conflict record is
needed.

### 5.4 Native macOS audio

Implement `MacAudioCapture: AudioCapturing` with a Core Audio/AVAudioEngine
backend appropriate for macOS. Required behavior:

1. enumerate input and monitoring devices with stable IDs;
2. honor the selected `RecordingDefaults` sample rate/channels/bit depth where
   hardware allows it;
3. write to the current autosave destination without blocking the UI;
4. feed levels and clipping state through the existing capture value types;
5. classify the route with `CaptureRouteClassifier`;
6. surface hardware changes, device removal, interruptions, and write failures;
7. finalize a valid file before handing it to `ingestCapturedTake`;
8. recover an interrupted session through the existing `CaptureRecovery` contract;
9. prove that every Mac-created `Take` carries the real route class and warning
   values where applicable.

The Mac target gets the audio-input sandbox entitlement and microphone usage
description. The settings UI must explain denied permission and missing devices
in plain language.

### 5.5 Sync model for the Mac release

The current code says “phone is the sole writer.” That is a current implementation
constraint, not a reason to create a Mac-only database. Before the native Mac
release:

- rename/extract the coordinator around its actual responsibilities;
- allow a Mac-local project store to publish and pull using the same production
  transport and record types;
- make project and asset mutations idempotent across repeated sync passes;
- define and test ordering for take insertion, selected-take changes, review
  events, and metadata changes;
- keep Watch relay code on the phone side;
- show sync state as advisory status, never as a blocker for local recording;
- avoid claiming multi-device conflict resolution beyond what the tests prove.

If the current CloudKit mirror cannot safely accept peer writes for a field, the
release must either add a narrowly scoped, tested rule or keep that field local
until the rule exists. It must not silently overwrite recordings or delete local
assets.

## 6. Native Mac UI specification

### 6.1 Window and navigation

- One main `WindowGroup`/document-like project window for the product shell.
- Persistent sidebar with Listen, My Books, Discover, and Narration.
- Toolbar title reflects the current destination or project.
- Toolbar actions are task-oriented: search, add, record next, inspector,
  settings, and playback.
- Native menus mirror visible actions and expose keyboard equivalents.
- A project workspace may use a second window only as an optional later feature;
  the first release does not require window-per-project concurrency.
- The mini-player remains available while browsing and collapses into the native
  toolbar/status area when the window is short.

### 6.2 Keyboard map

Implement a typed command layer routed to the focused Mac window. The initial map:

| Command | Default key | Rule |
| --- | --- | --- |
| Listen | `⌘1` | Switches destination unless text editing owns the key |
| My Books | `⌘2` | Same |
| Discover | `⌘3` | Same |
| Narration | `⌘4` | Same |
| Search | `⌘F` | Focuses the current destination search field |
| Record/stop | `⌘R` | Only when a paragraph is selected and no text editor is focused |
| Accept and advance | `⌘Return` | Only after a take exists |
| Retry | `⌘⇧R` | Only after a take exists |
| Next paragraph | `⌘↓` | Moves selection, preserving unsaved state |
| Previous paragraph | `⌘↑` | Same |
| Play selected take | `Space` | Not while a text field is focused |
| Stop playback | `Escape` | Does not dismiss unrelated sheets |
| Toggle inspector | `⌘⌥0` | Native Mac convention may be adjusted during testing |
| Open settings | `⌘,` | Native application command |

Tests must assert no duplicate shortcut, no shortcut firing inside a text editor,
and no command targeting a non-focused project window.

### 6.3 Accessibility and automation

New mockup identifiers use the `native-mac.` namespace. Final implementation IDs
must be stable and semantic, for example:

- `native-mac.sidebar.narration`;
- `native-mac.projects.record-next`;
- `native-mac.workspace.paragraph-list`;
- `native-mac.record.toggle`;
- `native-mac.inspector.take-compare`;
- `native-mac.export.start`.

Identifiers are a future UI-test contract, not evidence that the mockups are
implemented.

### 6.4 Listen, My Books, and Discover implementation details

The native Mac target should implement the three listening surfaces as separate
feature roots that share the existing services:

| Feature root | Existing source of truth | Mac presentation | Required behavior |
| --- | --- | --- | --- |
| Listen | `ListenView`, `PlaybackCoordinator`, `HomeRecommendationStore`, `ListeningStatsStore` | Resume card, compact shelves, Now Playing expansion | First meaningful action within one click; recommendations cannot block playback |
| My Books | `LibraryView`, `LibraryStore`, `LibraryRepository`, `OfflineDownloadManager` | Dense searchable table/list with contextual actions | Search appears in the title bar; row state preserves position and download state |
| Discover | `BrowseView`, `CatalogStore`, collection preferences, catalog fetchers | Search-led results with All/Collections mode bar | Search, collection scoping, filter popover, and info disclosure preserve result context |

Each root gets a small Mac view model that translates existing service state into
renderable rows. It must not load all audio bytes, all recommendations, or every
catalog detail on the main actor. Results should be incremental and cancellable;
the UI must remain scrollable while search or artwork work is in flight.

Required state transitions:

- Listen: `idle → loading playback snapshot → ready` must show a useful empty
  state if there is no session; recommendations cannot block `ready`.
- My Books: `searching → results/empty/error` must retain the last valid list until
  the replacement result is ready, avoiding a blank flash.
- Discover: `mode + query + collection + filters` is one query state; clearing one
  control must not clear the others unexpectedly.
- All three surfaces keep the mini-player visible and preserve its playback
  position when navigating.

### 6.5 Native macOS menu bar

The menu bar is a second path to the same actions, not a hidden second feature
set. Every menu command has a matching visible toolbar, sidebar, or contextual
action where it is relevant.

**Voxglass**

- About Voxglass
- Settings… (`⌘,`)
- Services
- Hide Voxglass (`⌘H`)
- Hide Others (`⌥⌘H`)
- Quit Voxglass (`⌘Q`)

**File**

- New Narration (`⌘N`)
- Open Project… (`⌘O`)
- Import Book…
- Import Audio…
- Close Window (`⌘W`)

**Edit**

- Undo / Redo
- Cut / Copy / Paste
- Select All
- Add Note to Selected Paragraph

**View**

- Show/Hide Sidebar (`⌘⌥S`)
- Show/Hide Inspector (`⌘⌥0`)
- Show Search (`⌘F`)
- Actual Size / Zoom In / Zoom Out where a script or book page supports it

**Playback**

- Play/Pause (`Space` when focus permits)
- Stop (`Escape`)
- Previous Chapter
- Next Chapter
- Show Now Playing
- Add Bookmark

**Narration**

- Record / Stop (`⌘R`)
- Accept Take and Next (`⌘Return`)
- Retry Take (`⌘⇧R`)
- Previous Paragraph (`⌘↑`)
- Next Paragraph (`⌘↓`)
- Open Audio Setup…
- Open Review & Export…

**Window**

- Minimize (`⌘M`)
- Zoom
- Bring All to Front

**Help**

- Voxglass Help
- Keyboard Shortcuts
- Recording Troubleshooting
- Send Diagnostics…

Menu command rules:

- commands are disabled when their current context cannot perform them;
- Record/Stop never fires while a text editor owns keyboard focus;
- playback commands operate on the current `PlaybackCoordinator` session;
- narration commands operate on the focused project workspace, not a global
  notification broadcast;
- menu titles use user tasks, never internal words such as projection, hydration,
  asset record, or mutation log;
- `mockups/09-menus.html` is the visual contract for hierarchy, grouping, and
  disabled-state treatment.

## 7. Build, entitlement, and distribution work

1. Add a macOS application target to `project.yml` with a new source root and
   native macOS `Info.plist`/entitlements.
2. Keep `VoxglassCore`'s macOS package support and add only missing availability
   annotations or abstractions exposed by compilation.
3. Link only native Mac dependencies needed by the app. Do not link WatchConnectivity
   or CarPlay into the Mac target.
4. Use the same product identifier, app record, Apple ID/SKU, and Pro entitlement
   as the existing iOS/iPad app. Do not create `voxglass.studio` or a Mac-only
   product.
5. Add a native Mac scheme and a macOS test destination to CI after local build
   and unit coverage are stable.
6. Add sandbox capabilities for microphone input, user-selected files, network
   access, and the existing iCloud container only where required by the target.
7. Keep the Catalyst build until the native target proves it can replace the
   intended Mac workflow; do not silently change Catalyst into the native
   distribution lane.

## 8. Test plan and acceptance gates

### 8.1 Core and sync tests

Add or adapt tests for:

- opening an existing `.voxproject` on Mac without migration or data loss;
- current SQLite migration and schema version;
- project summaries and paragraph summaries matching iPhone/iPad;
- two offline devices inserting different takes and later syncing;
- repeated sync passes being idempotent;
- review event folding and outbox replay;
- remote-only hydration with SHA-256 verification;
- eviction never selecting local-only, uploading, pinned, working-set, or
  unverified originals;
- clearing render/proxy/export cache never deleting a local book or local-only
  original;
- export preflight, resume after interruption, checksum output, and package
  contents;
- StoreKit entitlement parity across targets.

### 8.2 Native Mac unit tests

- `MacAudioCaptureTests`: device selection, format, route classification, write
  finalization, interruption, device removal, and recovery.
- `MacCompositionTests`: required services are constructed lazily and test
  processes do not touch unavailable CloudKit entitlement paths.
- `MacCommandTests`: map, focus rules, key repeat, and focused-window routing.
- `MacProjectWorkspaceTests`: selection, next/previous, accept/retry, notes, and
  inspector state.
- `MacStoragePresentationTests`: displayed bytes equal the scoped inventories.

### 8.3 UI and manual matrix

Native Mac UI tests should cover:

1. boot into the sidebar and switch all four destinations;
2. create/open a narration project;
3. select a paragraph and record using keyboard only;
4. stop, play, accept, retry, and move to the next paragraph;
5. open the inspector, add a note, select a take, and hide the inspector;
6. run validation, see a useful blocker, fix it, and export;
7. resume an interrupted export;
8. clear cache while a local-only take exists and verify the take remains;
9. deny microphone permission and recover through Settings;
10. change input device while idle and during monitoring;
11. sign out or lose network and continue recording locally;
12. reopen the project after relaunch and recover autosave.

Manual hardware tests must include a USB microphone, an aggregate/multi-channel
device if supported, device removal, sleep/wake, external display, reduced
window height, VoiceOver, keyboard navigation, and a long project with at least
1,000 paragraphs.

### 8.4 Release gates

The native Mac target is not release-ready until all are true:

- `swift test` is green;
- native Mac Debug and Release builds are green;
- iPhone/iPad, Watch, and CarPlay tests remain green;
- local-only originals survive every cache-clear path;
- no rejected handoff phrase appears in app source, tests, mockups, or docs;
- no old Studio source is reintroduced;
- a real Mac recording has a non-nil route classification where expected;
- a project recorded on Mac can be opened and reviewed on iPhone/iPad after sync;
- a project recorded on iPhone/iPad can be opened and continued on Mac;
- export produces the same destination-valid package on all supported platforms;
- App Store Connect validates the shared purchase and native macOS metadata.

## 9. Implementation stages

### M0 — lock the current baseline

- Capture current `swift test`, iOS/iPad build, Catalyst build, and existing UI
  test results.
- Read the actual current production CloudKit schema and mutation paths.
- Add no UI. Produce a short sync decision record with tested current behavior.

**Exit:** baseline results are recorded; no data-model or target changes yet.

### M1 — extract shared production composition

- Split phone-only Watch relay and phone-only preview responsibilities from the
  production sync coordinator.
- Keep the existing phone behavior unchanged.
- Add in-memory transport fixtures and peer-write/idempotency tests.
- Make the shared coordinator usable by a Mac process without constructing UIKit,
  WatchConnectivity, or CarPlay services.

**Exit:** the current iOS target still passes, and a macOS host test can load a
project, fold events, and run a sync fixture.

### M2 — native target and shell

- Add `VoxglassMac` target, resources, entitlements, scheme, and app entry point.
- Implement sidebar, toolbar, commands, settings window, and shared playback.
- Wire My Books and Narration project list to current repositories.
- Add Listen, My Books, and Discover roots using current playback, library,
  catalog, and download services.
- Add the native menu hierarchy and route commands through focused-window state.

**Exit:** a signed local Mac build opens existing projects and no historical Mac
source file has been restored. The four listening/narration destinations are
reachable from both the sidebar and the menu bar, and the mini-player survives
navigation.

### M3 — project workspace

- Implement chapter/paragraph navigator, script center, inspector, notes,
  selected take, and progress.
- Reuse current `ProjectDashboard`/`ProductionStore` queries rather than loading
  an entire long project into SwiftUI state.
- Add focused-window keyboard routing.

**Exit:** a 1,000-paragraph project remains responsive while navigating and
editing; selection and notes survive relaunch.

Before proceeding, verify that Listen, My Books, and Discover remain responsive
while a narration project is open and while a search is in flight.

### M4 — native capture

- Implement native Mac `AudioCapturing`.
- Add microphone permission, device menu, monitoring, meters, interruption and
  recovery UI.
- Ingest a finalized take through `NarrationProjectRepository`.

**Exit:** a real USB microphone recording is playable, recoverable, classified,
  and visible on the existing iOS/iPad flow.

### M5 — review, validation, storage, export

- Add current review states, take compare, validation, hydration, assembly, and
  resumable export.
- Add storage inspector with durable/cache separation and safe clear actions.

**Exit:** an end-to-end Mac narration can be recorded, reviewed, validated,
  exported, resumed after interruption, and safely cache-cleared.

### M6 — iPad fit and shared release hardening

- Verify the already-shipped regular-width iPad surface against the new shared
  workspace state.
- Fix only shared model/composition defects; do not force native Mac menus or
  AppKit behavior into iPad.
- Run all platform, entitlement, accessibility, and field hardware tests.

**Exit:** iPad remains a full narration surface, the Mac is optional, and all
  release gates in section 8.4 pass.

## 10. Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| `PhoneProductionSync` assumes one writer | Extract behind fixtures first; test peer writes before exposing Mac sync |
| App-only services use UIKit or iOS-only audio APIs | Native Mac composition root; protocol adapters; compile the target early |
| Core currently contains CloudKit imports despite older “platform-free” claims | Document actual boundaries; do not assume purity; isolate only code proven to need isolation |
| Long projects freeze SwiftUI | Query summaries, use lazy lists, keep audio/file work off the main actor, and add the 1,000-paragraph test |
| Mac audio device behavior differs from iOS | Implement native device enumeration and test physical route changes |
| Storage copy becomes misleading | Derive every number from the current package and asset repositories; never infer from cache limit settings |
| Old Mac concepts creep back in through copy or mockups | Keep this plan as source of truth; reject old filenames, handoff language, and Studio screens in review |
| Universal Purchase/bundle configuration is irreversible after release | Add build and App Store Connect checks before the first native Mac upload |

## 11. Definition of done

The work is complete when a user can install the native Mac app, open the same
Voxglass account and project they use on iPhone/iPad, choose a custom microphone,
record and review a long narration with keyboard-first controls, recover from an
interruption, see truthful storage/sync state, export a valid audiobook package,
and return to the phone without a handoff ceremony or a second data model.

The Mac must make the production workflow more direct while hiding complexity;
it must not merely expose every internal service in a larger window.

## 12. Implementation audit — 2026-09-20

The plan was implemented and audited against the generated native target. The
following checks are now covered by code, build configuration, or tests:

- `VoxglassMac` is a real macOS 14 application target with native resources,
  sandbox microphone/file/network/iCloud capabilities, a scheme, and a settings
  scene. Catalyst and iPad remain separate existing surfaces.
- The shell uses a persistent sidebar for Listen, My Books, Discover, and
  Narration, a persistent mini-player, inspectors, native settings, and the
  menu command layer. The four destinations are reachable without exposing
  storage, sync, or playback implementation details.
- Listen has a resume-first layout; My Books has title-bar search, title/author/
  narrator matching, folder import, progress filters, contextual offline actions,
  and dense rows; Discover has title-bar search, title/author/narrator scope,
  real `IACollection` selection, collection-scoped searches, All/Collections
  state, collapsible featured collections, clearable selection pills, sort
  popover, and info disclosures.
- Narration opens existing project packages, creates a project from a selected
  text source, provides a wide paragraph workspace, keyboard record/accept/retry
  navigation, native AVAudioEngine capture, route classification, USB/Core Audio
  device selection, interruption notification, autosave ingestion, validation,
  and resumable shared export builders.
- The Mac production sync coordinator is lazy, uses the existing CloudKit zone,
  projection publisher, asset uploader, content-addressed files, and sync
  engine; it never blocks local recording on network availability. The ordinary
  library sync remains separate from production-package sync.
- Settings reports streaming cache, offline downloads, and narration-package
  originals/render/proxy/export/orphan totals separately. Cache clearing is
  confirmed with exact byte counts and explicitly leaves local book files and
  narration originals untouched.
- A native Mac unit-test target covers typed command delivery and destination
  coverage. The native Debug build and Mac unit tests were run locally; the CI
  compile job now includes the native Mac build.

The implementation intentionally keeps the current production transport's
projection semantics rather than inventing a second Mac database or CloudKit
record family. Any future expansion of full-project peer hydration must extend
the existing transport contract and its fixtures; it is not represented as a
Mac-only workaround here.

## 12. Design references

The platform decisions are consistent with Apple's current guidance:

- [Mac Catalyst](https://developer.apple.com/documentation/uikit/mac-catalyst)
  is an iPad-derived path; this plan keeps it as a compatibility surface while
  adding a separate native macOS target.
- [Apple app design and UI](https://developer.apple.com/documentation/technologyoverviews/app-design-and-ui)
  distinguishes SwiftUI's cross-platform layer from AppKit's native macOS
  capabilities; this plan uses SwiftUI for shared presentation and AppKit only
  where Mac behavior is materially native.
- [Creating a macOS app](https://developer.apple.com/tutorials/swiftui/creating-a-macos-app)
  supports a separate macOS app target that shares model code and tailors the
  platform UI.
- [Adding platforms in App Store Connect](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-platforms)
  is the basis for verifying the shared app record and Universal Purchase
  configuration before release.
- [Configuring the macOS App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)
  informs the microphone, file access, network, and iCloud entitlement work.
