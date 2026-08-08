# Agent brief — implement the iPhone + Watch Narration MVP

Paste the block below as the opening prompt for a coding agent working in `/Users/arley/github/parso-voxglass`.

---

## The prompt

You are implementing a specified feature in an existing Swift/SwiftUI repository. The specification is complete and decided; your job is to build it, stage by stage, without re-deriving decisions.

### Source of truth

**`docs/iphone-watch-only-revised-mvp/SPEC.md` is normative.** Read it in this order before writing any code:

1. **§0.4–§0.6** — three corrections tables (R-, M-, N-series). These are the *only* places a decision changes. Everything else is either inherited or new detail.
2. **§1–§2** — product definition and the free/Pro boundary. Getting the boundary wrong leaks `isPro` checks into recording and review code that must stay free forever.
3. **§4.3** — the single project model decision. This is the pivotal change and the largest single piece of work.
4. **§5** — implementation status inventory. **Read this before creating any file.** Most of what you need already exists; the table names the real files and marks each ✅ as-is / 🔧 rework / 🆕 new.
5. **§17** — the stage plan, P0 through P9.
6. **§19** — decisions already taken (D-1…D-5). Do not reopen them.

Consult §6–§16 as reference while implementing a stage. They are normative specification, not narrative.

Two inherited documents are cited by the spec and must **not** be re-derived or duplicated:

- `docs/voxglass-mvp/VOXGLASS_STUDIO_SPEC.md` — destination constants (§3), text pipeline (§9–10), assembly (§12), validation catalogue (§15). Cite section numbers; import the constants from `Voxglass/Core/Production/Destinations/`.
- `docs/voxglass-narration/NARRATION_NEEDS_SPEC.md` — the discovery ladder, unchanged (spec N-4).

Mockups are the visual contract: `docs/iphone-watch-only-revised-mvp/mockups/index.html`. HTML `id` attributes are the `.accessibilityIdentifier` values you must use — identifiers already shipping are preserved deliberately because the UI smoke tests key on them.

### Working method

**One stage per commit.** Imperative subject; body names the acceptance criterion the stage satisfies. **Stop after each stage and report** — do not chain P0 → P9 in one run. Start with **P0**; it is first for a reason (a shipping test imports the module being deleted).

For each stage: read the §5 inventory rows it touches → read the existing code → make the change → run the gates → commit → report what passed and what you chose.

If a stage's acceptance test cannot pass, **stop and report**. Do not weaken the test, do not mark the stage done, do not proceed to the next one.

If the spec and the repository disagree on a *fact* (a file path, a type name, an existing behavior), the **repository wins** — report the discrepancy in your stage report. If they disagree on *intent*, the **spec wins**. Never silently pick one.

### Verifying your work

```
swift test                        # Core suites — this is what CI runs
scripts/test_logic.sh             # Core + performance budgets
scripts/guard_production.sh       # CI grep gates
scripts/test_guards.sh            # proves each gate can fail — every new gate needs an entry here
scripts/test.sh --all             # UI smoke tests: LOCAL pre-commit gate only
```

**CI runs no simulator** (`.github/workflows/ios.yml` is Linux: `swift test` plus grep gates). The simulator suite is a local pre-commit gate. Do not add anything to CI that needs a simulator.

Watch UI test gotchas that have already cost this repo time: row taps need `.contentShape`; sheets are **not** `NavigationPath` destinations; the simulator must be pre-booted; build first then `test-without-building`; seeders must be idempotent.

### Repository conventions (non-negotiable)

- **XcodeGen** from `project.yml`. Never hand-edit `Voxglass.xcodeproj`. Run `xcodegen generate` after changing `project.yml`.
- **No GRDB.** Persistence is a hand-rolled `actor` over SQLite3 in the `AppDatabase` style, with integer-numbered append-only migrations.
- **`@Observable` only.** `ObservableObject` is banned in new code and fails a CI gate.
- **`Date()` / `UUID()` only through the `Clock` / `IDGenerator` seams** in `Voxglass/Core/Production/Domain/`.
- Core code goes in `Voxglass/Core/Production/<Area>/`; iPhone UI in `Voxglass/Features/Production/`; watch in `VoxglassWatch/Production/`. **Never create `…/ProductionStudio`** (spec R-2).
- Core stays free of CloudKit and StoreKit — concretes live in app targets behind protocol seams. The watch must never link CloudKit.
- 4-space indent, `///` on every `public` symbol, no force-unwraps outside tests, `// MARK: -` in files over ~150 lines.
- New Core tests go in `VoxglassTests/Production/`.

### Hard constraints — violating any of these is a failed stage

1. **Never lose a take.** The write ordering in §9.4 is MUST-ordered: bytes durable *before* metadata mutation. Recovery must survive force-quit, interruption, route change, and disk pressure (§7.4).
2. **Never evict before verified.** No original recording may be removed locally until its iCloud copy is SHA-256-verified *and* the remote asset id is persisted (§6.1). Call `ProductionAssetRecord.isEvictable`; never re-derive the condition.
3. **`LicenseGate` appears in exactly three places** — the export destination picker, the export runner, and Settings (§2.2). Never in recording, review, validation, assembly, storage, or watch code. The Internet Archive builder must never consult it (gate G-P2).
4. **Do not degrade listening.** The consumer player, downloads, CarPlay, and playback-position sync are out of scope and must not regress. Losing a user's playback position is a hard product failure.
5. **Validation is never gated.** A free user must be able to run and read a full ACX report.

### The working tree right now

There are **pre-existing staged changes you did not make**. Do not revert them.

- `Voxglass/Core/Production/CloudAssets/` (new) and doc-comment re-pointing across `Sync/` and `WatchLink/` — this is the start of P1. Fold it into P1's commit.
- `Voxglass/Core/Playback/PlaybackCoordinator.swift` and `VoxglassTests/PlaybackPresentationTests.swift` — unrelated consumer-playback work in flight. **Leave them alone entirely.**

Because of this, **stage your files explicitly by path. Never use `git commit -a` or `git add -A`.** P0 touches a disjoint set of files from the staged work, so a careful P0 commit is clean.

Do not push, and do not open a PR, unless asked.

### Start here

Begin with **P0 — Remove the macOS Studio surface and rename Pro** (§17). Before editing, reply with:

- your reading of what P0 deletes and what it repairs,
- the exact `project.yml` targets you intend to remove,
- how you plan to handle `VoxglassTests/Performance/PerformanceBudgetTests.swift`, which does `@testable import VoxglassStudioKit`,
- anything in the spec you believe is wrong or underspecified.

Then implement it.

---

## Notes for the human (not part of the prompt)

- **`scripts/capture_studio_screenshots.sh`** drives the macOS Studio app and becomes dead in P0. The spec doesn't mention it; expect the agent to surface it, or tell it up front to delete the script and the `RELEASE_CHECKLIST.md` line that references it.
- **P2 is the risky stage** — the single-project-model migration. It rewrites where the shipping Narration flow stores everything, and it deletes user-visible data paths (`Application Support/Voxglass/Narrations/`). Review that one closely; consider having the agent land the migration + tests in one commit and the `NarrationProjectStore` deletion in a second, so a revert is cheap.
- **If you want autonomous multi-stage runs**, replace "Stop after each stage and report" with "Stop after P0, P2, and P8 for review; otherwise continue." Those three are the ones where a wrong turn is expensive to unwind.
- The brief deliberately does **not** restate the spec. If an agent starts inventing structure it already has, the fix is to point it back at §5, not to enlarge this prompt.
