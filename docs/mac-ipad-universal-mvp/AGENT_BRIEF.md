# Agent brief — implement the Mac + iPad Universal MVP

Paste the block below as the opening prompt for a coding agent working in `/Users/arley/github/parso-voxglass`.

---

## The prompt

You are implementing a specified feature in an existing Swift 6 / SwiftUI repository that already ships an iPhone + Apple Watch audiobook narration app. The specification is complete and decided; your job is to build it, stage by stage, without re-deriving decisions.

### Source of truth

**`docs/mac-ipad-universal-mvp/SPEC.md` is normative.** It is a *delta* over `docs/iphone-watch-only-revised-mvp/SPEC.md`, which remains normative for everything the delta does not restate. Read in this order before writing any code:

1. **§0.5–§0.7** — three corrections tables (U-, G-, R2-series). These are the *only* places a decision changes. **§0.6 is the gate table and it is why stage U0 exists.**
2. **§2** — Universal Purchase. §2.1 pins the macOS bundle id to `guru.parso.voxglass`, which is irreversible after the first sale.
3. **§4.3** — the two-writer merge model. The pivotal change and the only genuinely new engineering.
4. **§5**, especially **§5.3** — the per-file disposition of the resurrected macOS tree. **Read this before creating any file.** Most of the Mac app already exists.
5. **§8** — the macOS keyboard and multi-project model. This is the product reason the Mac app exists; it is not chrome.
6. **§17** — the stage plan, U0 through U9.
7. **§19** — decisions already taken (D-U1…D-U6). Do not reopen them.

Then read **`docs/mac-ipad-universal-mvp/GAP_ANALYSIS.md`**, which maps all 41 gaps onto real files with evidence, and names the six files to delete outright and the three that are not mechanical.

Two inherited documents are cited and must **not** be re-derived or duplicated:

- `docs/voxglass-mvp/VOXGLASS_STUDIO_SPEC.md` — destination constants (§3), text pipeline (§9–10), assembly (§12), validation catalogue (§15). Cite sections; import constants from `Voxglass/Core/Production/Destinations/`.
- `docs/voxglass-narration/NARRATION_NEEDS_SPEC.md` — the discovery ladder, unchanged.

Mockups are the visual contract: `docs/mac-ipad-universal-mvp/mockups/index.html` for Mac and iPad, `docs/iphone-watch-only-revised-mvp/mockups/index.html` for iPhone, Watch, **and compact-width iPad**. HTML `id` attributes are the `.accessibilityIdentifier` values you must use.

### Start with U0, and understand why

`scripts/guard_production.sh` runs in the pre-commit hook. Gates **G-P5, G-P6, and G-P7** were written specifically to keep the macOS tree deleted. **Until you amend them, no commit that touches the Mac tree can land at all.** U0 is not cleanup; it is the unlock.

Gate changes land in **U0 and only U0**. Never weaken a gate as a side effect of another stage — if a later stage trips a gate, that is a signal about the code, not about the gate.

### The working tree right now

`VoxglassMac/`, `VoxglassMacTests/` (19 files), and `VoxglassMacUITests/` are **restored verbatim** from commit `c0c6712^` — the parent of the commit that deleted the macOS Studio surface — under new directory names so gate G-P6's on-disk check stays green. **No file content was altered.** The tree is inert: no `project.yml` target references it, `Package.swift` does not compile it, `swift test` does not see it.

Git records these as **plain additions, not renames**, so `git log --follow` will *not* reach the pre-deletion history. Read it at the old path instead:

```
git log  c0c6712^ -- VoxglassStudio/<path>     # history
git show c0c6712^:VoxglassStudio/<path>        # the original bytes
```

**Cite `c0c6712^` in your U0 commit body.** That commit message is the only place this provenance will be recorded.

Do not revert it, and do not rewrite it wholesale. It is 58 files of already-Swift-6 macOS UI with 19 real test suites, and §5.3 names exactly what drifted.

### Three things that will bite you

1. **`Take` gained `warning` and `routeClass` with default values.** `VoxglassMac/Features/Record/RecordingModel.swift` therefore **compiles clean and is silently wrong** — every Mac take records `.none` and `nil`, which quietly defeats route classification (§7.1) and the interruption matrix (§7.4). Nothing fails until retail validation months later. Same class of trap in `AssemblySettings.trimSilenceAtEdges` / `normalizeLoudness`. **A clean compile is not evidence of a correct adaptation.**
2. **Core moved +3,823 lines under the resurrected UI** since it was deleted — `CloudAssets/` in its entirety, `ResumableExportRunner`, `ExportPreflight`, `ChunkedRenderCoordinator`, `CaptureRouteClassifier`, `CaptureRecovery`, the C-atomics `CaptureRingBuffer`. Your job in most files is to *delete duplicated logic and call Core*, not to port anything.
3. **Merge scope creep.** SPEC §4.3.2 is a closed table: implement exactly those rules and add none. Takes, assets, and review events cannot conflict *by construction*, and that is what makes this shippable. Every extra "smart" merge rule is a new conflict case and a new test matrix.

### Working method

**One stage per commit.** Imperative subject; body names the acceptance criterion the stage satisfies. **Stop after each stage and report** — do not chain U0 → U9 in one run.

For each stage: read the §5 inventory rows and the GAP_ANALYSIS entries it touches → read the existing code → make the change → run the gates → commit → report what passed and what you chose.

If a stage's acceptance test cannot pass, **stop and report**. Do not weaken the test, do not mark the stage done, do not proceed.

If the spec and the repository disagree on a *fact* — a file path, a type name, an existing behavior — the **repository wins**; report the discrepancy in your stage report. If they disagree on *intent*, the **spec wins**. Never silently pick one.

**Re-point the resurrected `VoxglassMacTests` suites before writing new tests.** They are the cheapest possible check on whether an adaptation was correct.

### Verifying your work

```
swift test                        # Core suites — this is what CI runs
scripts/test_logic.sh             # Core + performance budgets
scripts/guard_production.sh       # CI grep gates
scripts/test_guards.sh            # proves each gate can fail — every amended/new gate needs an entry
scripts/test.sh --all             # UI smoke tests: LOCAL pre-commit gate only
xcodebuild -scheme VoxglassMac build   # after U0
```

**CI runs no simulator.** `macos-latest` runs `compile`, `logic-tests`, `testflight`; `ubuntu-latest` runs `guarded-tests`. U0 adds a **macOS build step to `compile`** — it needs no simulator and no signing. Do not add anything to CI that boots a simulator.

Set the `git commit` timeout to at least **1500 seconds** (the pre-commit hook runs wiring guards, logic tests, and simulator smoke tests). `git push` needs ~120 seconds and runs no tests.

### Repository conventions (non-negotiable)

- **Swift 6 language mode, complete strict concurrency, warning-free.** No mixed modes, no suppression, no unexplained concurrency escape hatch. See `CLAUDE.md`.
- **XcodeGen** from `project.yml`. Never hand-edit `Voxglass.xcodeproj`. Run `xcodegen generate` after changing `project.yml`.
- **No GRDB.** Persistence is a hand-rolled `actor` over SQLite3 with integer-numbered append-only migrations.
- **`@Observable` only.** `ObservableObject` is banned and fails a gate (extended to `VoxglassMac/` as G-U4).
- **`Date()` / `UUID()` only through the `Clock` / `IDGenerator` seams.** The new `DeviceIdentity` seam follows the same pattern.
- Core in `Voxglass/Core/Production/<Area>/`; iOS UI in `Voxglass/Features/Production/`; macOS in `VoxglassMac/`; watch in `VoxglassWatch/Production/`. **Never** create `…/ProductionStudio` or re-create `VoxglassStudio/`.
- **Core stays platform-free** — no `import AppKit`, no `import UIKit` (gate G-U2) — and free of CloudKit and StoreKit; concretes live in app targets behind protocol seams. The watch never links CloudKit.
- 4-space indent, `///` on every `public` symbol, no force-unwraps outside tests, `// MARK: -` in files over ~150 lines.
- New Core tests in `VoxglassTests/Production/`; Mac-target tests in `VoxglassMacTests/`.

### Hard constraints — violating any of these is a failed stage

1. **Never lose a take.** Write ordering (revised §9.4) is MUST-ordered: bytes durable *before* metadata mutation. This now also means: **a merge never loses a take** — takes union by id, always (SPEC §4.3.2).
2. **Never evict before verified.** No original may be removed locally until its iCloud copy is SHA-256-verified *and* the remote asset id is persisted. Call `ProductionAssetRecord.isEvictable`; never re-derive it.
3. **`LicenseGate` appears in exactly six files** — the export destination picker, export runner, and Settings, once per UI platform (SPEC §2.3). Never in recording, review, validation, assembly, storage, sync, the project library, the keyboard map, or watch code. The Internet Archive builder never consults it (gate G-P2).
4. **The lane decides the tier, never the device.** A platform-conditional tier — "free on iPhone, Pro on Mac" for the same lane, or the reverse — is forbidden. No gate can catch this; it is on you.
5. **Validation is never gated.** A free user must be able to run and read a full ACX report on every platform.
6. **Do not degrade listening.** The consumer player, downloads, CarPlay, and playback-position sync must not regress. Losing a user's playback position is a hard product failure.
7. **The bundle id is `guru.parso.voxglass` on macOS.** Universal Purchase depends on it and it is irreversible after the first sale.

### Start here

Begin with **U0 — Amend the gates, adapt the resurrected tree, add the target** (SPEC §17). Before editing, reply with:

- your reading of which gates U0 amends and what each amendment gives up,
- the exact `project.yml` target and scheme you intend to add, with its bundle id and dependencies,
- the list of files you intend to delete outright, and your recommendation on `DevicePreview` (open item O-3),
- your plan for the `RecentsStore` Application Support directory migration (GAP_ANALYSIS G28 — unlike the P0 entitlement keys, that file really was written by local builds),
- anything in the spec you believe is wrong or underspecified.

Then implement it.

---

## Notes for the human (not part of the prompt)

- **U0 is the stage to review most carefully.** It touches every gate in the repository. A gate quietly weakened in U0 is a real invariant lost for the life of the project, and it will not show up in any test result. Ask specifically what each amended gate no longer catches.
- **U1 writes to users' CloudKit records.** If a merge bug ships, it corrupts data that is not on your disk. Consider requiring the self-merge-is-a-no-op property test *first*, before any other merge test — it catches most merge bugs and it is cheap.
- **U5 is where "it compiles and tests pass" is least trustworthy** (GAP_ANALYSIS G21). Ask for a Mac-recorded take with a non-nil `routeClass` as evidence, not a green test run.
- **The four blocking gaps** (G1–G4) are all in U0. If the agent reports U0 done but any gate probe was not re-proven failable, U0 is not done.
- **If you want autonomous multi-stage runs**, replace "Stop after each stage and report" with "Stop after U0, U1, and U5 for review; otherwise continue." Those three are where a wrong turn is expensive to unwind.
- **Two open items need you, not the agent:** O-1 (Pro pricing — D-2's "iPhone-only unlock" rationale is void now that the Mac is back) and O-2 (re-read Apple's current Universal Purchase documentation before submission). Neither blocks any code.
- **`scripts/capture_studio_screenshots.sh`** was deleted in P0 and is recoverable from `c0c6712^` if a Mac screenshot pipeline is wanted again. The spec does not require it.
