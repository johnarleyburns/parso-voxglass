# Read by AI watch playback regression investigation

Follow-up: Read by AI watch downloads are now disabled by user request. The app transfer path and speech renderer have been retired; text playback on iPhone remains available. The findings below record the earlier investigation, not the current renderer implementation.

Investigated November 16, 2026 against HEAD `410333b` plus the existing local watch changes. This is a source investigation, not a reproduced or confirmed device diagnosis. No watch playback code was changed for this request.

## Findings

1. **The actual speech-rendering boundary remains untested.** `ReadWithAIWatchNarrationRenderer.writePCM` sends each `AVSpeechSynthesizer.write` callback's `AVAudioBuffer` into a new MainActor task (lines 48–49). The callback returns before the buffer is consumed; there is no owned PCM copy or explicit ordered drain. This is a buffer-lifetime/order risk worth testing first. It is present before the latest fixes, so it cannot by itself establish which recent change triggered the new symptom.
2. **Completion is accepted without evidence of a complete chapter.** The renderer treats any zero-frame callback as success, even if it has written no frames (lines 66–71). There is no speech-failure delegate/timeout, no frame count, and no text-versus-duration sanity check. The AAC validator checks extension, nonzero audio length and codec, but does not decode the entire file or check for audible speech/completeness. A short or silent but structurally valid AAC file can pass and be reused by the cache.
3. **Recent fixes changed conversion and acceptance, not this rendering behavior.** Commit `fbab629` (#297) changed the 48 kbps conversion profile from stereo to mono. Commit `350719d` (#298) added a shared AAC validator before caching/transferring and on watch installation, with rebuilds of invalid cached audio. Commit `7123c25` (#302) moved cache ownership into a managed, versioned cache. These changes can cause a previously accepted malformed artifact to fail preparation/installation instead of playing a fragment. Whether that explains this report needs the actual failure/receipt and artifact; it is not established by the source alone.
4. **The saved end-to-end tests do not synthesize speech or exercise watch audio output.** `WatchNarrationEndToEndTests.RealPCMRenderer` writes a one-second deterministic tone instead of using `ReadWithAIWatchNarrationRenderer`. Those tests cover PCM-to-AAC conversion, integrity, installation and acknowledgement; they cannot establish that a whole book is rendered, that the selected voice supports offline rendering, or that watch playback is audible.
5. **Watch diagnostics can distinguish failure stages.** `WatchSessionAdapter` persists the received/validated/rejected receipt in `watch.audioReceipt`; installation errors become failed acknowledgements. `WatchPlaybackEngine` emits codes for activation failure, item decode failure, never-ready items and stalls. Source inspection alone cannot tell which stage the reported build reaches. Installed files alone are also insufficient: reconciliation checks bytes/hash, not complete audible playback.

## Most useful next verification

On the physical iPhone/Watch running the affected build, transfer one known chapter with the selected voice. Record build numbers, the phone transfer failure/status, the watch audio receipt, and any playback problem-card code. Retain the generated PCM and transferred M4A for this controlled investigation. Compare PCM frame count/duration, AAC decoded duration and audible content, transferred bytes/hash, and a playback test starting at zero as well as from the saved resume point.

The first renderer repair to evaluate is synchronous ownership of callback samples followed by a serialized writer, explicit frame accounting/failure completion, and validation of the produced chapter before caching. Exercise the real selected voice, including cancellation and a multi-minute chapter. Do not regard conversion of a synthetic tone as verification of that repair.

## Verification limitation

This workspace runs Linux with no Xcode, iPhone or Apple Watch access. `swift test` fails in the existing `parso-audio-engine` Cvorbis dependency (`sharedbook.c`: undeclared `alloca`) before project tests execute. Apple speech synthesis, AAC decoding and watch output cannot be verified on this host. No simulator was started.
