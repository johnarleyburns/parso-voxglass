import Foundation

final class VolumeNormalizer {
    private let windowSize = 2048
    private var ring: [Float]
    private var ringIndex = 0
    private var sumOfSquares: Float = 0
    private var windowFilledSamples = 0

    private let targetRMS: Float = 0.158   // ~–16 dBFS
    private let attackCoeff: Float = 0.1   // fast attack (per hop)
    private let releaseCoeff: Float = 0.01 // slow release (per hop)
    private let minGain: Float = 0.25
    private let maxGain: Float = 4.0
    private let noiseFloor: Float = 0.0001

    private var hopCounter = 0
    private let hopSize = 256

    private(set) var gain: Float = 1.0

    init() {
        ring = Array(repeating: 0, count: windowSize)
    }

    func process(_ sample: Float) -> Float {
        let oldSample = ring[ringIndex]
        ring[ringIndex] = sample
        ringIndex = (ringIndex + 1) % windowSize

        sumOfSquares -= oldSample * oldSample
        sumOfSquares += sample * sample

        if windowFilledSamples < windowSize {
            windowFilledSamples += 1
        }

        hopCounter += 1
        if hopCounter >= hopSize {
            hopCounter = 0
            let rms = sqrt(sumOfSquares / Float(max(1, windowFilledSamples)))
            if rms > noiseFloor {
                let targetGain = targetRMS / rms
                let coeff = (targetGain > gain) ? attackCoeff : releaseCoeff
                gain += coeff * (targetGain - gain)
                gain = max(minGain, min(maxGain, gain))
            }
        }

        var output = gain * sample

        if output > 1.0 { output = 1.0 }
        if output < -1.0 { output = -1.0 }

        return output
    }

    func reset() {
        gain = 1.0
        for i in 0..<windowSize {
            ring[i] = 0
        }
        ringIndex = 0
        sumOfSquares = 0
        windowFilledSamples = 0
        hopCounter = 0
    }
}
