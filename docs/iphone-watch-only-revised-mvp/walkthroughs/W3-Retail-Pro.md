# W-3 — Retail (Pro) walkthrough

> Release gate §16.6, walkthrough 3. Executed on real hardware with a real
> microphone. This is the **Pro** lane (§2.2): retail delivery unlocks through
> the Voxglass Narration Pro non-consumable purchase. The retail destination is
> gated in exactly three places — the export destination picker, the export
> runner, and Settings (hard constraint 3).

## Setup

- iPhone with a retail-ready route (USB interface), real microphone, real voice,
  public-domain manuscript (or a fixture).
- The StoreKit sandbox `.storekit` (`Voxglass/Resources/VoxglassNarration.storekit`,
  product `guru.parso.voxglass.narration.pro`) enabled for the scheme.

## Steps

1. Create and record a project with a retail profile (ACX) selected.
2. **Audio setup** (`audioSetup.*`): confirm the route classifies `retailReady`
   with no warnings; on a draft-only route the retail export shows a
   blocking-strength warning (§7.1) but LibriVox/IA remain unaffected.
3. **Validation** (`validation.*`): deliberately leave one take hot/clipped so
   the report flags peak/RMS; the four iPhone issue codes and their fix actions
   are shown (§12.2).
4. **Pro purchase** (`pro.purchase`/`pro.restore`): tap the locked **Retail**
   destination in the picker → the Pro sheet appears (`14c`). Purchase in
   sandbox. Entitlement returns after reinstall (Restore Purchases);
   a revocation reverts to free **while preserving user projects** (M-12).
5. **Export** (`export.destination.retail`): run the retail export. The runner
   hydrates remote-only chapters (SHA-verified), resumes after an interruption,
   and applies the mastering chain. Export the validation report alongside.
6. Open the M4B in a player: chapter marks are playable, the retail sample is
   the correct duration and is not the credits.

## Pass criteria

- The exported files verify against an external ACX-style checker:
  RMS ∈ [−23, −18] dBFS, true peak ≤ −3 dBFS, noise floor ≤ −60 dBFS (M-11),
  at 192 kbps CBR / 44.1 kHz.
- Mastering produces the mastered MP3/WAV/FLAC chapter files, the chapterized
  M4B, the retail sample, and the exportable validation report (P8 acceptance).
- Purchase and restore work; projects survive a revocation (M-12).
- The `LicenseGate` appears only in the destination picker, the export runner,
  and Settings — never in recording/review/validation/storage (gate G-2).
- Everything is reachable with VoiceOver and Reduce Transparency on (M-13/M-14).

## Result

Record date / device / mic and attach the external checker's agreement. Check
the box in `RELEASE_CHECKLIST.md` W-3.
