import Foundation

public struct ReplayGainCalculator: Sendable {

    public static func analyze(samples: [Float], sampleRate: Double) -> Double {
        analyzeFull(samples: samples, sampleRate: sampleRate).gainDB
    }

    public static func analyzeFull(samples: [Float], sampleRate: Double) -> (gainDB: Double, peakDBFS: Double) {
        guard !samples.isEmpty else { return (0, -.infinity) }

        let sampleRateInt = Int(sampleRate)
        guard ReplayGainCoefficients.supportedRates.contains(sampleRateInt) else {
            return (.infinity, peakDBFS(for: samples))
        }

        guard let yuleB = ReplayGainCoefficients.yuleB(for: sampleRateInt),
              let yuleA = ReplayGainCoefficients.yuleA(for: sampleRateInt),
              let butterB = ReplayGainCoefficients.butterworthB(for: sampleRateInt),
              let butterA = ReplayGainCoefficients.butterworthA(for: sampleRateInt) else {
            return (.infinity, peakDBFS(for: samples))
        }

        let blockSize = Int(sampleRate * 0.05)
        guard blockSize > 0 else { return (0, -.infinity) }

        // The published RG 1.0 reference (flac gain_analysis.c) runs this
        // cascade in Float32; the coefficient tables stay Double (verbatim),
        // but the per-sample arithmetic is Float32 with a hand-unrolled
        // direct-form II transposed section — no biquad factoring, no
        // root-finding. This is what keeps a 30 s take inside the §11.6.9
        // budget even in debug builds.
        let bY = yuleB.map { Float($0) }
        let aY = yuleA.map { Float($0) }
        let bB = butterB.map { Float($0) }
        let aB = butterA.map { Float($0) }
        let (bY0, bY1, bY2, bY3, bY4, bY5, bY6, bY7, bY8, bY9, bY10) = (bY[0], bY[1], bY[2], bY[3], bY[4], bY[5], bY[6], bY[7], bY[8], bY[9], bY[10])
        let (aY1, aY2, aY3, aY4, aY5, aY6, aY7, aY8, aY9, aY10) = (aY[1], aY[2], aY[3], aY[4], aY[5], aY[6], aY[7], aY[8], aY[9], aY[10])
        let (bB0, bB1, bB2) = (bB[0], bB[1], bB[2])
        let (aB1, aB2) = (aB[1], aB[2])

        var v0: Float = 0, v1: Float = 0, v2: Float = 0, v3: Float = 0, v4: Float = 0
        var v5: Float = 0, v6: Float = 0, v7: Float = 0, v8: Float = 0, v9: Float = 0
        var u0: Float = 0, u1: Float = 0

        var blockLoudness: [Double] = []
        blockLoudness.reserveCapacity(samples.count / blockSize + 1)

        samples.withUnsafeBufferPointer { src in
            let p = src.baseAddress!
            var blockIndex = 0
            while blockIndex + blockSize <= src.count {
                var sumSq: Float = 0
                let end = blockIndex + blockSize
                var i = blockIndex
                while i + 1 < end {
                    // Two samples per iteration; the direct-form II transposed
                    // state chains across them. Pointer reads, no bounds checks.
                    var y = bY0 * p[i] + v0
                    v0 = bY1 * p[i] - aY1 * y + v1
                    v1 = bY2 * p[i] - aY2 * y + v2
                    v2 = bY3 * p[i] - aY3 * y + v3
                    v3 = bY4 * p[i] - aY4 * y + v4
                    v4 = bY5 * p[i] - aY5 * y + v5
                    v5 = bY6 * p[i] - aY6 * y + v6
                    v6 = bY7 * p[i] - aY7 * y + v7
                    v7 = bY8 * p[i] - aY8 * y + v8
                    v8 = bY9 * p[i] - aY9 * y + v9
                    v9 = bY10 * p[i] - aY10 * y
                    var t = bB0 * y + u0
                    u0 = bB1 * y - aB1 * t + u1
                    u1 = bB2 * y - aB2 * t
                    sumSq += t * t

                    y = bY0 * p[i + 1] + v0
                    v0 = bY1 * p[i + 1] - aY1 * y + v1
                    v1 = bY2 * p[i + 1] - aY2 * y + v2
                    v2 = bY3 * p[i + 1] - aY3 * y + v3
                    v3 = bY4 * p[i + 1] - aY4 * y + v4
                    v4 = bY5 * p[i + 1] - aY5 * y + v5
                    v5 = bY6 * p[i + 1] - aY6 * y + v6
                    v6 = bY7 * p[i + 1] - aY7 * y + v7
                    v7 = bY8 * p[i + 1] - aY8 * y + v8
                    v8 = bY9 * p[i + 1] - aY9 * y + v9
                    v9 = bY10 * p[i + 1] - aY10 * y
                    t = bB0 * y + u0
                    u0 = bB1 * y - aB1 * t + u1
                    u1 = bB2 * y - aB2 * t
                    sumSq += t * t

                    i += 2
                }
                while i < end {
                    let x = p[i]
                    var y = bY0 * x + v0
                    v0 = bY1 * x - aY1 * y + v1
                    v1 = bY2 * x - aY2 * y + v2
                    v2 = bY3 * x - aY3 * y + v3
                    v3 = bY4 * x - aY4 * y + v4
                    v4 = bY5 * x - aY5 * y + v5
                    v5 = bY6 * x - aY6 * y + v6
                    v6 = bY7 * x - aY7 * y + v7
                    v7 = bY8 * x - aY8 * y + v8
                    v8 = bY9 * x - aY9 * y + v9
                    v9 = bY10 * x - aY10 * y
                    let t = bB0 * y + u0
                    u0 = bB1 * y - aB1 * t + u1
                    u1 = bB2 * y - aB2 * t
                    sumSq += t * t
                    i += 1
                }
                let ms = Double(sumSq) / Double(blockSize)
                let L = 10.0 * log10(ms + 1e-37)
                blockLoudness.append(clamp(L, -110, 30))
                blockIndex += blockSize
            }
        }

        guard !blockLoudness.isEmpty else { return (0, peakDBFS(for: samples)) }

        blockLoudness.sort()
        let idx95 = min(Int(ceil(Double(blockLoudness.count) * 0.95)) - 1, blockLoudness.count - 1)
        let L95 = blockLoudness[idx95]

        let gainDB = -25.4885 - L95
        let peakDBFS = peakDBFS(for: samples)

        return (gainDB, peakDBFS)
    }

    private static func clamp(_ value: Double, _ lo: Double, _ hi: Double) -> Double {
        value < lo ? lo : (value > hi ? hi : value)
    }

    private static func peakDBFS(for samples: [Float]) -> Double {
        var peak: Double = 0
        for s in samples {
            let a = Double(abs(s))
            if a > peak { peak = a }
        }
        return peak > 0 ? 20.0 * log10(peak) : -.infinity
    }

    private init() {}
}
