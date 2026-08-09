# W-2 — Internet Archive walkthrough (free lane)

> Release gate §16.6, walkthrough 2. Executed on real hardware with a real
> microphone. Like W-1, the IA lane is **free** (R-9): the Internet Archive
> builder must never consult a license gate (gate G-P2), and no purchase prompt
> may appear.

## Setup

- iPhone, real microphone, real voice, public-domain manuscript.
- A destination **identifier** (e.g. `test_collection` dry-run target) and a
  license URL, set in the Metadata & Rights step.

## Steps

1. Create and record a project as in W-1 (steps 1–5).
2. **Metadata & rights** (`metadata.*`): set the IA identifier, license URL, and
   rights attestation. The AI-origin declaration for any imported audio must be
   present (`importAudio.origin.*`).
3. **Validation** (`validation.destination.internetArchive`): run validation.
   Note: a non-human-origin take blocks LibriVox validation but the IA lane has
   **no license check on the path** (gate G-P2).
4. **Export** (`export.destination.internetArchive`): export to Files. **No
   purchase prompt.** The package contains FLAC masters + MP3 derivatives +
   checksums + checklist.
5. Save the package and inspect it in Files.

## Pass criteria

- The IA export produces **FLAC masters + MP3 derivatives**, the metadata and
  license URL, per-file **checksums**, and a complete submission **checklist**
  (mockup 14: `export.*`).
- No `ProFeature`/`LicenseGate` reference exists in the IA builder (gate G-P2 is
  green).
- Everything from tab to saved package is reachable with VoiceOver and Reduce
  Transparency on (M-13/M-14).
- No "Mac" affordance appears anywhere (§15.6).

## Result

Record date / device / mic and attach the export's manifest. Check the box in
`RELEASE_CHECKLIST.md` W-2.
