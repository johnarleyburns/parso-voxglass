import Accelerate
import Foundation

public protocol AudioMetricsCalculating: Sendable {
    func metrics(for url: URL) async throws -> AudioQualityMetrics
    func metrics(for samples: [Float], sampleRate: Double, channels: Int) -> AudioQualityMetrics
}

public struct AudioMetricsCalculator: AudioMetricsCalculating {
    public static let analyzerVersion = 1

    public let decoder: any AudioDecoding

    public init(decoder: any AudioDecoding = PlaceholderAudioDecoder()) {
        self.decoder = decoder
    }

    public func metrics(for url: URL) async throws -> AudioQualityMetrics {
        let decoded = try await decoder.decodeToMonoFloat(url, targetSampleRate: nil)
        return metrics(for: decoded.samples, sampleRate: decoded.sampleRate, channels: 1)
    }

    public func metrics(for samples: [Float], sampleRate: Double, channels: Int) -> AudioQualityMetrics {
        guard !samples.isEmpty else {
            return AudioQualityMetrics(
                peakDBFS: -.infinity,
                truePeakDBFS: -.infinity,
                rmsDBFS: -.infinity,
                noiseFloorDBFS: -90,
                noiseFloorReliable: false,
                replayGainDB: 0,
                clipCount: 0,
                dcOffset: 0,
                leadingSilence: 0,
                trailingSilence: 0,
                duration: 0,
                sampleRate: sampleRate,
                channels: channels
            )
        }

        let peak = Self.computePeak(samples)
        let truePeak = Self.computeTruePeak(samples)
        let (rms, firstNonSilent, lastNonSilent) = Self.computeRMS(samples)
        let noiseFloor = Self.computeNoiseFloor(samples, sampleRate: sampleRate, firstNonSilent: firstNonSilent, lastNonSilent: lastNonSilent)
        let clipCount = Self.computeClipCount(samples)
        let dcOffset = Self.computeDCOffset(samples)
        let (leadingSilence, trailingSilence) = Self.computeSilenceBounds(samples, sampleRate: sampleRate)
        let replayGain = ReplayGainCalculator.analyze(samples: samples, sampleRate: sampleRate)
        let duration = Double(samples.count) / sampleRate

        return AudioQualityMetrics(
            peakDBFS: peak,
            truePeakDBFS: truePeak,
            rmsDBFS: rms,
            noiseFloorDBFS: noiseFloor.value,
            noiseFloorReliable: noiseFloor.isReliable,
            replayGainDB: replayGain,
            clipCount: clipCount,
            dcOffset: dcOffset,
            leadingSilence: leadingSilence,
            trailingSilence: trailingSilence,
            duration: duration,
            sampleRate: sampleRate,
            channels: channels
        )
    }
}

extension AudioMetricsCalculator {

    public static func computePeak(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return -.infinity }
        var peak: Float = 0
        samples.withUnsafeBufferPointer { buf in
            vDSP_maxmgv(buf.baseAddress!, 1, &peak, vDSP_Length(buf.count))
        }
        return floatToDBFS(Double(peak))
    }

    /// 4× oversampled true peak (§11.6.2). The 33-tap polyphase kernels are
    /// computed once; each phase's convolution is evaluated with
    /// `vDSP_desamp` (4 phases × 4 sub-phases), so no interpolated array is
    /// ever materialized.
    public static func computeTruePeak(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return -.infinity }
        let kernel = truePeakKernel().map { Float($0) }
        let paddedCount = samples.count + 8
        var padded = [Float](repeating: 0, count: paddedCount)
        padded.replaceSubrange(8..<paddedCount, with: samples)

        var peak: Float = 0
        padded.withUnsafeBufferPointer { pad in
            var out = [Float](repeating: 0, count: samples.count / 4 + 4)
            for phase in 0..<4 {
                // out_p[m] = sum_k kernel[p + 4k] * src[m - k], padded to 9 taps.
                var taps = [Float](repeating: 0, count: 9)
                for k in 0..<9 {
                    let t = phase + 4 * k
                    if t < 33 { taps[k] = kernel[t] }
                }
                let reversed = Array(taps.reversed())
                for sub in 0..<4 {
                    let n = (samples.count - sub + 3) / 4
                    guard n > 0 else { continue }
                    let src = pad.baseAddress! + sub
                    out.withUnsafeMutableBufferPointer { outBuf in
                        vDSP_desamp(src, 4, reversed, outBuf.baseAddress!, vDSP_Length(n), 9)
                    }
                    var phasePeak: Float = 0
                    out.withUnsafeBufferPointer { outBuf in
                        vDSP_maxmgv(outBuf.baseAddress!, 1, &phasePeak, vDSP_Length(n))
                    }
                    if phasePeak > peak { peak = phasePeak }
                }
            }
        }
        return floatToDBFS(Double(peak))
    }

    public static func computeRMS(_ samples: [Float]) -> (dbfs: Double, firstNonSilent: Int, lastNonSilent: Int) {
        let silenceThreshold: Float = 0.001
        var first = 0
        var last = samples.count - 1
        while first < samples.count && abs(samples[first]) < silenceThreshold { first += 1 }
        while last > first && abs(samples[last]) < silenceThreshold { last -= 1 }
        if first > last { return (-.infinity, 0, 0) }
        let count = last - first + 1
        var sumSq: Float = 0
        samples.withUnsafeBufferPointer { buf in
            vDSP_svesq(buf.baseAddress! + first, 1, &sumSq, vDSP_Length(count))
        }
        let rms = sqrt(Double(sumSq) / Double(count))
        return (floatToDBFS(rms), first, last)
    }

    public static func computeNoiseFloor(_ samples: [Float], sampleRate: Double, firstNonSilent: Int, lastNonSilent: Int) -> (value: Double, isReliable: Bool) {
        let windowLength = Int(sampleRate * 0.05)
        let hop = Int(sampleRate * 0.025)
        guard windowLength > 0, hop > 0 else { return (-90, false) }

        var envelope: [Double] = []
        envelope.reserveCapacity(samples.count / hop + 1)
        samples.withUnsafeBufferPointer { buf in
            var i = 0
            while i + windowLength <= samples.count {
                var sumSq: Float = 0
                vDSP_svesq(buf.baseAddress! + i, 1, &sumSq, vDSP_Length(windowLength))
                envelope.append(Double(sumSq) / Double(windowLength))
                i += hop
            }
        }
        guard envelope.count >= 10 else { return (-90, false) }
        let sorted = envelope.sorted()
        let e0 = sorted[max(0, Int(Double(sorted.count) * 0.10))]
        let absoluteFloor: Double = 3.162e-4
        let silenceThreshold = max(e0 * 4.0, absoluteFloor)

        var silentSumSq: Double = 0
        var silentCount = 0
        for e in envelope {
            if e < silenceThreshold { silentSumSq += e; silentCount += 1 }
        }
        guard silentCount >= 10 else { return (-90, false) }
        let silentDuration = Double(silentCount * hop) / sampleRate
        guard silentDuration >= 0.5 else { return (-90, false) }
        let noiseFloorRMS = sqrt(silentSumSq / Double(silentCount))
        return (floatToDBFS(noiseFloorRMS), true)
    }

    public static func computeClipCount(_ samples: [Float]) -> Int {
        let clipThreshold: Float = 0.9995
        guard !samples.isEmpty else { return 0 }
        // Fast path: if nothing reaches the threshold there can be no runs.
        var maxAbs: Float = 0
        samples.withUnsafeBufferPointer { buf in
            vDSP_maxmgv(buf.baseAddress!, 1, &maxAbs, vDSP_Length(buf.count))
        }
        guard maxAbs >= clipThreshold else { return 0 }
        var clipCount = 0
        var run = 0
        for s in samples {
            if abs(s) >= clipThreshold {
                run += 1
            } else {
                if run >= 3 { clipCount += 1 }
                run = 0
            }
        }
        if run >= 3 { clipCount += 1 }
        return clipCount
    }

    public static func computeDCOffset(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        samples.withUnsafeBufferPointer { buf in
            vDSP_sve(buf.baseAddress!, 1, &sum, vDSP_Length(buf.count))
        }
        return Double(sum) / Double(samples.count)
    }

    public static func computeSilenceBounds(_ samples: [Float], sampleRate: Double) -> (leading: TimeInterval, trailing: TimeInterval) {
        let threshold: Float = 0.001
        let windowLength = Int(sampleRate * 0.01)
        let stride = max(windowLength / 2, 1)
        guard windowLength > 0, samples.count >= windowLength else { return (0, 0) }

        var leadingFrames = 0
        samples.withUnsafeBufferPointer { buf in
            var pos = 0
            while pos + windowLength <= buf.count {
                var sumSq: Float = 0
                vDSP_svesq(buf.baseAddress! + pos, 1, &sumSq, vDSP_Length(windowLength))
                if sqrt(Double(sumSq) / Double(windowLength)) > Double(threshold) { break }
                leadingFrames = pos + windowLength
                pos += stride
            }
        }

        var trailingFrames = 0
        samples.withUnsafeBufferPointer { buf in
            var pos = buf.count - windowLength
            while pos >= 0 {
                var sumSq: Float = 0
                vDSP_svesq(buf.baseAddress! + pos, 1, &sumSq, vDSP_Length(windowLength))
                if sqrt(Double(sumSq) / Double(windowLength)) > Double(threshold) { break }
                trailingFrames = buf.count - pos
                pos -= stride
            }
        }

        return (Double(leadingFrames) / sampleRate, Double(trailingFrames) / sampleRate)
    }

    public static func floatToDBFS(_ value: Double) -> Double {
        return 20.0 * log10(max(value, 1e-7))
    }

    private static func truePeakKernel() -> [Double] {
        let beta: Double = 8.0
        let taps = 33
        let fc: Double = 0.5 / 4.0
        var kernel = [Double](repeating: 0, count: taps)
        let mid = Double(taps - 1) / 2.0
        for i in 0..<taps {
            let x = Double(i) - mid
            if abs(x) < 1e-6 {
                kernel[i] = 2.0 * fc
            } else {
                kernel[i] = sin(2.0 * .pi * fc * x) / (.pi * x)
            }
            let nu = beta * sqrt(1.0 - pow((x / mid), 2))
            kernel[i] *= besselI0(nu) / besselI0(beta)
        }
        var sum: Double = 0
        for k in kernel { sum += k }
        for i in 0..<taps { kernel[i] = kernel[i] * 4.0 / sum }
        return kernel
    }

    private static func besselI0(_ x: Double) -> Double {
        var sum: Double = 1.0
        var term: Double = 1.0
        for k in 1...25 {
            term *= (x * x) / (4.0 * Double(k * k))
            sum += term
            if term < 1e-15 { break }
        }
        return sum
    }
}

public struct PlaceholderAudioDecoder: AudioDecoding {
    public init() {}

    public func describe(_ url: URL) async throws -> AudioFormatDescription {
        throw CoreAudioDecodeError.notAvailable
    }

    public func decodeToMonoFloat(_ url: URL, targetSampleRate: Double?) async throws -> DecodedAudio {
        throw CoreAudioDecodeError.notAvailable
    }
}

public enum CoreAudioDecodeError: Error {
    case notAvailable
}
