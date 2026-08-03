import Foundation
import VoxglassCore

// MARK: - UITest fakes
//
// Gate G-9 forbids `VoxglassCoreTestSupport` in a shipping target, so the
// `.test(seed:)` environment wires its own fakes here, mirroring the Core
// fakes (spec §19.2). Compiled only in DEBUG; the `UITestSeed` type itself
// stays compiled in all configurations so gate G-8 can find it (§19.6).

#if DEBUG

// MARK: - Capture

/// Scripted `AudioCapturing` for the seeded UI-test environment. Never touches
/// a microphone; produces a silent WAV of the requested duration so takes
/// ingest cleanly.
public final class UITestAudioCapture: AudioCapturing, @unchecked Sendable {
    public var state: CaptureState = .idle
    public let levels: AsyncStream<CaptureLevels>
    public var onStartRecording: ((URL) -> Void)?

    private let clock: any Clock
    private let ids: any IDGenerator
    private var format = RecordingDefaults()
    private var lastDestinationURL: URL?

    public init(clock: any Clock, ids: any IDGenerator) {
        self.clock = clock
        self.ids = ids
        self.levels = AsyncStream { _ in }
    }

    public func availableInputDevices() async -> [AudioDeviceInfo] {
        [AudioDeviceInfo(id: "ui-test-input", name: "UI Test Input", channelCount: 1, supportedSampleRates: [44_100, 48_000], isDefault: true, transport: "virtual")]
    }

    public func prepare(device: String?, format: RecordingDefaults) async throws {
        self.format = format
        state = .prepared
    }

    public func startMonitoring() async throws {
        state = .monitoring
    }

    public func stopMonitoring() async {
        state = .prepared
    }

    public func startRecording(to destinationURL: URL) async throws {
        state = .recording
        lastDestinationURL = destinationURL
        let sampleRate = Int(format.sampleRate)
        let frames = sampleRate * 2
        var samples = [Int16](repeating: 0, count: frames)
        let data = samples.withUnsafeBytes { Data($0) }
        var wav = Data("RIFF".utf8)
        let dataSize = Int32(data.count)
        let chunkSize = dataSize + 36
        wav.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian) { Data($0) })
        wav.append(Data("WAVE".utf8))
        wav.append(Data("fmt ".utf8))
        wav.append(contentsOf: withUnsafeBytes(of: Int32(16).littleEndian) { Data($0) })
        wav.append(contentsOf: withUnsafeBytes(of: Int16(1).littleEndian) { Data($0) })
        wav.append(contentsOf: withUnsafeBytes(of: Int16(1).littleEndian) { Data($0) })
        wav.append(contentsOf: withUnsafeBytes(of: Int32(sampleRate).littleEndian) { Data($0) })
        wav.append(contentsOf: withUnsafeBytes(of: Int32(sampleRate * 2).littleEndian) { Data($0) })
        wav.append(contentsOf: withUnsafeBytes(of: Int16(2).littleEndian) { Data($0) })
        wav.append(contentsOf: withUnsafeBytes(of: Int16(16).littleEndian) { Data($0) })
        wav.append(Data("data".utf8))
        wav.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        wav.append(data)
        try wav.write(to: destinationURL)
        onStartRecording?(destinationURL)
    }

    public func stopRecording() async throws -> CapturedTake {
        state = .prepared
        return CapturedTake(
            fileURL: lastDestinationURL ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ui-test-take.wav"),
            duration: 2.0,
            format: AudioFormatDescription(sampleRate: format.sampleRate, channels: 1, bitDepth: format.bitDepth, codec: "pcm"),
            clippedDuringCapture: false,
            peakDBFS: -60
        )
    }

    public func cancelRecording() async {
        state = .prepared
    }

    public func punchIn(from offset: TimeInterval) async throws {
        throw CaptureError.punchInNotSupported
    }
}

// MARK: - Sync

/// No-op transport: the seeded environment must never reach CloudKit.
public final class UITestSyncTransport: ProductionSyncTransport, @unchecked Sendable {
    public init() {}
    public func accountStatus() async -> SyncAccountStatus { .notAuthenticated }
    public func fetchZoneChanges(after token: SyncChangeToken?) async throws -> ZoneFetchResult {
        ZoneFetchResult()
    }
    public func pushRecords(_ records: [SyncRecord]) async throws {}
    public func deleteRecords(_ recordNames: [String]) async throws {}
}

/// In-memory `SyncStateStore` mirror for the seeded environment.
public actor UITestSyncStateStore: SyncStateStore {
    private var snapshot: SyncProjection?
    private var token: SyncChangeToken?
    private var publishDates: [UUID: Date] = [:]

    public init() {}

    public func projectionSnapshot(projectID: UUID) async throws -> SyncProjection? { snapshot }
    public func setProjectionSnapshot(_ projection: SyncProjection?, projectID: UUID) async throws {
        snapshot = projection
    }
    public func changeToken() async throws -> SyncChangeToken? { token }
    public func setChangeToken(_ token: SyncChangeToken?) async throws { self.token = token }
    public func lastPublishDate(projectID: UUID) async throws -> Date? { publishDates[projectID] }
    public func setLastPublishDate(_ date: Date?, projectID: UUID) async throws {
        publishDates[projectID] = date
    }
    public func clear() async throws {
        snapshot = nil
        token = nil
        publishDates = [:]
    }
}

// MARK: - License

public final class UITestLicenseProvider: LicenseProvider, @unchecked Sendable {
    private let continuation: AsyncStream<EntitlementState>.Continuation
    public let updates: AsyncStream<EntitlementState>

    public init() {
        var c: AsyncStream<EntitlementState>.Continuation!
        updates = AsyncStream { c = $0 }
        continuation = c
    }

    public var entitlement: EntitlementState { .free }
    public func refresh() async {}
    public func purchasePro() async throws -> EntitlementState { .free }
    public func restore() async throws -> EntitlementState { .free }
    public func product() async throws -> ProductInfo {
        ProductInfo(displayPrice: "$149", displayName: "Voxglass Studio Pro", description: "Pro")
    }
}

// MARK: - Transcoder

/// Minimal `AudioTranscoding` for the seeded environment: copies the input.
public struct UITestTranscoder: AudioTranscoding {
    public var availableEncoders: Set<Codec> { [.mp3, .flac, .pcm, .aacLC, .alac] }

    public init() {}

    public func transcode(
        input: URL,
        to spec: AudioSpec,
        tags: AudioTags,
        output: URL,
        progress: @Sendable (Double) -> Void
    ) async throws -> ExportedFile {
        try FileManager.default.copyItem(at: input, to: output)
        return ExportedFile(
            url: output,
            role: .chapter,
            byteCount: (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64) ?? 0
        )
    }

    public func concatenate(
        _ inputs: [URL],
        to spec: AudioSpec,
        chapters: [ChapterMark]?,
        tags: AudioTags,
        output: URL
    ) async throws -> ExportedFile {
        var data = Data()
        for input in inputs {
            data.append(try Data(contentsOf: input))
        }
        try data.write(to: output)
        return ExportedFile(url: output, role: .chapter, byteCount: Int64(data.count))
    }

    public func master(input: URL, target: MasteringTarget, output: URL) async throws -> ExportedFile {
        try FileManager.default.copyItem(at: input, to: output)
        return ExportedFile(
            url: output,
            role: .master,
            byteCount: (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64) ?? 0
        )
    }
}

// MARK: - Metrics / Player / Clock / IDs

public struct UITestMetricsCalculator: AudioMetricsCalculating {
    public init() {}
    public func metrics(for url: URL) async throws -> AudioQualityMetrics {
        AudioQualityMetrics(
            peakDBFS: -40, truePeakDBFS: -40, rmsDBFS: -55,
            noiseFloorDBFS: -70, clipCount: 0, dcOffset: 0,
            leadingSilence: 0, trailingSilence: 0,
            duration: 0, sampleRate: 48_000, channels: 1, analyzerVersion: 1
        )
    }
    public func metrics(for samples: [Float], sampleRate: Double, channels: Int) -> AudioQualityMetrics {
        AudioQualityMetrics(
            peakDBFS: -40, truePeakDBFS: -40, rmsDBFS: -55,
            noiseFloorDBFS: -70, clipCount: 0, dcOffset: 0,
            leadingSilence: 0, trailingSilence: 0,
            duration: Double(samples.count) / sampleRate, sampleRate: sampleRate, channels: channels, analyzerVersion: 1
        )
    }
}

public final class UITestSegmentPlayer: SegmentPlayer, @unchecked Sendable {
    public var currentParagraphID: UUID?
    public var currentTime: TimeInterval = 0
    public var isPlaying = false
    public let events: AsyncStream<PlayerEvent>

    public init() {
        events = AsyncStream { _ in }
    }
    public func load(_ segments: [PlaybackSegment]) async throws {}
    public func play() async throws { isPlaying = true }
    public func pause() async { isPlaying = false }
    public func seek(toParagraph id: UUID, offset: TimeInterval) async throws { currentParagraphID = id }
    public func nextParagraph() async throws {}
    public func previousParagraph() async throws {}
    public func skip(by seconds: TimeInterval) async {}
    public func setRate(_ rate: Float) async {}
}

public struct UITestFixedClock: Clock {
    public var now: Date { Date(timeIntervalSince1970: 1_700_000_000) }
    public init() {}
}

public final class UITestSequentialIDGenerator: IDGenerator, @unchecked Sendable {
    private let lock = NSLock()
    private var counter: UInt64 = 0
    public init() {}
    public func next() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        return UUID(uuidString: String(format: "%08X-0000-0000-0000-000000000000", counter))!
    }
}

#endif
