#!/usr/bin/env python3
"""generate_carplay_cues.py — build the three CarPlay audio-confirmation cues.

Spec §18.3 rule 6: voice confirmations must NOT use speech synthesis
(CI gate G-1 forbids TTS symbols). The three confirmations are instead
distinct pre-recorded earcons bundled as small 16-bit mono WAVs:

  approve.wav   — two rising notes (660 → 880 Hz)   "accepted, move on"
  flag.wav      — two short low bursts (330 Hz)      "kept flagged"
  pickup.wav    — two falling notes (660 → 440 Hz)   "needs re-recording"

Outputs land in Voxglass/Resources/CarPlayCues/ and are committed so the
app bundle needs no build-time audio pipeline. Pure stdlib, no dependencies.

Usage: python3 scripts/generate_carplay_cues.py
"""

import math
import struct
import wave
from pathlib import Path

SAMPLE_RATE = 44_100
AMPLITUDE = 0.15  # ≈ −16.5 dBFS: audible but below the review audio level
FADE = 0.005      # 5 ms fade in/out on every note, so no click or pop
OUT_DIR = Path(__file__).resolve().parent.parent / "Voxglass" / "Resources" / "CarPlayCues"


def render(freqs: list[tuple[float, float, float]]) -> list[float]:
    """Render note runs [(freq, start_s, end_s), ...] into float samples."""
    end = max(end for _, _, end in freqs)
    total = int(end * SAMPLE_RATE)
    samples = [0.0] * total
    for freq, start, stop in freqs:
        s0, s1 = int(start * SAMPLE_RATE), int(stop * SAMPLE_RATE)
        for i in range(s0, s1):
            t = (i - s0) / SAMPLE_RATE
            position = min(max(t / FADE, 0.0), 1.0)
            edge = min(position, max((stop - start - t) / FADE, 0.0))
            samples[i] += AMPLITUDE * min(edge, 1.0) * math.sin(2 * math.pi * freq * t)
    peak = max(1.0, max(abs(s) for s in samples))
    return [s / peak for s in samples]


def write_wav(name: str, samples: list[float]) -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    path = OUT_DIR / f"{name}.wav"
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(b"".join(
            struct.pack("<h", int(max(-1.0, min(1.0, s)) * 32767)) for s in samples
        ))
    print(f"wrote {path} ({len(samples) / SAMPLE_RATE:.2f}s)")


def main() -> None:
    write_wav("approve", render([
        (660, 0.000, 0.090),
        (880, 0.100, 0.190),
    ]))
    write_wav("flag", render([
        (330, 0.000, 0.060),
        (330, 0.075, 0.135),
    ]))
    write_wav("pickup", render([
        (660, 0.000, 0.100),
        (440, 0.110, 0.210),
    ]))


if __name__ == "__main__":
    main()
