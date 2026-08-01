import Foundation
import VoxglassCore

/// Deterministic decoder used by tests: produces a synthetic mono signal of a
/// scripted duration without touching the filesystem or Core Audio.
public struct FixtureDecoder: AudioDecoding {
    public let sampleRate: Double
    public let channels: Int
    public let durationOverride: TimeInterval?

    public init(sampleRate: Double = 48000, channels: Int = 1, durationOverride: TimeInterval? = nil) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.durationOverride = durationOverride
    }

    public func describe(_ url: URL) async throws -> AudioFormatDescription {
        AudioFormatDescription(sampleRate: sampleRate, channels: channels, bitDepth: 16, codec: "pcm")
    }

    public func decodeToMonoFloat(_ url: URL, targetSampleRate: Double?) async throws -> DecodedAudio {
        // A 440 Hz sine at a moderate level; every fixture is deterministic.
        let rate = targetSampleRate ?? sampleRate
        let duration = durationOverride ?? 1.0
        let count = Int(rate * duration)
        var samples: [Float] = []
        samples.reserveCapacity(count)
        for i in 0..<count {
            samples.append(Float(sin(2.0 * .pi * 440.0 * Double(i) / rate) * 0.25))
        }
        return DecodedAudio(samples: samples, sampleRate: rate, duration: Double(count) / rate)
    }
}

/// Deterministic metrics fake. Returns values that are stable regardless of
/// the input URL, for assertions about plumbing rather than DSP.
public struct FixtureMetricsCalculator: AudioMetricsCalculating {
    public let fixture: AudioQualityMetrics

    public init(fixture: AudioQualityMetrics = AudioQualityMetrics(
        peakDBFS: -6.0,
        truePeakDBFS: -6.0,
        rmsDBFS: -20.0,
        noiseFloorDBFS: -60.0,
        noiseFloorReliable: true,
        replayGainDB: 4.0,
        clipCount: 0,
        dcOffset: 0,
        leadingSilence: 0.1,
        trailingSilence: 0.2,
        duration: 30.0,
        sampleRate: 48000,
        channels: 1
    )) {
        self.fixture = fixture
    }

    public func metrics(for url: URL) async throws -> AudioQualityMetrics {
        fixture
    }

    public func metrics(for samples: [Float], sampleRate: Double, channels: Int) -> AudioQualityMetrics {
        fixture
    }
}

/// In-memory segment player for tests. Tracks load/play/pause state and emits
/// a scripted event stream.
public final class FakeSegmentPlayer: SegmentPlayer, @unchecked Sendable {
    public private(set) var currentParagraphID: UUID?
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var isPlaying = false
    public private(set) var loadedSegments: [PlaybackSegment] = []
    public private(set) var seekCount = 0

    private let eventContinuation: AsyncStream<PlayerEvent>.Continuation
    public let events: AsyncStream<PlayerEvent>

    public init() {
        var continuation: AsyncStream<PlayerEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        eventContinuation = continuation
    }

    public func load(_ segments: [PlaybackSegment]) async throws {
        loadedSegments = segments
        currentParagraphID = segments.first?.paragraphID
    }

    public func play() async throws {
        isPlaying = true
    }

    public func pause() async {
        isPlaying = false
    }

    public func seek(toParagraph id: UUID, offset: TimeInterval) async throws {
        seekCount += 1
        currentParagraphID = id
        currentTime = offset
        eventContinuation.yield(.paragraphChanged(id))
    }

    public func nextParagraph() async throws {
        guard let current = currentParagraphID,
              let idx = loadedSegments.firstIndex(where: { $0.paragraphID == current }),
              idx + 1 < loadedSegments.count else { return }
        currentParagraphID = loadedSegments[idx + 1].paragraphID
        currentTime = 0
        eventContinuation.yield(.paragraphChanged(loadedSegments[idx + 1].paragraphID))
    }

    public func previousParagraph() async throws {
        guard let current = currentParagraphID,
              let idx = loadedSegments.firstIndex(where: { $0.paragraphID == current }),
              idx > 0 else { return }
        currentParagraphID = loadedSegments[idx - 1].paragraphID
        currentTime = 0
        eventContinuation.yield(.paragraphChanged(loadedSegments[idx - 1].paragraphID))
    }

    public func skip(by seconds: TimeInterval) async throws {
        currentTime += seconds
    }

    public func setRate(_ rate: Float) async {
    }

    deinit {
        eventContinuation.finish()
    }
}
