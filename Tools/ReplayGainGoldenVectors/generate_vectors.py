#!/usr/bin/env python3
"""Generate the ReplayGain golden-vector fixtures for VoxglassTests.

Produces:
  - VoxglassTests/Fixtures/ReplayGain/<name>.wav   (48 kHz, 16-bit, mono)
  - VoxglassTests/Fixtures/ReplayGain/expected.json (expected replayGainDB per file)

CI must not need flac/metaflac: the WAVs and the JSON are committed. Re-run this
script only when the fixture set changes.

Reference values come from the independent RG 1.0 transcription below
(direct-form II transposed Yule + Butterworth stages, 50 ms blocks, 95th
percentile, gain = -25.4885 - L95), NOT from metaflac: modern metaflac/flac
(>= 1.4) compute RG 2.0 against a -18 LUFS reference, which differs from RG 1.0
by ~2-3 dB on these signals. The transcription was validated against the
metaflac-measured anchors in docs/voxglass-mvp/S5-REMEDIATION-PLAN.md
(1 kHz -20 dBFS -> +2.83 dB, 100 Hz -20 dBFS -> +9.88 dB).

All signals are deterministic (fixed-seed LCG), so the fixtures are reproducible.
"""

import json
import math
import os
import struct
import subprocess
import sys
import tempfile
import wave

SAMPLE_RATE = 48000
DURATION = 8.0
N = int(SAMPLE_RATE * DURATION)

OUT_DIR = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "..", "VoxglassTests", "Fixtures", "ReplayGain",
)

A = 6_364_136_223_846_793_005
C = 1_442_695_040_888_963_407
MASK = (1 << 64) - 1


class LCG:
    def __init__(self, seed: int) -> None:
        self.state = seed & MASK

    def next_u64(self) -> int:
        self.state = (self.state * A + C) & MASK
        return self.state

    def next_double(self) -> float:
        return (self.next_u64() >> 11) * (1.0 / (1 << 53))

    def next_float32(self) -> float:
        # Uniform in [-1, 1].
        return self.next_double() * 2.0 - 1.0


def white_noise(seed: int, n: int) -> list[float]:
    rng = LCG(seed)
    return [rng.next_float32() for _ in range(n)]


def pink_noise(seed: int, n: int) -> list[float]:
    """Voss-McCartney pink noise with a fixed-seed LCG (deterministic)."""
    rng = LCG(seed)
    rows = [rng.next_float32() for _ in range(16)]
    out = []
    for i in range(n):
        rows[i & 15] = rng.next_float32()
        out.append(sum(rows) / 16.0)
    return out


def normalize_rms(samples: list[float], target_db: float) -> list[float]:
    """Scale so the RMS equals 10^(target_db/20) (unit scale, 1.0 = full scale)."""
    sum_sq = sum(s * s for s in samples)
    rms = math.sqrt(sum_sq / len(samples))
    if rms <= 0:
        raise ValueError("cannot normalize silence")
    target = 10.0 ** (target_db / 20.0)
    gain = target / rms
    return [max(-1.0, min(1.0, s * gain)) for s in samples]


def tone(freq: float, amp: float, n: int = N) -> list[float]:
    return [amp * math.sin(2.0 * math.pi * freq * i / SAMPLE_RATE) for i in range(n)]


def sixty_percent_silence() -> list[float]:
    # 60 % silence (leading), 40 % 1 kHz tone.
    silence_n = int(N * 0.6)
    tone_n = N - silence_n
    s = [0.0] * silence_n
    s.extend(tone(1000.0, 10.0 ** (-20.0 / 20.0), tone_n))
    return s


def write_wav(path: str, samples: list[float]) -> None:
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        frames = b"".join(
            struct.pack("<h", int(max(-1.0, min(1.0, s)) * 32767)) for s in samples
        )
        w.writeframes(frames)


YULE_48K_B = [
    0.03857599435200, -0.02160367184185, -0.00123395316851, -0.00009291677959,
    -0.01655260341619,  0.02161526843274, -0.02074045215285,  0.00594298065125,
     0.00306428023191,  0.00012025322027,  0.00288463683916,
]
YULE_48K_A = [
    1.00000000000000, -3.84664617118067,  7.81501653005538, -11.34170355132042,
   13.05504219327545, -12.28759895145294,  9.48293806319790,  -5.87257861775999,
    2.75465861874613,  -0.86984376593551,  0.13919314567432,
]
BUTTER_48K_B = [0.98621192462708, -1.97242384925416, 0.98621192462708]
BUTTER_48K_A = [1.00000000000000, -1.97223372919527, 0.97261396931306]


class DirectFormII:
    """Direct-form II transposed section (RG 1.0 Yule stage and Butterworth)."""

    def __init__(self, b: list[float], a: list[float]) -> None:
        self.b = b
        self.a = a
        self.v = [0.0] * (len(b) - 1)

    def process(self, x: float) -> float:
        y = self.b[0] * x + self.v[0]
        n = len(self.v)
        for k in range(n - 1):
            self.v[k] = self.b[k + 1] * x - self.a[k + 1] * y + self.v[k + 1]
        self.v[n - 1] = self.b[n] * x - self.a[n] * y
        return y


def replay_gain_1_0(samples: list[float], sample_rate: int = 48000) -> float:
    """RG 1.0 track gain in dB (89 dB reference, unit-scale samples)."""
    if not samples:
        return 0.0
    yule = DirectFormII(YULE_48K_B, YULE_48K_A)
    butter = DirectFormII(BUTTER_48K_B, BUTTER_48K_A)
    block_size = int(sample_rate * 0.05)
    loudness = []
    for start in range(0, len(samples) - block_size + 1, block_size):
        sum_sq = 0.0
        for i in range(start, start + block_size):
            s = yule.process(samples[i])
            t = butter.process(s)
            sum_sq += t * t
        ms = sum_sq / block_size
        loudness.append(10.0 * math.log10(ms + 1e-37))
    loudness.sort()
    idx = min(int(math.ceil(len(loudness) * 0.95)) - 1, len(loudness) - 1)
    return -25.4885 - loudness[idx]


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)

    fixtures = {
        "pink-14dbfs": normalize_rms(pink_noise(11, N), -14.0),
        "pink-20dbfs": normalize_rms(pink_noise(22, N), -20.0),
        "pink-26dbfs": normalize_rms(pink_noise(33, N), -26.0),
        "tone-1khz-20dbfs": tone(1000.0, 10.0 ** (-20.0 / 20.0)),
        "tone-100hz-20dbfs": tone(100.0, 10.0 ** (-20.0 / 20.0)),
        "sixty-percent-silence": sixty_percent_silence(),
    }

    expected = {}
    for name, samples in fixtures.items():
        wav_path = os.path.join(OUT_DIR, name + ".wav")
        write_wav(wav_path, samples)
        expected[name] = round(replay_gain_1_0(samples), 3)
        print(f"{name}: {expected[name]:+.3f} dB")

    with open(os.path.join(OUT_DIR, "expected.json"), "w") as f:
        json.dump(expected, f, indent=2, sort_keys=True)
        f.write("\n")
    print(f"wrote {len(fixtures)} fixtures to {OUT_DIR}")


if __name__ == "__main__":
    sys.exit(main())
