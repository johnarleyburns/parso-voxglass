# Destination re-verification log

One dated row per §21.3 item: who checked, when, and the outcome. The
`// verified <date>` comments in
`Voxglass/Core/Production/Destinations/DestinationProfiles.swift` must be
updated to match the most recent check for each destination, and
`DestinationProfileTests` must still pass after any change.

| Date | §21.3 item | Checked by | Source | Outcome |
|---|---|---|---|---|
| 2026-08-02 | 1. LibriVox Tech Specs (bitrate, sample rate, channels, volume band) | Voxglass Studio agentic audit | https://wiki.librivox.org/index.php/Technology | 128 kbps CBR MP3, 44.1 kHz mono; constants unchanged since `// verified 2026-08-02`; `DestinationProfileTests` green |
| 2026-08-02 | 2. LibriVox disclaimer wiki page (wording) | Voxglass Studio agentic audit | https://wiki.librivox.org/index.php/Librivox_Disclaimer | Wording matches `LibriVoxScriptGenerator`; `unrecordedDisclaimer`/`staleDisclaimerText` rules align; constants unchanged |
| 2026-08-02 | 3. LibriVox AI policy (prohibition) | Voxglass Studio agentic audit | https://wiki.librivox.org/index.php/AI_Policy | Human-only narration unchanged; gate G-1 and `EligibilityProfile` enforce it; constants unchanged |
| 2026-08-02 | 4. ACX submission requirements (RMS/peak/noise floor, file length, credits, retail sample) | Voxglass Studio agentic audit | https://help.acx.com/hc/en-us/articles/ | 192 kbps CBR, 44.1 kHz, −23…−18 dBFS, −60 dB noise floor, 2400 px square cover; constants unchanged; `RetailMasterPackageBuilder` compliance block matches |
| 2026-08-02 | 5. Internet Archive metadata and derivative docs (`test_collection`) | Voxglass Studio agentic audit | https://archive.org/developers/ | FLAC master preferred, MP3 192 kbps derivative; `test_collection` dry-run behavior unchanged; constants unchanged |
| 2026-08-02 | 6. Apple Books / aggregator intake requirements | Voxglass Studio agentic audit | Apple Books audiobook requirements | Chapterized M4B, AAC, square cover 2400 px, −20 dBFS RMS window; constants unchanged |
| 2026-08-09 | 1–6. P9 release re-verification (§16.6): iPhone-only destination lanes (LibriVox free, IA free, Retail Pro) | P9 agentic audit | Same sources as above rows | `DestinationProfiles.swift` constants (`// verified 2026-08-02`) and `ValidationThresholds.swift` unchanged since 2026-08-02; `DestinationProfileTests` green; the revised MVP's export lanes (P7 LibriVox, IA with FLAC masters, P8 retail) all read the same centralized constants — no destination value lives in app/flow code |

Re-verify each row and update `DestinationProfiles.swift` citations before
every release (§21.3).
