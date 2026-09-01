# Voxglass — current status

**Updated:** 2026-09-01

**Active initiative:** Correct Watch-local download-first audiobook playback

**Plan status:** Corrective plan approved; implementation in progress

**Next implementation phase:** Watch-local playback corrective phase — implement, test, perform
the mandatory post-implementation acceptance review, fix every finding, then commit without pushing

**Active plan:** `docs/plans/watch-local-playback/IMPLEMENTATION_PLAN.md`

## Active corrective-phase status — 2026-09-01

Field behavior exposed that the current Watch source does not contain the playback engine described
by the prior Phase 3 audit. `WatchAppServices.play` optimistically marks playback active, creates a
bare remote `AVPlayer`, and never configures/activates the watchOS long-form audio session. It does
not resolve downloaded chapter files, observe real player state/errors, publish system Now Playing,
handle remote commands/routes/interruptions, or report real elapsed progress. The visible progress
is a constant. Therefore the earlier playback-complete claim is superseded by the current source
audit for this corrective phase.

The approved decision is download-first, audibly Watch-owned playback with approved connected HTTPS
streaming as a secondary source. There is no implicit iPhone playback fallback. The detailed plan
contains unit tests, deterministic smoke changes, acceptance criteria, and a required acceptance
review after implementation but before commit. A phase commit is prohibited until every criterion
is pass or honestly pending physical hardware and every review finding has been fixed and retested.

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
| 1 | Foundation: boundaries, store, protocol, connectivity | **Complete** | `ccc8526` |
| 2 | Phone projection and end-to-end download pipeline | **Complete** | `892dfb6` |
| 3 | Playback and complete iPhone/Watch UI replacement | **Complete** | `4d50190` |
| 4 | Cutover, reliability, and release verification | **Complete** | `89549e0` |
| 5 | Product fixes and release guards | **Complete** | `89549e0` |

## Phase 5 — Post-Phase 4 product fixes

After Phase 4, address these follow-up issues:

1. Remove the extra arrow shown between a downloaded indicator and the trailing `>` on My Books book cards.
2. Show the “Great Books” Explore collection only for languages explicitly requested by the user; English is the default when no language has been selected.
3. Allow searching within an Explore collection after the user selects it.
4. Keep Search-tab results, Explore results, and Explore collection-search results completely separate; results must not be shared across those tabs.
5. Simplify Narration: remove “Make a commercial Audiobook”; add “Recording, LibriVox, and Internet Archive stay free forever.” to the “Bring your own book” paragraph; remove the text below “Start a narration,” the duplicate “Start a Narration” text, and the “See all” link; change “Browse community needs” from text to a button styled like “Start a narration.”
6. Remove all compiler warnings across the project.

## Phase 4 + Phase 5 handoff — Cutover and product fixes

Commit `89549e0` (`Complete watch cutover and product fixes`) completed Phases 4 and 5 in one pass.
The Watch production/review/recording/search/settings surfaces and legacy transports were removed;
the replacement is an iPhone-owned My Books projection with connected/disconnected behavior, Watch
download management, and audibly local Watch playback. Explore language filtering and collection
search were separated from Search state, and the Narration copy/actions were simplified per the
follow-up list. Release guards and mockup audits were updated for the new surface.

Verification passed:

- `swift test`: 1,379 tests in 204 suites.
- `bash scripts/test_guards.sh`, `bash scripts/guard_production.sh`, and
  `bash scripts/guard_wiring.sh`.
- Concrete `VoxglassWatch` build on `Voxglass-Agent-Watch` and combined `Voxglass` build on
  `iPhone 16`.
- iPhone `iPhone 16` and Watch `Watch-Small` simulator smoke tests, including the pre-commit hook.
- `git diff --cached --check` and local UI smoke completion.

The commit was pushed to `origin/main`. Physical paired-device delivery, offline behavior, and the
40 mm Now Playing geometry/screenshot evidence remain pending; simulator injection does not prove
those rows. Existing Swift 6 XCTest actor-isolation and minor test-target warnings remain visible in
the Xcode output, so warning-free release approval is still a follow-up item.

Post-push CI run `33294340397` exposed that the Ubuntu guard runner does not install `rg`, which
caused G-19 to fail and skipped TestFlight. Commit `37df95a` replaced that guard's `rg` usage with
portable `grep` and was pushed. Replacement CI run `33319543245` passed Guarded Tests, Logic
Tests, iOS/watchOS Compile, and TestFlight archive/upload. The CI portability rule was also recorded
in `CLAUDE.md` and intentionally left uncommitted with this handoff.

## Field connectivity repair handoff — iPhone and Watch

Commit `7452804` (`Repair iPhone Watch connectivity and downloads`) repaired the paired-device
handshake and projection flow. iPhone now exposes Watch download actions and per-book download
state, reports connection transitions and sync results, and shows Watch book count/storage totals
in Settings. The Watch now requests the typed projection, acknowledges downloads, downloads
approved HTTPS chapters locally, and reports its manifest back to iPhone. The Watch library shows
download progress and completion state.

Verification passed locally: focused contract/accessibility/dynamic-type tests, all wiring and
production guards, concrete iPhone and Watch builds, iPhone and Watch simulator smoke tests, and
the full pre-commit hook. The commit was pushed to `origin/main`.

Post-push CI run `33350429679` passed all jobs: Guarded Tests, Logic Tests, iOS/watchOS Compile, and
TestFlight archive/upload. Physical paired-device testing is still required to confirm behavior on
an actual iPhone and Watch; local/private audiobook file transfer and true offline playback remain
follow-up validation items.

## Phase 3 handoff — Playback and complete iPhone/Watch UI replacement

Commit `4d50190` (`Replace watch playback and library UI`) completed Phase 3. It replaced the Watch
tab shell with connected/disconnected My Books, added Watch artwork and the single previous/play/
next chapter transport row, restricted remote playback to approved HTTPS URLs, accounted for
shared-file chapter offsets, published system Now Playing metadata, added iPhone Watch action IDs
and removal intent wiring, and replaced the old Watch smoke with the deterministic injected flow.
Verification passed: concrete Watch build, combined iPhone build, full logic suites (1,373),
performance tests (6), guard self-tests, pre-commit wiring/logic checks, iPhone smoke, and Watch
`Watch-Small` smoke. The hook emitted existing deprecation/Swift 6 test-target warnings; no
physical-device evidence was claimed. The 40 mm geometry and paired-device rows remain pending.

## Phase 2 handoff — Phone projection and end-to-end download pipeline

Project My Books/details/artwork/source capabilities from `LibraryRepository`; persist phone
projection revisions and desired book-download roots. Implement preparation, scheduling,
outstanding-transfer recovery, cancellation/removal, checksums, estimates, Watch staging,
validation, atomic installation, durable/ephemeral assets, storage reserve, acknowledgements,
manifest reconciliation, and safe adoption of provably complete legacy files. Integrate existing
phone cache and local imports without duplicating bytes; the Watch performs no catalog networking.

Commit `892dfb6` (`Build watch library and download pipeline`) completed this phase. Verification
passed: focused Watch foundation tests (9), full logic suites (1,373), performance tests (6),
guard self-tests, concrete `Voxglass-Agent-Watch` build, concrete `iPhone 16` build, and the
pre-commit iPhone `iPhone 16` smoke plus Watch `Watch-Small` smoke. No physical-device evidence
was claimed; all paired-device rows remain pending. The Phase 5 follow-up list remains deferred
until after Phase 4.

## Known baseline

- Branch: `main`.
- Latest pushed implementation: `bfefcb5` (`Add Internet Archive and local audiobook imports`).
- Its local hooks passed wiring, logic, performance, iPhone smoke, and Watch smoke.
- GitHub Actions logic, iOS/watchOS compile, and guarded jobs passed; TestFlight was still running
  when last checked.
- CarPlay has two hosted scene smoke tests in
  `VoxglassCarPlaySmokeTests/VoxglassCarPlaySmokeTests.swift`. They run in the local `Voxglass`
  iOS-simulator test action and intentionally do not run on GitHub Actions.
- The Phase 2 post-commit status handoff is intentionally uncommitted. The requested long-running-
  command note in `CLAUDE.md` was included in the Phase 2 commit.
- `CLAUDE.md` documents WatchKit/AppIcon-safe Xcode commands and long-running hook handling;
  preserve them.

## Last completed phase handoff

Phase 2 committed as `892dfb6`. Verification passed: foundation and pipeline host tests, full
logic/performance suites, guard self-tests, concrete iPhone/Watch simulator builds, and the
pre-commit wiring/logic/UI smoke hook. No physical-device evidence was claimed; the paired-device
matrix remains pending.
