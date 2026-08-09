# W-1 — LibriVox walkthrough (free lane)

> Release gate §16.6, walkthrough 1. Executed on real hardware with a real
> microphone. This is the *free* lane: **no purchase prompt may appear at any
> point** (gate G-P2 / §2.2 — the IA and LibriVox lanes are never gated).

## Setup

- iPhone with a USB-C class-compliant interface or a USB mic with hardware gain
  (or built-in mic for the community-ready path).
- Real microphone, real voice; a short public-domain manuscript (e.g. a Project
  Gutenberg `.txt` or a pasted passage).

## Steps

1. **Narration tab** (`tab.narration`) → Start narrating a need, or ＋ → paste /
   import the manuscript. Accept the structure on the source review screen
   (`import.acceptStructure`).
2. **Dashboard** (`dashboard.*`): confirm the project appears, "Record next"
   resolves to paragraph 1, and the storage card shows the on-device take size.
3. **Audio setup** (`audioSetup.*`): open Audio Setup from the recording toolbar
   and confirm the route is classified (`retailReady`/`communityReady`/`draftOnly`).
4. **Record** (`record.transport.record`): record the two LibriVox disclaimer
   paragraphs plus several body paragraphs, using **Accept & Next**
   (`record.acceptAndNext`) and flagging at least one paragraph
   (`record.flagAndNext`).
5. **Review** (`reviewList`/`player.*`): play the queue, approve the good ones,
   pick up the flagged one (`player.pickup`), add a note (`player.addNote`).
   Confirm a flagged paragraph lands back as `needsPickup`.
6. **Validation** (`validateExport`, `validation.destination.librivox`): run
   validation. The report is readable **without any Pro purchase** (validation is
   never gated — hard constraint 5).
7. **Export** (`export.destination.librivox`): export to Files. **No purchase
   prompt.** The destination picker offers LibriVox and Internet Archive freely;
   Retail shows the Pro sheet instead (that is the only gate location).
8. Save the exported package to Files and open it.

## Pass criteria

- The exported MP3s verify as **128 kbps CBR / 44.1 kHz / mono** (run `ffprobe`
  or the transcoder's own MP3 frame parser) with the correct per-chapter names
  and ID3 tags.
- LibriVox disclaimers are recorded as real paragraphs and present in the
  package.
- Validation report reads clean (or lists only issues the user then fixes).
- The whole path from the narration tab to a saved package is reachable with
  VoiceOver and Reduce Transparency on (M-13/M-14), and no "Mac" affordance
  appears anywhere (§15.6).

## Result

Record date / device / mic and attach the export's checksums. Check the box in
`RELEASE_CHECKLIST.md` W-1.
