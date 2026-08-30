# Voxglass — current status

**Updated:** 2026-08-29

**Active initiative:** Apple Watch iPhone-owned library rearchitecture

**Plan status:** Phase 0 proposal complete; owner approval required before implementation

**Next implementation phase:** Phase 1 — Foundation: boundaries, store, protocol, and connectivity

## Session command

When the owner says **“read current_status.md and proceed”**, perform exactly one phase: the
phase named under **Next implementation phase** above.

Do not restart research, redesign the approved contract, combine phases, or begin the next phase.
If Phase 0 has not been approved, review the plan and ask for approval without changing production
code.

## Required reading, in order

1. `current_status.md`.
2. `CLAUDE.md` for repository commands, safe Xcode destinations, and hooks.
3. `docs/plans/watch-rearchitecture/IMPLEMENTATION_PLAN.md` in full.
4. `docs/plans/watch-rearchitecture/ACCEPTANCE_MATRIX.md` in full.
5. `docs/plans/watch-rearchitecture/mockups/index.html` and every state.
6. The active phase's relevant source and tests.

`../parso-tonearm/docs/plans/watch-rearchitecture/` is implementation precedent, not a second
specification. The Voxglass plan wins where the products differ.

## Non-negotiable contract

- The iPhone is the sole CloudKit client and authoritative owner of My Books, metadata, artwork,
  source resolution, and desired Watch downloads.
- The Watch has no CloudKit connectivity, entitlement, container identifier, catalog search,
  production/review, dictation, recording, or library mutation.
- Connected mode shows all projected My Books and permits Watch playback and download management.
- Disconnected mode shows and plays only complete, validated local downloads.
- WatchConnectivity is not an audio stream. Public chapters may use a phone-approved,
  credential-free HTTPS URL; phone-local/private audio uses just-in-time chapter transfer.
- Ephemeral/JIT audio never marks a book Downloaded or exposes it disconnected.
- The iPhone owns desired download state; the Watch owns installed truth. `Downloaded`/`On Watch`
  appears only after a complete Watch manifest acknowledgement.
- Playback is audibly owned by Apple Watch; Watch controls never secretly control iPhone playback.
- Watch Now Playing always exposes previous chapter, play/pause, and next chapter together; the
  chapter controls move exactly one chapter and are not time-skip controls.
- The primary Now Playing transport row must fit without clipping, overlap, or scrolling on a
  40 mm Apple Watch SE with 44×44-point targets; the normal smoke also runs on `Watch-Small`.
- Archive.org and local folder/ZIP/shared-file imports preserve chapter IDs, order, offsets, and
  offline behavior.

## Per-session execution contract

For the active phase:

1. Inspect the working tree and preserve unrelated changes.
2. Restate the phase scope and implement every deliverable, test, and guard assigned to it.
3. Do not implement future phases merely because their code is nearby.
4. Run phase acceptance rows and proportionate regression checks.
5. Use concrete iPhone and Watch simulator destinations from `CLAUDE.md`. Never force the combined
   scheme through `-sdk iphonesimulator` or a generic simulator destination.
6. Run `git diff --check`, inspect the final diff, and stage no unrelated files.
7. Commit the completed phase on `main`; allow at least 25 minutes for the pre-commit hook.
8. **Do not push.** Never run `git push` unless the owner explicitly asks in that session.
9. After the commit, update this file with the hash, exact checks/results, physical-device work,
   discoveries, and next phase.
10. Leave that post-commit `current_status.md` update uncommitted for the next session.
11. Stop and report the commit plus the fact that it was not pushed.

If blocked, do not make a partial “phase complete” commit. Record the exact blocker and evidence in
this file and leave **Next implementation phase** unchanged.

## Git and evidence policy

- Work on `main`; one completed phase equals one commit.
- Never bypass hooks without explicit owner authorization.
- Never push automatically.
- Include main-plan Implementation Audit updates in the phase commit.
- Update this status file after that commit and leave the status update uncommitted.
- Physical-device rows remain pending until run on paired hardware.
- Injected simulator transport proves UI/state wiring, not real WCSession delivery.
- Existing CarPlay smoke coverage is a hosted iOS-simulator integration test, not dashboard
  XCUITest. Keep it green; do not claim it proves real CarPlay hardware interaction.
- Any phase touching Watch Now Playing must run the 40 mm screenshot/frame geometry gate and verify
  previous/next chapter behavior in addition to the normal Watch smoke.

## Phase ledger

| Phase | Scope | Status | Commit |
|---|---|---|---|
| 0 | Contract, plan, acceptance matrix, mockups | **Complete — awaiting owner approval** | — |
| 1 | Foundation: boundaries, store, protocol, connectivity | **Next after approval** | — |
| 2 | Phone projection and end-to-end download pipeline | Not started | — |
| 3 | Playback and complete iPhone/Watch UI replacement | Not started | — |
| 4 | Cutover, reliability, and release verification | Not started | — |

## Active phase: Phase 1 — Foundation: boundaries, store, protocol, and connectivity

Do not begin until the owner approves Phase 0.

### Goal

Build the complete non-UI foundation while preserving shipped Watch behavior behind an explicitly
temporary legacy path. This phase does not implement the new download pipeline, playback, or UI.

### Deliverables

- Foundation-only Watch protocol boundary for stable IDs, DTO placeholders, protocol version and
  capabilities, transport abstractions, and pure connection/download state.
- Watch core boundary that imports no CloudKit, GRDB, WatchConnectivity, AVFoundation, catalog
  client, credential provider, or SwiftUI.
- Exactly one Watch-side `WCSession.delegate` owner and one iPhone-side owner/router; existing
  relays are isolated behind adapters.
- In-memory fake duplex transport supporting request/reply, context, user-info, file events,
  duplicates, delay, reordering, reachability, and injected failure.
- Dependency/source/entitlement guards for CloudKit, production/review, catalog, and credentials.
- Existing Watch UI remains compiling through a clearly temporary legacy assembly/flag.
- CloudKit-disabled Watch schema, repositories, bootstrap/recovery, file scan, quarantine, and
  provably safe legacy-file adoption.
- Typed envelope/channels, revisions, message ledger, paired-library identity, timeouts, debounced
  connection reducer, application-context ingestion, and reconciliation.
- Protocol, persistence, recovery, architecture-boundary, and fault-injection tests.
- Main plan Implementation Audit records the actual target/product layout.

### Acceptance focus

- `A-01` through `A-06` where structurally applicable.
- Protocol primitive round trips and fake-duplex fault controls.
- iOS app and concrete Watch simulator builds.
- Existing logic, wiring, iPhone/Watch smoke, and hosted CarPlay smoke remain green.
- No simulator result is represented as physical WatchConnectivity proof.

### Commit and handoff

Commit subject: `Build watch foundation and connectivity`

After the commit, mark Phase 1 complete here with its hash and verification, change **Next
implementation phase** to `Phase 2 — Phone projection and end-to-end download pipeline`, replace this Active phase section
with Phase 2's exact instructions from the main plan, leave the status edit uncommitted, and stop
without pushing.

## Known baseline

- Branch: `main`.
- Latest pushed implementation: `bfefcb5` (`Add Internet Archive and local audiobook imports`).
- Its local hooks passed wiring, logic, performance, iPhone smoke, and Watch smoke.
- GitHub Actions logic, iOS/watchOS compile, and guarded jobs passed; TestFlight was still running
  when last checked.
- CarPlay has two hosted scene smoke tests in
  `VoxglassCarPlaySmokeTests/VoxglassCarPlaySmokeTests.swift`. They run in the local `Voxglass`
  iOS-simulator test action and intentionally do not run on GitHub Actions.
- The rearchitecture documents and this status rewrite are uncommitted pending owner review.
- `CLAUDE.md` already documents WatchKit/AppIcon-safe Xcode commands; preserve them.

## Last completed phase handoff

Phase 0 produced the implementation plan, acceptance matrix, and interactive HTML mockups. No
production source changed. The owner must explicitly approve those artifacts before Phase 1.
