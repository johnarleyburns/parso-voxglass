# The Possessed, chapter 57: Cannot Decode at 2:52–2:53

Investigated October 7, 2026 against the connected physical iPhone's installed
Voxglass 1.1.425 (425), its library database, and its actual cached audio.
Screenshots are `~/Downloads/voxglass_decode_fail1.jpg` and
`~/Downloads/voxglass_decode_fail2.jpg` (underscores in the actual filenames).

## Confirmed cause

The phone's library maps chapter 57, “Pt. 3, Ch. 01: The Fête—First Part
(Sec. 1-2a),” to:

https://archive.org/download/possessed_1404_librivox/possessed_57_dostoyevsky_128kb.mp3

Duration is 1232.48 seconds (20:32). The current streaming cache blob is corrupted;
the Archive original and the phone's legacy offline copy are identical and healthy.

| Copy | Bytes | MD5 |
| --- | ---: | --- |
| Fresh Archive original | 19,724,451 | `a03e487ffe48b4d1cc93b7bc8b85894c` |
| Phone legacy OfflineAudio copy | 19,724,451 | `a03e487ffe48b4d1cc93b7bc8b85894c` |
| Phone StreamCacheV2 copy | 19,724,451 | `3bae9ccb2890f6d3024659e8c84f0827` |

Cache key is `a2ab146b82bffdba310e50ee12abfd2c9fc370d8da1856d3b6a829c8e04cdce3-mp3`.
Its StreamCacheV2 metadata claims complete coverage `[0,19724451]` and
`complete: true`. Completeness is a range/length check, not content verification.

Exactly one 32,768-byte span at zero-based offsets `[2785282,2818050)` is wrong.
It contains original-file bytes from `[10354690,10387458)` instead. Of these,
32,610 byte values differ; the rest coincidentally match. This is a misplaced
32 KB audio block, matching the streaming loader's default chunk size. The
nearest original MP3 packet timestamps are about 173.79–175.86 seconds.
Decoder read-ahead explains why playback can fail while the visible playhead
is still 172–173 seconds.

The precise operation that originally misplaced the block cannot be proved
from these persisted files. This investigation establishes cache corruption,
not a defect in the LibriVox recording or proof of a particular network or
concurrency failure. No dependency implementation was changed, and no phone
files were modified.

## Reproduction

Downloaded the original and VBR derivative, checked their MD5 against Archive
metadata, and decoded both completely with FFmpeg and macOS AVAssetReader.
Both pass, including seeks at 170, 172, 173, 174, 175, and 176 seconds.

Copied the actual StreamCacheV2 blob from the physical iPhone using read-only
`devicectl device copy from`, then repeated the same decodes:

- FFmpeg reports invalid MPEG frames, missing headers, and `big_values too big`.
- AVAssetReader fails with `AVFoundationErrorDomain -11821`, “Cannot Decode”.
- Underlying error is `NSOSStatusErrorDomain 1650549857`, FourCC `bada`.
- Starting at 170, 172, 173, 174, or 175 seconds still hits the bad span.
- Starting at 176 seconds (2:56) successfully decodes the following ten seconds.

Apple identifies `AVError.Code.decodeFailed` as a media decoding failure:
https://developer.apple.com/documentation/avfoundation/averror-swift.struct/code/decodefailed

Previously the engine reduced the NSError to its localized message, and the
coordinator immediately paused, persisted the failing position, and displayed
an alert. Restart and Try Again returned to the same cached damaged bytes.

## Recovery change

- Preserve decoder error identity by domain/code, including wrapped errors;
  do not depend on the English string “Cannot Decode”.
- Reload the current chapter one second after the last confirmed position.
  A failed AVPlayerItem must be replaced; seeking the failed item is insufficient.
- Permit three such forward reload attempts. A further decode failure stops
  playback and invokes the existing retryable alert. Network and unrelated
  failures do not skip audio.
- Persist each forward position before loading, so restart retains the recovery
  point. Shared-file chapters retain their absolute chapter offset.
- Keep the attempt budget across successful loads until actual playback advances
  two seconds beyond the attempted position; a load alone cannot prove recovery.
- Show the recovery attempt on the book player and allow Pause to stop it.
  Seeking, selecting, deleting the playing book, and retrying cancel pending work.
- Observe failures after gapless preloaded items become current. Reject stale
  failures from replaced items.

For this specific corruption, the required skip target can be later than 2:53
because the decoder fails ahead of the visible playhead. Recovery is bounded;
it does not promise to bypass damage longer than the three attempts allow.

## Verification

- Full host suite: 1,563 tests across 238 suites passed.
- Final playback suite: 107 tests across 19 suites passed, including 13 decode
  recovery regressions (the final manual-play budget reset case was added after
  the full-suite run).
- iPhone/embedded Watch compile and Mac compile: `BUILD SUCCEEDED`.
- Production guards and `git diff --check`: passed.
- Builds used physical-device SDKs and macOS, with signing disabled for compile
  verification. No simulator was booted, no app was installed, and no phone
  playback or cache state was changed.
