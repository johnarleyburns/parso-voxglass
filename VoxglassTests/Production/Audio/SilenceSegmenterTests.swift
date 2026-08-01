import Foundation
import Testing
import VoxglassCore

struct SilenceSegmenterTests {

    func makeSilentAudio(sampleRate: Double, duration: TimeInterval) -> [Float] {
        [Float](repeating: 0, count: Int(sampleRate * duration))
    }

    func makeTone(sampleRate: Double, frequency: Double, duration: TimeInterval, amplitude: Float = 0.5) -> [Float] {
        let n = Int(sampleRate * duration)
        var samples: [Float] = []
        samples.reserveCapacity(n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            samples.append(amplitude * Float(sin(2 * .pi * frequency * t)))
        }
        return samples
    }

    @Test func emptySamplesReturnsNoRegions() {
        let segmenter = SilenceSegmenter()
        let regions = segmenter.detect(samples: [], sampleRate: 48000)
        #expect(regions.isEmpty)
    }

    @Test func silentAudioReturnsOneRegion() {
        let segmenter = SilenceSegmenter()
        let samples = makeSilentAudio(sampleRate: 48000, duration: 3.0)
        let regions = segmenter.detect(samples: samples, sampleRate: 48000,
            options: SilenceSegmenter.Options(thresholdDBFS: -30, minSilenceDuration: 0.3))
        #expect(regions.count == 1)
    }

    @Test func speechWithGapsDetectsSilenceRegions() {
        let segmenter = SilenceSegmenter()
        let rate = 48000.0
        var samples = makeTone(sampleRate: rate, frequency: 440, duration: 1.0)
        samples.append(contentsOf: makeSilentAudio(sampleRate: rate, duration: 0.5))
        samples.append(contentsOf: makeTone(sampleRate: rate, frequency: 440, duration: 0.5))
        samples.append(contentsOf: makeSilentAudio(sampleRate: rate, duration: 0.5))
        samples.append(contentsOf: makeTone(sampleRate: rate, frequency: 440, duration: 1.0))

        let regions = segmenter.detect(samples: samples, sampleRate: rate,
            options: SilenceSegmenter.Options(thresholdDBFS: -30, minSilenceDuration: 0.4))
        #expect(regions.count == 2)
    }

    @Test func shortSilenceIsNotDetected() {
        let segmenter = SilenceSegmenter()
        let rate = 48000.0
        var samples = makeTone(sampleRate: rate, frequency: 440, duration: 1.0)
        samples.append(contentsOf: makeSilentAudio(sampleRate: rate, duration: 0.2))
        samples.append(contentsOf: makeTone(sampleRate: rate, frequency: 440, duration: 1.0))

        let regions = segmenter.detect(samples: samples, sampleRate: rate,
            options: SilenceSegmenter.Options(thresholdDBFS: -30, minSilenceDuration: 0.35))
        #expect(regions.isEmpty)
    }

    @Test func proposeBoundariesWithNoRegions() {
        let segmenter = SilenceSegmenter()
        let boundaries = segmenter.proposeBoundaries([], boundaryPadding: 0, targetCount: nil)
        #expect(boundaries.isEmpty)
    }

    @Test func proposeBoundariesReturnsMidpoints() {
        var regions: [SilenceRegion] = []
        regions.append(SilenceRegion(startTime: 1.0, endTime: 1.5, duration: 0.5))
        regions.append(SilenceRegion(startTime: 3.0, endTime: 3.5, duration: 0.5))

        let segmenter = SilenceSegmenter()
        let boundaries = segmenter.proposeBoundaries(regions, boundaryPadding: 0, targetCount: nil)
        #expect(boundaries.count == 2)
        #expect(abs(boundaries[0].time - 1.25) < 0.01)
        #expect(abs(boundaries[1].time - 3.25) < 0.01)
    }

    @Test func proposeBoundariesFiltersShortSegments() {
        var regions: [SilenceRegion] = []
        regions.append(SilenceRegion(startTime: 0.4, endTime: 0.5, duration: 0.1))
        regions.append(SilenceRegion(startTime: 0.8, endTime: 0.9, duration: 0.1))

        let segmenter = SilenceSegmenter()
        let boundaries = segmenter.proposeBoundaries(regions, boundaryPadding: 0, targetCount: nil)
        #expect(boundaries.count <= 1)
    }
}
