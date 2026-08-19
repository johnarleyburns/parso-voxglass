import Foundation

public struct SilenceSegmenter: Sendable {

    public struct Options: Sendable {
        public var thresholdDBFS: Double
        public var minSilenceDuration: TimeInterval
        public var minSegmentDuration: TimeInterval

        public init(
            thresholdDBFS: Double = -40,
            minSilenceDuration: TimeInterval = 0.35,
            minSegmentDuration: TimeInterval = 0.8
        ) {
            self.thresholdDBFS = thresholdDBFS
            self.minSilenceDuration = minSilenceDuration
            self.minSegmentDuration = minSegmentDuration
        }
    }

    private func computePeakDBFS(_ samples: [Float]) -> Double {
        var peak: Float = 0
        for s in samples {
            let a = abs(s)
            if a > peak { peak = a }
        }
        return peak > 0 ? Double(20.0 * log10(peak)) : -.infinity
    }

    public init() {}

    public func detect(samples: [Float], sampleRate: Double, options: Options = Options()) -> [SilenceRegion] {
        let hop = Int(sampleRate * 0.02)
        guard hop > 0, samples.count > hop else { return [] }
        let totalFrames = samples.count / hop

        let filePeak = computePeakDBFS(samples)
        let relativeThreshold = max(filePeak + options.thresholdDBFS, -50)
        let threshold = pow(10.0, relativeThreshold / 20.0)
        var silentFrames = [Bool](repeating: false, count: totalFrames)
        for i in 0..<totalFrames {
            let start = i * hop
            var sum: Double = 0
            for j in start..<min(start + hop, samples.count) {
                sum += Double(samples[j]) * Double(samples[j])
            }
            let rms = sqrt(sum / Double(hop))
            silentFrames[i] = rms < threshold
        }

        let minFrames = Int(options.minSilenceDuration / 0.02)
        var regions: [SilenceRegion] = []
        var i = 0
        while i < silentFrames.count {
            if silentFrames[i] {
                let start = i
                while i < silentFrames.count && silentFrames[i] { i += 1 }
                let length = i - start
                if length >= minFrames {
                    let startTime = Double(start) * 0.02
                    let endTime = Double(i) * 0.02
                    regions.append(SilenceRegion(startTime: startTime, endTime: endTime, duration: endTime - startTime))
                }
            } else {
                i += 1
            }
        }
        return regions
    }

    public func proposeBoundaries(_ regions: [SilenceRegion], boundaryPadding: TimeInterval = 0.08, targetCount: Int? = nil, ids: any IDGenerator = UUIDGenerator()) -> [SegmentBoundary] {
        let minDuration: Double = 0.8
        let minSilenceForHigh: Double = 0.6

        var boundaries = regions.map { region -> SegmentBoundary in
            let midpoint = (region.startTime + region.endTime) / 2.0 + boundaryPadding
            let confidence: SegmentBoundary.Confidence = region.duration >= minSilenceForHigh ? .high : .review
            return SegmentBoundary(
                id: ids.next(),
                time: midpoint,
                confidence: confidence,
                isUserPlaced: false
            )
        }

        if boundaries.count > 1 {
            var filtered: [SegmentBoundary] = [boundaries[0]]
            for i in 1..<boundaries.count {
                let segmentDuration = boundaries[i].time - (filtered.last?.time ?? 0)
                if segmentDuration >= minDuration {
                    filtered.append(boundaries[i])
                }
            }
            boundaries = filtered
        }

        if let target = targetCount, target > 0 {
            var working = boundaries
            while working.count > target - 1 {
                if working.count <= 1 { break }
                var shortestIdx = 0
                var shortestLength = Double.infinity
                for i in 0..<(working.count - 1) {
                    let segmentLen = working[i + 1].time - working[i].time
                    if segmentLen < shortestLength { shortestLength = segmentLen; shortestIdx = i + 1 }
                }
                var idx = shortestIdx
                if working.count == 2 && idx == 1 { idx = 0 }
                if idx < working.count {
                    working.remove(at: idx)
                }
            }
            boundaries = working
        }

        return boundaries
    }
}

public struct SilenceRegion: Sendable, Equatable {
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var duration: TimeInterval

    public init(startTime: TimeInterval, endTime: TimeInterval, duration: TimeInterval) {
        self.startTime = startTime
        self.endTime = endTime
        self.duration = duration
    }
}

public struct SegmentBoundary: Sendable, Equatable, Identifiable {
    public enum Confidence: Sendable, Equatable {
        case high
        case review
    }
    public let id: UUID
    public var time: TimeInterval
    public var confidence: Confidence
    public var isUserPlaced: Bool

    public init(id: UUID, time: TimeInterval, confidence: Confidence, isUserPlaced: Bool) {
        self.id = id
        self.time = time
        self.confidence = confidence
        self.isUserPlaced = isUserPlaced
    }
}
