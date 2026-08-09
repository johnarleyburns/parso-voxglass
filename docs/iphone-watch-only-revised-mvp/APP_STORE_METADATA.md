# Voxglass — App Store metadata (iPhone + Watch Narration MVP, v1.1)

Prepared for the first iPhone-only submission (§18, §16.6). Fill the bracketed
fields at submission time. Screenshots come from the iPhone simulator using the
local smoke seeds; no real user data is captured.

## App listing

- **Name:** Voxglass
- **Subtitle:** Audiobook player & narration studio
- **Category:** Productivity
- **Price:** Free with in-app purchase (Voxglass Narration Pro, one-time $49
  introductory / $79 standard; set in App Store Connect — decision D-2)

## Description (English)

> Voxglass is an audiobook player that also lets you record your own narration.
> Import an EPUB, DOCX, Markdown, or TXT manuscript and record by paragraph with
> unlimited takes; proof your work from your iPhone, Apple Watch, or CarPlay;
> and produce submission-ready packages for LibriVox and the Internet Archive —
> free, forever.
>
> **Record by paragraph, not by waveform.** Voxglass segments your manuscript
> into recordable paragraphs with stable identities. Record one take per
> paragraph with unlimited retakes, compare takes before choosing, and import
> existing audio. The audio setup screen tells you whether your current
> microphone route is ready for professional retail delivery before you record.
>
> **Proof your book from your wrist.** Flag a paragraph, dictate a note on your
> Watch, and review a queue hands-free. Every review action lands on your iPhone
> exactly once.
>
> **Backed up through your own iCloud.** Recordings and manuscript text live on
> your device and in your private iCloud — there is no Voxglass server and no
> upload anywhere you did not choose.
>
> **Submit with confidence.** Voxglass validates against the actual rules of
> LibriVox, the Internet Archive, and the commercial retailers (ACX/Audible),
> measures loudness, peak, and noise floor against each destination's
> thresholds, and produces a human-readable submission checklist. LibriVox and
> Internet Archive exports are free and unlimited. Professional retail delivery
> (mastered MP3/WAV/FLAC chapter files, chapterized M4B, batch export, and
> exportable validation reports) is part of Voxglass Narration Pro — a one-time
> purchase, no subscription.
>
> Voxglass does not upload your files to retailers and does not determine
> copyright status. You submit the files yourself.

## Keywords

audiobook, narration, narrator, recording, LibriVox, ACX, audio, publishing,
record, listen

## App Store privacy

- **Data not collected.** No analytics SDK, no advertising, no third-party
  network calls.
- Microphone use is explained in-context before the first recording (§18).
- Manuscript text and audio stay on device and in the user's private iCloud
  unless the user exports them; iCloud backup and offload use the user's own
  private CloudKit database.
- Privacy nutrition label: "Data Not Collected" — with microphone-use disclosure
  (`NSMicrophoneUsageDescription`).

## Review notes (for Apple)

- The app records the user's own narration through the microphone.
  `NSMicrophoneUsageDescription` explains that audio stays on the device unless
  the user chooses to export it.
- The app does not upload content to retailers and does not determine copyright
  status. It prepares local export packages the user submits themselves.
- The in-app purchase (Voxglass Narration Pro) unlocks commercial retail export
  formats and mastering; LibriVox and Internet Archive exports are free and
  never gated.
- Restore Purchases is always visible. A refund or revocation returns the app to
  free while preserving user projects.
- Export compliance: `ITSAppUsesNonExemptEncryption: false`.
- Test account / demo: use a seeded narration project; a `.storekit` sandbox
  (`Voxglass/Resources/VoxglassNarration.storekit`) carries the non-consumable
  product for review builds.

## In-app purchase

- **ID:** `guru.parso.voxglass.narration.pro` (decision D-1)
- **Type:** non-consumable, one-time
- **Price:** USD 49 (introductory) / 79 (standard) — decision D-2, set in
  App Store Connect at submission
- **Family Sharing:** enabled
- **Display name:** Voxglass Narration Pro
- **Description:** Unlock professional retail delivery: mastered MP3/WAV/FLAC
  chapter files, chapterized M4B, retail samples, batch export, and exportable
  validation reports. One-time purchase, no subscription.

## Screenshots (6 required)

| # | Screen | Capture via |
|---|---|---|
| 1 | Narration tab | local smoke seed, narration tab |
| 2 | New narration / source import | smoke seed, flow step `.importWork` |
| 3 | Project dashboard | seeded project, dashboard |
| 4 | Recording workspace | seeded project, record |
| 5 | Review queue | seeded flagged queue, review |
| 6 | LibriVox validation | seeded project, validate |

Run the app in the simulator with the production smoke seed and capture the
above surfaces against the design tokens (§15.2). Third-party notices ship in
the app at `Voxglass/Resources/ThirdPartyNotices.md` (LAME LGPL-2.1, libFLAC
BSD-3 — §16.6).
