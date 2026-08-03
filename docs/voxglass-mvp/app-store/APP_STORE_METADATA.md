# Voxglass Studio — App Store metadata (macOS, v1.0)

Prepared for the first submission (spec §21.2). Fill the bracketed fields at
submission time. Screenshots are produced by
`scripts/capture_studio_screenshots.sh` (seeded sessions, no real data).

## App listing

- **Name:** Voxglass Studio
- **Subtitle:** Audiobook production for solo narrators
- **Category:** Productivity
- **Price:** Free with in-app purchase (Voxglass Studio Pro, one-time $149)

## Description (English)

> Voxglass Studio turns your manuscript into a submission-ready audiobook —
> recorded, proofed, and validated against the destinations' own requirements —
> without leaving your Mac.
>
> **Record by paragraph, not by waveform.** Import an EPUB, DOCX, Markdown, or
> TXT manuscript; Voxglass segments it into recordable paragraphs with stable
> identities. Record one take per paragraph with unlimited retakes, and compare
> takes before choosing. Trims, gain, and fades are non-destructive
> instructions — your original recording is never altered.
>
> **Proof your book away from the desk.** Accepted takes are compressed and
> projected to your iPhone, Apple Watch, and CarPlay through iCloud. Flag a
> paragraph on your phone while walking, dictate a note on your watch, or
> review a queue hands-free in the car. Every review action lands back on the
> Mac, exactly once.
>
> **Submit with confidence.** Voxglass encodes the actual rules of LibriVox,
> the Internet Archive, and the commercial retailers (ACX/Audible and
> Apple Books). It measures loudness, peak, noise floor, and structure against
> each destination's thresholds, writes the correct ID3 tags, generates the
> LibriVox disclaimers as paragraphs you simply record, and produces a
> human-readable submission checklist.
>
> **Free, forever, for the free lanes.** Creating, importing, recording,
> reviewing, validating, and exporting LibriVox and Internet Archive packages
> are complete and unlimited with no purchase. Commercial retail delivery is
> part of Voxglass Studio Pro — a one-time purchase, no subscription.
>
> Voxglass does not upload anywhere. You submit the files yourself.
> Voxglass does not determine copyright status.

## Keywords

audiobook, narration, narrator, ACX, LibriVox, recording, audiobook studio,
publishing

## App Store privacy

- **Data not collected.** No analytics SDK, no advertising, no third-party
  network calls.
- Audio recordings and manuscript text stay in the user's iCloud private
  database (and on the Mac) and are never sent anywhere by the app.
- Privacy nutrition label: "Data Not Collected."

## Review notes (for Apple)

- The app records the user's own narration through the microphone.
  `NSMicrophoneUsageDescription` explains that audio stays on the Mac unless
  the user chooses to preview it on their devices.
- The app never uploads content; all distribution packages are prepared
  locally for the user to submit themselves.
- The $149 non-consumable in-app purchase unlocks professional retail export
  formats (ACX/Audible, Apple Books, FLAC masters, batch export, validation
  report export). Everything required for LibriVox and Internet Archive
  contribution is free.
- A demo project (`.voxproject`) is included in the review notes.
- Export compliance: `ITSAppUsesNonExemptEncryption: false`.

## In-app purchase

- **ID:** `guru.parso.voxglass.studio.pro`
- **Type:** non-consumable, one-time
- **Price:** USD 149
- **Family Sharing:** enabled
- **Display name:** Voxglass Studio Pro
- **Description:** Unlock commercial retail delivery: ACX/Audible and Apple
  Books profiles, the mastering chain, chapterized M4B, FLAC masters, batch
  export, commercial metadata, and exportable validation reports.

## Screenshots (6 required)

| # | Screen | Capture via |
|---|---|---|
| 1 | Library | seed `empty`, library view |
| 2 | New Project wizard | seed `empty`, wizard |
| 3 | Source Import | seed `empty` + bundled fixture `.txt` |
| 4 | Dashboard | seed `librivoxReady`, dashboard |
| 5 | Recording workspace | seed `librivoxReady`, record |
| 6 | Validation report | seed `librivoxReady`, validate |

Run `scripts/capture_studio_screenshots.sh` and review the output against
`docs/voxglass-mvp/voxglass-macos-view-mockups`.
