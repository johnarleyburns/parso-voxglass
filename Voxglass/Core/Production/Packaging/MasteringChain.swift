import Foundation

// MARK: - MasteringTarget

/// What the mastering chain aims for (§16.7). Values come from the
/// destination profile (`LoudnessRule.rmsWindow.targetDBFS`, `peakCeilingDBFS`,
/// `headroomSilence`) — the chain never hardcodes destination numbers, so the
/// "make it pass ACX" button is exactly as strict as the profile says it is.
public struct MasteringTarget: Sendable, Equatable {
    /// Speech-only RMS target in dBFS (ACX: −20).
    public var targetRMSDBFS: Double
    /// True-peak ceiling in dBFS. The limiter works 0.5 dB inside this ceiling
    /// because lossy encoding can raise inter-sample peaks above the PCM peak
    /// (ACX: −3.0 → limiter ceiling −3.5).
    public var peakCeilingDBFS: Double
    /// Target head room-tone length in seconds.
    public var headSeconds: TimeInterval
    /// Target tail room-tone length in seconds.
    public var tailSeconds: TimeInterval

    public init(
        targetRMSDBFS: Double,
        peakCeilingDBFS: Double,
        headSeconds: TimeInterval = 0.75,
        tailSeconds: TimeInterval = 2.0
    ) {
        self.targetRMSDBFS = targetRMSDBFS
        self.peakCeilingDBFS = peakCeilingDBFS
        self.headSeconds = headSeconds
        self.tailSeconds = tailSeconds
    }
}

// MARK: - MasteringResult

public struct MasteringResult: Sendable, Equatable {
    public var samples: [Float]
    public var sampleRate: Double
    /// The static gain (dB) applied by RMS normalization (0 if no gain needed).
    public var appliedGainDB: Double
    public var truePeakDBFS: Double
    public var rmsDBFS: Double
}

// MARK: - MasteringChain

/// The deterministic, documented mastering chain (§16.7). Applied only for
/// retail destinations and only when `ExportOptions.applyMastering` is on.
///
/// Order of operations on the assembled chapter master (float PCM):
/// DC removal → 80 Hz high-pass → room-tone normalization → speech-only RMS
/// normalization → true-peak lookahead limiting (ceiling −0.5 dB inside the
/// profile) → re-measure. Dither is a separate helper applied by PCM writers
/// when reducing bit depth.
public enum MasteringChain {

    /// The limiter works this far inside the profile's true-peak ceiling.
    public static let limiterHeadroomDB: Double = 0.5

    /// Speech/gap boundary: samples quieter than this (linear) are "gap".
    private static let speechFloorLinear: Float = 0.003_162 // ≈ −50 dBFS

    /// Run the full chain. `target` is derived from the destination profile.
    public static func master(samples input: [Float], sampleRate: Double, target: MasteringTarget) -> MasteringResult {
        var samples = input
        guard !samples.isEmpty, sampleRate > 0 else {
            return MasteringResult(samples: input, sampleRate: sampleRate, appliedGainDB: 0, truePeakDBFS: 0, rmsDBFS: 0)
        }

        // 1. DC removal — subtract the mean.
        var mean: Double = 0
        for s in samples { mean += Double(s) }
        mean /= Double(samples.count)
        for i in samples.indices { samples[i] -= Float(mean) }

        // 2. High-pass — 2nd-order Butterworth at 80 Hz (rumble removal).
        samples = highpass(samples, sampleRate: sampleRate, cutoffHz: 80)

        // 3. Speech-only RMS normalization. Measured *before* room-tone padding
        //    so the (much quieter) head/tail room tone can never drag the
        //    speech level; the pad inherits the same gain, which keeps the
        //    delivered file uniform and the chain idempotent (§16.7 step 4).
        let rms = speechRMSDBFS(samples)
        let gainDB = target.targetRMSDBFS - rms
        let gainLinear = Float(pow(10.0, gainDB / 20.0))
        for i in samples.indices { samples[i] *= gainLinear }

        // 4. Room-tone normalization — trim/pad head and tail room tone.
        samples = normalizeRoomTone(samples, sampleRate: sampleRate, targetHead: target.headSeconds, targetTail: target.tailSeconds)

        // 5. True-peak lookahead limiting at ceiling − 0.5 dB.
        let ceiling = target.peakCeilingDBFS - Self.limiterHeadroomDB
        samples = lookaheadLimit(samples, sampleRate: sampleRate, ceilingDBFS: ceiling)
        // Safety: nothing may exceed the ceiling on the 4× oversampled signal.
        samples = enforceTruePeakCeiling(samples, sampleRate: sampleRate, ceilingDBFS: ceiling)

        // 6. Re-measure.
        let finalRMS = AudioMetricsCalculator.computeRMS(samples).dbfs
        let truePeak = AudioMetricsCalculator.computeTruePeak(samples)

        return MasteringResult(
            samples: samples,
            sampleRate: sampleRate,
            appliedGainDB: gainDB,
            truePeakDBFS: truePeak,
            rmsDBFS: finalRMS
        )
    }

    /// TPDF dither at 1 LSB for `bitDepth`, applied after limiting, only when
    /// reducing bit depth for a PCM output (§16.7 step 7). Deterministic via a
    /// fixed seed so the chain stays reproducible.
    public static func tpdfDither(_ samples: [Float], bitDepth: Int) -> [Float] {
        guard bitDepth > 1 else { return samples }
        let lsb = pow(2.0, -(Double(bitDepth) - 1.0))
        var rng = SeededPRNG(seed: 0x9E37_79B9_7F4A_7C15)
        var out = samples
        for i in out.indices {
            let noise = (rng.nextUnit() + rng.nextUnit() - 1.0) * lsb
            out[i] = out[i] + Float(noise)
        }
        return out
    }

    // MARK: - DC removal

    private static func highpass(_ samples: [Float], sampleRate: Double, cutoffHz: Double) -> [Float] {
        // RBJ cookbook, 2nd-order Butterworth (Q = 1/√2) high-pass.
        let w0 = 2 * Double.pi * cutoffHz / sampleRate
        let alpha = sin(w0) / (2 * 0.7071_0678)
        let cosw0 = cos(w0)
        let a0 = 1 + alpha
        let b0 = (1 + cosw0) / 2
        let b1 = -(1 + cosw0)
        let b2 = (1 + cosw0) / 2
        let a1 = -2 * cosw0
        let a2 = 1 - alpha

        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        var out = [Float](repeating: 0, count: samples.count)
        for i in samples.indices {
            let x = Double(samples[i])
            let y = (b0 / a0) * x + (b1 / a0) * x1 + (b2 / a0) * x2 - (a1 / a0) * y1 - (a2 / a0) * y2
            x2 = x1; x1 = x
            y2 = y1; y1 = y
            out[i] = Float(y)
        }
        return out
    }

    // MARK: - Room tone

    /// Trims or pads the head and tail to the target room-tone windows.
    /// Padding never inserts digital silence at the head (an ACX failure mode).
    /// When the take has usable room tone it is looped as-is; otherwise the
    /// quietest window is synthesized at a *quiet* level so a second mastering
    /// pass detects it as silence (the chain is idempotent, §16.7 step 7).
    ///
    /// A tolerance band absorbs the ±10 ms quantization of
    /// `computeSilenceBounds`; without it a "already at target" head could be
    /// trimmed or re-padded by one stride and the chain would not be idempotent.
    private static let roomToneTolerance: TimeInterval = 0.25

    private static func normalizeRoomTone(_ samples: [Float], sampleRate: Double, targetHead: TimeInterval, targetTail: TimeInterval) -> [Float] {
        let bounds = AudioMetricsCalculator.computeSilenceBounds(samples, sampleRate: sampleRate)
        let headTarget = Int(targetHead * sampleRate)
        let tailTarget = Int(targetTail * sampleRate)
        let tolerance = Int(Self.roomToneTolerance * sampleRate)
        let headSamples = Int(bounds.leading * sampleRate)
        let tailSamples = Int(bounds.trailing * sampleRate)

        var work = samples

        if headSamples > headTarget + tolerance, headSamples <= work.count {
            work.removeFirst(headSamples - headTarget)
        } else if headSamples < headTarget - tolerance {
            let room = roomToneBase(work, existingSilence: headSamples, sampleRate: sampleRate)
            let pad = loopedRoomTone(base: room, targetCount: headTarget - headSamples, sampleRate: sampleRate)
            work.insert(contentsOf: crossfadeHead(pad, with: work, sampleRate: sampleRate), at: 0)
        }

        if tailSamples > tailTarget + tolerance, tailSamples <= work.count {
            work.removeLast(tailSamples - tailTarget)
        } else if tailSamples < tailTarget - tolerance {
            let room = roomToneBase(work, existingSilence: tailSamples, sampleRate: sampleRate)
            let pad = loopedRoomTone(base: room, targetCount: tailTarget - tailSamples, sampleRate: sampleRate)
            work.append(contentsOf: crossfadeTail(work, with: pad, sampleRate: sampleRate))
        }

        return work
    }

    /// Blends the tail of a head pad with the head of the signal so the
    /// pad→signal transition is smooth. Without this the discontinuity rings
    /// the high-pass filter on a second pass and the chain is not idempotent.
    private static func crossfadeHead(_ pad: [Float], with signal: [Float], sampleRate: Double) -> [Float] {
        let fade = min(Int(0.03 * sampleRate), pad.count, signal.count)
        guard fade > 0 else { return pad }
        var blended = pad
        for i in 0..<fade {
            let t = Float(i) / Float(fade)
            blended[blended.count - fade + i] = blended[blended.count - fade + i] * (1 - t) + signal[i] * t
        }
        return blended
    }

    /// Blends the tail of the signal with the head of a tail pad (mirror of
    /// `crossfadeHead`).
    private static func crossfadeTail(_ signal: [Float], with pad: [Float], sampleRate: Double) -> [Float] {
        let fade = min(Int(0.03 * sampleRate), pad.count, signal.count)
        guard fade > 0 else { return pad }
        var blended = pad
        for i in 0..<fade {
            let t = Float(i) / Float(fade)
            blended[i] = blended[i] * t + signal[signal.count - fade + i] * (1 - t)
        }
        return blended
    }

    /// The loop source for room-tone padding: the take's own room tone when it
    /// is genuinely quiet, else the quietest window scaled to a quiet level.
    private static func roomToneBase(_ samples: [Float], existingSilence: Int, sampleRate: Double) -> [Float] {
        if existingSilence > 0 {
            let silence = Array(samples.prefix(existingSilence))
            let level = AudioMetricsCalculator.computeRMS(silence).dbfs
            if level.isFinite, level < -50 { return silence }
        }
        return scaleToRMS(quietestWindow(samples), targetDBFS: -65)
    }

    private static func scaleToRMS(_ samples: [Float], targetDBFS: Double) -> [Float] {
        let current = AudioMetricsCalculator.computeRMS(samples).dbfs
        guard current.isFinite, current > targetDBFS else { return samples }
        let scale = Float(pow(10.0, (targetDBFS - current) / 20.0))
        return samples.map { $0 * scale }
    }

    /// Loops `base` until `targetCount` samples, crossfading 30 ms at each join.
    private static func loopedRoomTone(base: [Float], targetCount: Int, sampleRate: Double) -> [Float] {
        guard !base.isEmpty, targetCount > 0 else { return [Float](repeating: 0, count: max(0, targetCount)) }
        let xfade = min(Int(0.03 * sampleRate), max(1, base.count / 2))
        var out: [Float] = []
        out.reserveCapacity(targetCount)

        while out.count < targetCount {
            let remaining = targetCount - out.count
            var chunk = base
            if chunk.count > remaining {
                chunk = Array(chunk.prefix(remaining))
            }
            guard !chunk.isEmpty else { break }

            if out.isEmpty {
                out = chunk
                continue
            }

            let fade = min(xfade, out.count, chunk.count)
            if fade > 0 {
                for i in 0..<fade {
                    let t = Float(i) / Float(fade)
                    out[out.count - fade + i] = out[out.count - fade + i] * (1 - t) + chunk[i] * t
                }
            }
            if fade < chunk.count {
                out.append(contentsOf: chunk.suffix(from: fade))
            } else {
                // The final (possibly clipped) chunk fits entirely inside the
                // crossfade region; append it so the loop always terminates.
                out.append(contentsOf: chunk)
            }
        }
        if out.count > targetCount { out.removeLast(out.count - targetCount) }
        return out
    }

    /// The quietest 250 ms window in the middle 90 % of the signal — the
    /// fallback room-tone source when the take has no usable head/tail silence
    /// (§16.7 step 3). The edges are skipped so a filter-settling transient at
    /// the very start/end can never be mistaken for room tone.
    private static func quietestWindow(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let window = 250
        guard samples.count > window else { return samples }
        let margin = samples.count / 20
        let searchStart = min(margin, max(0, samples.count - window))
        let searchEnd = max(searchStart + window, samples.count - margin)
        let base = Array(samples[searchStart ..< searchEnd])
        guard base.count > window else { return Array(samples[0 ..< window]) }

        var bestStart = 0
        var bestEnergy = Double.greatestFiniteMagnitude
        var energy: Float = 0
        for i in 0..<window { energy += base[i] * base[i] }
        bestEnergy = Double(energy)
        for start in 1...(base.count - window) {
            energy -= base[start - 1] * base[start - 1]
            energy += base[start + window - 1] * base[start + window - 1]
            if Double(energy) < bestEnergy {
                bestEnergy = Double(energy)
                bestStart = start
            }
        }
        return Array(base[bestStart ..< bestStart + window])
    }

    // MARK: - RMS normalization

    /// Speech-only RMS in dBFS: gaps (|x| below −50 dBFS) are excluded so the
    /// inserted silence between paragraphs cannot drag the number down (§15.6).
    private static func speechRMSDBFS(_ samples: [Float]) -> Double {
        var sum: Double = 0
        var count = 0
        for s in samples {
            if abs(s) >= speechFloorLinear {
                let d = Double(s)
                sum += d * d
                count += 1
            }
        }
        guard count > 0 else { return -90 }
        let rms = sqrt(sum / Double(count))
        return 20 * log10(max(rms, 1e-12))
    }

    // MARK: - Limiter

    /// 4× lookahead limiter: 5 ms attack, 50 ms release, ceiling at
    /// `ceilingDBFS`, operating on a 4× oversampled signal (§16.7 step 5).
    /// The sliding-maximum window runs in O(n) via a monotonic deque.
    private static func lookaheadLimit(_ samples: [Float], sampleRate: Double, ceilingDBFS: Double) -> [Float] {
        let ceilingLinear = pow(10.0, ceilingDBFS / 20.0)
        let rate4 = sampleRate * 4
        let over = oversample4(samples)
        guard !over.isEmpty else { return samples }

        let lookahead = max(1, Int(0.005 * rate4))        // 5 ms of 4× samples
        let attackCoeff = exp(-1.0 / (0.005 * rate4))     // 5 ms attack
        let releaseCoeff = exp(-1.0 / (0.050 * rate4))    // 50 ms release
        let n = over.count

        // envelope[i] = max |over[i-lookahead...i]| via a monotonic deque backed
        // by a fixed buffer (Array.removeFirst would make this O(n²)).
        var envelope = [Float](repeating: 0, count: n)
        var deque = [Int](repeating: 0, count: n + 1)
        var head = 0
        var tail = 0
        for i in 0..<n {
            while tail > head, abs(over[deque[tail - 1]]) <= abs(over[i]) { tail -= 1 }
            deque[tail] = i
            tail += 1
            if deque[head] < i - lookahead { head += 1 }
            envelope[i] = abs(over[deque[head]])
        }

        // target gain at i reacts to the peak up to `lookahead` samples ahead.
        var gains = [Double](repeating: 1, count: n)
        for i in 0..<n {
            let future = min(n - 1, i + lookahead)
            let peak = envelope[future]
            gains[i] = peak > 0 ? min(1, ceilingLinear / max(Double(peak), 1e-6)) : 1
        }

        var smoothed = [Double](repeating: 1, count: n)
        var current = 1.0
        for i in 0..<n {
            let target = gains[i]
            if target < current {
                current = current * attackCoeff + target * (1 - attackCoeff)
            } else {
                current = current * releaseCoeff + target * (1 - releaseCoeff)
            }
            smoothed[i] = current
        }

        var limited = [Float](repeating: 0, count: n)
        for i in 0..<n {
            limited[i] = over[i] * Float(smoothed[i])
        }
        return downsample4(limited)
    }

    /// Final safety: scale by the ratio of ceiling to the measured 4× true peak
    /// if any inter-sample peak still exceeds the ceiling. A tiny margin keeps
    /// the measured peak strictly inside the ceiling across encoder round-trips.
    private static func enforceTruePeakCeiling(_ samples: [Float], sampleRate: Double, ceilingDBFS: Double) -> [Float] {
        let measured = AudioMetricsCalculator.computeTruePeak(samples)
        let margin = ceilingDBFS - 0.02
        if measured.isFinite, measured > margin {
            let scale = Float(pow(10.0, (margin - measured) / 20.0))
            var out = samples
            for i in out.indices { out[i] *= scale }
            return out
        }
        return samples
    }

    private static func oversample4(_ samples: [Float]) -> [Float] {
        guard samples.count > 1 else { return samples }
        var out = [Float](repeating: 0, count: (samples.count - 1) * 4 + 1)
        for i in 0..<(samples.count - 1) {
            let a = samples[i]
            let b = samples[i + 1]
            let d = (b - a) * 0.25
            out[i * 4] = a
            out[i * 4 + 1] = a + d
            out[i * 4 + 2] = a + 2 * d
            out[i * 4 + 3] = a + 3 * d
        }
        out[out.count - 1] = samples[samples.count - 1]
        return out
    }

    /// Picks every 4th oversampled sample, preserving the input length: a
    /// length-`n` signal oversamples to `4(n−1)+1`, whose indices `0, 4, …, 4(n−1)`
    /// are exactly `n` samples.
    private static func downsample4(_ oversampled: [Float]) -> [Float] {
        guard !oversampled.isEmpty else { return [] }
        var out = [Float](repeating: 0, count: (oversampled.count - 1) / 4 + 1)
        for i in out.indices {
            out[i] = oversampled[i * 4]
        }
        return out
    }
}

// MARK: - SeededPRNG

/// A small deterministic LCG for the dither noise (the chain must stay
/// reproducible; CI gate G-7 forbids wall-clock/random seeds in
/// Core/Production, and a system RNG would break golden comparisons).
struct SeededPRNG: Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
    mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
