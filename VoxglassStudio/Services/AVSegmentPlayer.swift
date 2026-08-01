import AVFoundation
import Foundation
import VoxglassCore

/// Concrete `SegmentPlayer` backed by `AVAudioEngine` + `AVAudioPlayerNode`
/// (spec §12.5).
///
/// Segments are played as **scheduled buffers** — not `AVQueuePlayer` — so that
/// paragraph-to-paragraph transitions are sample-accurate and programmatic
/// silence is scheduled as real zero buffers rather than timers. Paragraph
/// boundaries are detected from the scheduler's completion callback, which
/// fires when a paragraph's audio buffer finishes; `next`/`previous` always
/// mean paragraph.
///
/// All buffers are normalized to a canonical 48 kHz mono Float32 format up
/// front. Buffers for the whole loaded queue are built once; the scheduler
/// then plays them back-to-back in order.
@MainActor
public final class AVSegmentPlayer: @preconcurrency SegmentPlayer {
    public private(set) var currentParagraphID: UUID?
    public private(set) var currentTime: TimeInterval
    public private(set) var isPlaying: Bool
    public let events: AsyncStream<PlayerEvent>

    private let assets: any ContentAddressedStore
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()

    private var segments: [PlaybackSegment] = []
    private var items: [PlayItem] = []
    private var audioStartFrame: [UUID: AVAudioFramePosition] = [:]
    private var scheduleCursor: AVAudioFramePosition = 0
    private var eventContinuation: AsyncStream<PlayerEvent>.Continuation?
    private var isPrepared = false
    private var timeUpdateTask: Task<Void, Never>?

    private static let canonicalRate: Double = 48_000
    private let canonicalFormat: AVAudioFormat

    /// A single schedulable unit: a silent gap or a paragraph's audio.
    private struct PlayItem {
        let buffer: AVAudioPCMBuffer
        /// Non-nil for a paragraph's audio; nil for silence.
        let paragraphID: UUID?
        /// The paragraph that becomes current when this item finishes.
        let nextParagraphID: UUID?
        /// True for paragraph audio (fires paragraphChanged / finished).
        let isBoundary: Bool
    }

    public init(assets: any ContentAddressedStore) {
        self.assets = assets
        self.canonicalFormat = AVAudioFormat(
            standardFormatWithSampleRate: AVSegmentPlayer.canonicalRate,
            channels: 1
        ) ?? AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        self.currentTime = 0
        self.isPlaying = false
        let pair = AsyncStream<PlayerEvent>.makeStream(of: PlayerEvent.self)
        self.events = pair.stream
        self.eventContinuation = pair.continuation
    }

    // MARK: - SegmentPlayer

    public func load(_ segments: [PlaybackSegment]) async throws {
        self.segments = segments
        timeUpdateTask?.cancel()
        timeUpdateTask = nil
        try await prepareItems(startingAt: 0, startOffset: 0)
        currentParagraphID = segments.first?.paragraphID
        currentTime = 0
    }

    public func play() async throws {
        ensureGraph()
        guard isPrepared, !items.isEmpty else { throw AVSegmentPlayerError.nothingLoaded }

        if !engine.isRunning {
            try engine.start()
        }
        if !node.isPlaying {
            node.play()
        }
        isPlaying = true
        startTimeUpdates()
    }

    public func pause() async {
        node.pause()
        isPlaying = false
        timeUpdateTask?.cancel()
        timeUpdateTask = nil
    }

    public func seek(toParagraph id: UUID, offset: TimeInterval) async throws {
        guard let idx = segments.firstIndex(where: { $0.paragraphID == id }) else {
            throw AVSegmentPlayerError.paragraphNotFound
        }
        node.stop()
        node.reset()
        timeUpdateTask?.cancel()
        timeUpdateTask = nil
        try await prepareItems(startingAt: idx, startOffset: max(0, offset))
        currentParagraphID = id
        currentTime = max(0, offset)
        if isPlaying {
            try await play()
        }
    }

    public func nextParagraph() async throws {
        guard let current = currentParagraphID,
              let idx = segments.firstIndex(where: { $0.paragraphID == current }),
              idx + 1 < segments.count else { return }
        try await seek(toParagraph: segments[idx + 1].paragraphID, offset: 0)
    }

    public func previousParagraph() async throws {
        guard let current = currentParagraphID,
              let idx = segments.firstIndex(where: { $0.paragraphID == current }),
              idx > 0 else { return }
        try await seek(toParagraph: segments[idx - 1].paragraphID, offset: 0)
    }

    public func skip(by seconds: TimeInterval) async throws {
        let current = currentParagraphID ?? segments.first?.paragraphID
        guard let current else { return }
        let offset = max(0, currentTime + seconds)
        try await seek(toParagraph: current, offset: offset)
    }

    public func setRate(_ rate: Float) async {
        timePitch.rate = min(2.0, max(0.75, rate))
    }

    // MARK: - Time tracking

    private func startTimeUpdates() {
        timeUpdateTask?.cancel()
        timeUpdateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                self.updateCurrentTime()
            }
        }
    }

    private func updateCurrentTime() {
        guard let current = currentParagraphID,
              let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else { return }
        let start = audioStartFrame[current] ?? 0
        currentTime = max(0, Double(playerTime.sampleTime - start)) / canonicalFormat.sampleRate
    }

    // MARK: - Preparation

    private func ensureGraph() {
        guard !isPrepared else { return }
        engine.attach(node)
        engine.attach(timePitch)
        engine.connect(node, to: timePitch, format: canonicalFormat)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)
        timePitch.rate = 1.0
        engine.prepare()
        isPrepared = true
    }

    /// Build and schedule the play items, starting at `startIndex`. An optional
    /// `startOffset` slices the first paragraph's audio so seek lands mid-take.
    private func prepareItems(startingAt startIndex: Int, startOffset: TimeInterval) async throws {
        var newItems: [PlayItem] = []
        audioStartFrame = [:]
        scheduleCursor = 0

        for (i, segment) in segments.enumerated() {
            guard i >= startIndex else {
                scheduleCursor += 0
                continue
            }

            let isFirst = (i == startIndex)

            if !isFirst || startOffset == 0 {
                if segment.leadingSilence > 0 {
                    let silence = try makeSilenceBuffer(seconds: segment.leadingSilence)
                    newItems.append(PlayItem(buffer: silence, paragraphID: nil, nextParagraphID: nil, isBoundary: false))
                    scheduleCursor += AVAudioFramePosition(silence.frameLength)
                }
            }

            let audio = try await makeAudioBuffer(for: segment, startOffset: isFirst ? startOffset : 0)
            let nextID = i + 1 < segments.count ? segments[i + 1].paragraphID : nil
            audioStartFrame[segment.paragraphID] = scheduleCursor
            newItems.append(PlayItem(buffer: audio, paragraphID: segment.paragraphID, nextParagraphID: nextID, isBoundary: true))
            scheduleCursor += AVAudioFramePosition(audio.frameLength)

            if segment.trailingSilence > 0 {
                let silence = try makeSilenceBuffer(seconds: segment.trailingSilence)
                newItems.append(PlayItem(buffer: silence, paragraphID: nil, nextParagraphID: nil, isBoundary: false))
                scheduleCursor += AVAudioFramePosition(silence.frameLength)
            }
        }

        items = newItems
        node.reset()
        for item in items {
            let paragraphID = item.paragraphID
            let nextID = item.nextParagraphID
            let isBoundary = item.isBoundary
            node.scheduleBuffer(item.buffer) { [weak self] in
                Task { @MainActor in
                    self?.handleItemCompletion(
                        paragraphID: paragraphID,
                        nextID: nextID,
                        isBoundary: isBoundary
                    )
                }
            }
        }
    }

    private func handleItemCompletion(paragraphID: UUID?, nextID: UUID?, isBoundary: Bool) {
        guard isBoundary else { return }
        if let nextID {
            currentParagraphID = nextID
            currentTime = 0
            eventContinuation?.yield(.paragraphChanged(nextID))
        } else {
            currentParagraphID = paragraphID
            isPlaying = false
            eventContinuation?.yield(.finished)
        }
    }

    // MARK: - Buffer construction

    private func makeAudioBuffer(for segment: PlaybackSegment, startOffset: TimeInterval) async throws -> AVAudioPCMBuffer {
        let url = assets.url(for: segment.assetRef)
        let file = try AVAudioFile(forReading: url)
        let fileFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let fileBuffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: frameCount) else {
            throw AVSegmentPlayerError.bufferAllocation
        }
        try file.read(into: fileBuffer)

        var samples = try convertToCanonical(fileBuffer, from: fileFormat)
        let rate = canonicalFormat.sampleRate

        let startSample = max(0, min(samples.count, Int(segment.trim.lowerBound * rate)))
        let endSample = max(startSample, min(samples.count, Int(segment.trim.upperBound * rate)))
        var trimmed = Array(samples[startSample..<endSample])
        samples.removeAll(keepingCapacity: false)

        let offsetSample = min(trimmed.count, Int(startOffset * rate))
        if offsetSample > 0 {
            trimmed.removeFirst(offsetSample)
        }

        let gain = Float(pow(10, segment.gainDB / 20))
        let fadeInFrames = max(1, Int(segment.fadeIn * rate))
        let fadeOutFrames = max(1, Int(segment.fadeOut * rate))

        for i in trimmed.indices {
            var g = gain
            if i < fadeInFrames {
                g *= Float(i) / Float(fadeInFrames)
            }
            let fromEnd = trimmed.count - i
            if fromEnd <= fadeOutFrames {
                g *= Float(fromEnd) / Float(fadeOutFrames)
            }
            trimmed[i] *= g
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: AVAudioFrameCount(trimmed.count)) else {
            throw AVSegmentPlayerError.bufferAllocation
        }
        buffer.frameLength = AVAudioFrameCount(trimmed.count)
        if let data = buffer.floatChannelData {
            for i in trimmed.indices {
                data[0][i] = trimmed[i]
            }
        }
        return buffer
    }

    private func makeSilenceBuffer(seconds: TimeInterval) throws -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(max(0, seconds) * canonicalFormat.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: frames) else {
            throw AVSegmentPlayerError.bufferAllocation
        }
        buffer.frameLength = frames
        if let data = buffer.floatChannelData {
            for c in 0..<Int(canonicalFormat.channelCount) {
                for i in 0..<Int(frames) {
                    data[c][i] = 0
                }
            }
        }
        return buffer
    }

    /// Decode `fileBuffer` (arbitrary format/channel count) to a Float32 mono
    /// array at the canonical sample rate.
    private func convertToCanonical(_ buffer: AVAudioPCMBuffer, from format: AVAudioFormat) throws -> [Float] {
        guard let converter = AVAudioConverter(from: format, to: canonicalFormat) else {
            throw AVSegmentPlayerError.conversionUnavailable
        }

        let ratio = canonicalFormat.sampleRate / format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: capacity) else {
            throw AVSegmentPlayerError.bufferAllocation
        }

        let input = buffer
        let box = ConversionBox(buffer: input)
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if let b = box.buffer {
                box.buffer = nil
                status.pointee = .haveData
                return b
            }
            status.pointee = .noDataNow
            return nil
        }

        var result: [Float] = []
        var error: NSError?
        var done = false
        while !done {
            outBuffer.frameLength = 0
            let status = converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
            if let data = outBuffer.floatChannelData {
                for i in 0..<Int(outBuffer.frameLength) {
                    result.append(data[0][i])
                }
            }
            switch status {
            case .endOfStream:
                done = true
            case .error:
                throw error ?? AVSegmentPlayerError.conversionFailed
            default:
                if outBuffer.frameLength == 0 { done = true }
            }
        }
        return result
    }

    private final class ConversionBox: @unchecked Sendable {
        var buffer: AVAudioPCMBuffer?
        init(buffer: AVAudioPCMBuffer?) { self.buffer = buffer }
    }
}

public enum AVSegmentPlayerError: Error {
    case nothingLoaded
    case paragraphNotFound
    case bufferAllocation
    case conversionUnavailable
    case conversionFailed
}
