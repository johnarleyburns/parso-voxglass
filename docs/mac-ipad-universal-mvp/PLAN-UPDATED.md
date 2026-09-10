# Mac + iPad Universal MVP — status check against the author's current framing

**Purpose of this document.** The author asked (2026-09-07) to "update the macOS plan to our
current flows, especially that we can now construct narrations 100% entirely on iPhone," with
three explicit requirements: (1) the Mac app is universal, no separate purchase; (2) the same
commercial-production purchase gate as iOS applies identically on Mac; (3) everything else stays
free; and the point of the Mac app is making professional-level recording and serious
LibriVox/community-narration workflows *easier*, not making them *possible* — iPhone alone already
suffices end-to-end.

**Finding: the existing plan already says this**, nearly verbatim, and was decided before this
session. This document does not replace `SPEC.md` — it confirms the existing spec against the
author's current framing, flags which older documents are superseded and why, and states what has
and hasn't been built yet. Read `SPEC.md` for anything not restated here; it remains normative.

---

## 1. The existing spec already matches the brief

`SPEC.md` §1.3 ("Why macOS, stated once"):

> A narrator working through a 400-paragraph book performs the same four actions thousands of
> times — record, listen, accept, advance. On a touch screen each is a look-aim-tap. On a keyboard
> each is one key... That is the whole argument for the Mac app... A Mac app that merely mirrors
> the iPhone screens on a bigger canvas would not be worth its maintenance cost.

And §1.2 already states, in a table, that iPhone, iPad, and Mac each "create audio" and are each a
"peer writer" — the full flow works on all three; the Mac is additive (keyboard/footswitch capture,
multi-project library, cross-project review queue, batch export — §8), not gating.

§1.2 also already says, explicitly: *"Still explicitly removed, and not restored by this document:
the iPhone→Mac long-work handoff (N-1)... any screen that presents a Mac as a prerequisite for
anything (gate G-U1)."* And §15.5 bans the literal phrases "Record on Mac", "Continue on Mac",
"Requires a Mac" as a CI gate (G-U1). So the "iPhone can do 100% of narration, Mac is optional
power-user tooling" framing isn't new — it's already the spec's foundational premise, and there's
already a grep gate enforcing it.

**Universal Purchase and gating — §2, already decided:**

- Same bundle id on every platform: `guru.parso.voxglass` (§2.1) — required for Universal Purchase,
  called out as irreversible after first sale.
- One IAP product id shared across the record: `guru.parso.voxglass.narration.pro` (§2.1). Verified
  still current in the shipping code: `Voxglass/Core/Production/License/LicenseTypes.swift:48`.
- Free forever, identically on iPhone/iPad/Mac (§2.2): unlimited projects/chapters/takes/recording
  time, full validation on every destination including retail, LibriVox export, Internet Archive
  export including FLAC masters, personal WAV export, the Mac's own project library / keyboard map
  / cross-project queue, and two-writer sync/conflict resolution.
- Pro, identically gated (§2.3): the same seven `ProFeature` cases (`retailPresets`, `mastering`,
  `m4bExport`, `flacExport` commercial-only, `batchExport`, `commercialMetadata`,
  `validationReportExport`) — verified still current at `LicenseTypes.swift:10`. `LicenseGate` is
  permitted in exactly **six** files total (was three, iOS-only): the export destination picker,
  export runner, and Settings, once per UI platform. Never in recording, review, validation,
  assembly, storage, sync, the library, the keyboard map, or watch code, on any platform — enforced
  by `LicenseGatePlacementTests` (extended in U0, not duplicated).
- §1.4 explicitly forbids a platform-conditional tier: "free on iPhone, Pro on Mac" (or the reverse)
  is banned by name, for the same lane.

This is precisely the model the author just asked for. No changes to §2 are needed.

---

## 2. What's superseded, and why (so nobody builds from the wrong file)

Two document sets predate this decided spec and are **not** current:

- `docs/voxglass-narration/n04-iphone-long-work-mac-handoff.html`, `n05-mac-library-start-narration.html`,
  `n06-mac-needs-browser.html` — their own `<title>` tags read "Studio Library" / "Studio Needs
  Browser," i.e. they're from the deleted `VoxglassStudio` era (removed in commit `c0c6712`,
  "P0 remove the macOS Studio surface"). `n04` in particular is the literal "Mac handoff" premise
  §1.2/§15.5 now explicitly reject. These three files describe a product decision that was made and
  then reversed; treat them as historical record, not a spec to reconcile against.
- `docs/voxglass-mvp/voxglass-macos-view-mockups/` (19 files) — also pre-dates `SPEC.md` and is not
  referenced by it anywhere. `docs/voxglass-mvp/VOXGLASS_STUDIO_SPEC.md`/`VOXGLASS_STUDIO_IMPLEMENTATION_PLAN.md`
  are cited by `SPEC.md` for narrow, still-valid things (destination constants, text pipeline,
  assembly, validation catalogue — see `AGENT_BRIEF.md`'s "inherited documents" note) but not for
  the Mac UI itself.

**The current, normative mockups are the 10 files in `docs/mac-ipad-universal-mvp/mockups/`**
(`mac-01-library.html` through `mac-10-export.html`), mapped file-by-file to owning source in
`SPEC.md` §15.2, plus three iPad-specific mockups (`ipad-01`..`ipad-03`, §15.3). HTML `id`
attributes in these files are the literal `.accessibilityIdentifier` values the implementation must
use (§15.4) — this is a CI-enforced contract once `AccessibilityAuditTests` is extended in U0, not
yet before then.

No action needed on the superseded files beyond this note — deleting or archiving them is a
housekeeping call for the author, not a blocker for anything.

---

## 3. Current build status: not started

Checked directly against the working tree (2026-09-07):

- `VoxglassMac/`, `VoxglassMacTests/`, `VoxglassMacUITests/` exist on disk and are committed —
  resurrected verbatim from `c0c6712^` per `AGENT_BRIEF.md`/D-U5, under new directory names.
- `project.yml` has **no** `VoxglassMac` target, scheme, or reference of any kind — confirmed via
  `grep -n "VoxglassMac" project.yml` (no matches). The tree is exactly as advertised: inert. It
  does not compile, nothing in `Package.swift`/CI touches it, `swift test` does not see it.
- No commit in history mentions stage `U0` through `U9` — the stage plan (§17) has not been
  started.

So: the spec is fully decided and unusually detailed (938 lines, a 41-item gap analysis against the
actual working tree, an implementation agent brief with the exact opening prompt to use), but
**zero implementation stages have landed.** This is a "ready to start," not a "partially done and
drifted," situation.

---

## 4. Open items still requiring the author (unchanged from §19.1 — restated here for visibility)

- **O-1 — Pro pricing.** The prior $49/$79 decision (D-2) was justified by *"an iPhone-only unlock
  skews toward less professional narrators"* — that premise is void now that Mac is back and priced
  the same across all platforms via Universal Purchase. Needs a fresh number before submission; no
  code depends on the answer.
- **O-2 — Universal Purchase mechanics.** Re-verify Apple's current Universal Purchase / macOS-in-
  an-iOS-record documentation at submission time (App Store policy can move; the bundle-id choice
  itself is not expected to change).
- **O-3 — `DevicePreview`.** §5.3 recommends deleting this resurrected surface; confirm during U0.
- **O-4 — Window-per-project vs. single-window-tabs** for the Mac library (§8.4). Ship
  window-per-project with native tabbing first; revisit only if real usage shows people always tab.

None of these block starting U0.

---

## 5. Recommended next step

Nothing in this session's work changes the plan — it confirms the plan already anticipated it.
The concrete next action, when the author is ready, is exactly what `AGENT_BRIEF.md` already
prescribes: hand that file's "The prompt" section to an implementing agent as-is, starting with
stage **U0** (§17) — amend the three CI gates that currently keep the Mac tree deleted, add the
`VoxglassMac` target/scheme to `project.yml` at bundle id `guru.parso.voxglass`, delete the six
files `GAP_ANALYSIS.md` names as not worth adapting, and extend `AccessibilityAuditTests` /
`LicenseGatePlacementTests` to cover it. U0's acceptance bar is explicitly "compiles and gates
pass," not "the Mac app works" — later stages (U1 merge model, U3 app shell, U5 capture, U9
Universal Purchase hardening) build on top of that unlock, one reviewable commit per stage, per the
brief's own stop-and-report discipline.
