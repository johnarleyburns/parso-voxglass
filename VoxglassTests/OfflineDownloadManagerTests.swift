import Testing
import Foundation
import AVFoundation
import ParsoAudioStreaming
@testable import VoxglassCore

@MainActor
@Suite struct OfflineDownloadManagerTests {

    // MARK: - §7 cellular / Pro gate decision

    @Test func startDecisionPromptsOnCellularWhenToggleOff() {
        let decision = OfflineDownloadManager.startDecision(
            isCellular: true, cacheOnCellular: false, allowCellularOverride: false
        )
        #expect(decision == .needsCellularConfirmation)
    }

    @Test func startDecisionStartsOnCellularWhenToggleOn() {
        let decision = OfflineDownloadManager.startDecision(
            isCellular: true, cacheOnCellular: true, allowCellularOverride: false
        )
        #expect(decision == .start)
    }

    @Test func startDecisionStartsOnCellularWithOverride() {
        let decision = OfflineDownloadManager.startDecision(
            isCellular: true, cacheOnCellular: false, allowCellularOverride: true
        )
        #expect(decision == .start)
    }

    @Test func startDecisionStartsOnWiFi() {
        let decision = OfflineDownloadManager.startDecision(
            isCellular: false, cacheOnCellular: false, allowCellularOverride: false
        )
        #expect(decision == .start)
    }

    // MARK: - §7 state derivation

    @Test func derivedStateAllChaptersCompleteIsCached() {
        #expect(OfflineDownloadManager.derivedState(chapterComplete: [true, true, true], anyFailed: false) == .cached)
    }

    @Test func derivedStatePartialIsDownloading() {
        #expect(OfflineDownloadManager.derivedState(chapterComplete: [true, false, false], anyFailed: false) == .downloading(progress: 1.0 / 3.0))
    }

    @Test func derivedStateNoneCompleteIsNotCached() {
        #expect(OfflineDownloadManager.derivedState(chapterComplete: [false, false], anyFailed: false) == .notCached)
    }

    @Test func derivedStateEmptyIsNotCached() {
        #expect(OfflineDownloadManager.derivedState(chapterComplete: [], anyFailed: false) == .notCached)
    }

    @Test func derivedStatePartialWithFailureIsFailed() {
        #expect(OfflineDownloadManager.derivedState(chapterComplete: [true, false], anyFailed: true) == .failed)
    }

    // MARK: - §A5 pin-count (call-site test — must exercise the real state filter)

    @Test func pinCountCountsCachedAndDownloading() {
        var states: [UUID: OfflineState] = [
            UUID(): .cached,
            UUID(): .downloading(progress: 0.5),
            UUID(): .failed,
            UUID(): .notCached
        ]
        #expect(OfflineDownloadManager.pinCount(states: states) == 2)
    }



    // MARK: - §6/§7 stable cache keys

    @Test func audioCacheKeyIsStableAcrossCalls() {
        let url = URL(string: "https://archive.org/download/item/01%20Chapter.mp3")!
        #expect(AudioCache.key(for: url) == AudioCache.key(for: url))
    }

    @Test func audioCacheKeyIsSHA256Hex() {
        let url = URL(string: "https://archive.org/download/item/01%20Chapter.mp3")!
        let key = AudioCache.key(for: url)
        #expect(key.hasSuffix("-mp3"))
        let hex = key.replacingOccurrences(of: "-mp3", with: "")
        #expect(hex.count == 64)  // SHA256 hex digest is 64 characters
        #expect(hex.allSatisfy { $0.isHexDigit })
        #expect(!(key.hasPrefix("art_")))  // Audio keys must not collide with artwork keys
    }

    @Test func cacheBlobNameRetainsEnoughTypeInformationForAVFoundation() {
        let remote = URL(string: "https://archive.org/download/item/chapter.mp3")!
        let blob = URL(fileURLWithPath: "/tmp/\(AudioCache.key(for: remote))")

        #expect(blob.pathExtension.isEmpty)
        #expect(RemoteAudioURL.contentTypeMIME(for: blob) == "audio/mpeg")
        #expect(RemoteAudioURL.contentTypeMIME(for: remote) == "audio/mpeg")
    }

    /// Regression guard for the original symptom: cache keys end in `-mp3`,
    /// not `.mp3`, so AVFoundation rejects a downloaded blob unless playback
    /// supplies the MIME type explicitly.
    @Test func extensionlessDownloadedBlobNeedsAndAcceptsExplicitMIMEType() async throws {
        let source = try #require(Bundle.module.url(
            forResource: "tone-1khz-20dbfs", withExtension: "wav", subdirectory: "ReplayGain"
        ))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("extensionless-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let blob = directory.appendingPathComponent("cache-key-wav")
        try FileManager.default.copyItem(at: source, to: blob)

        let withoutType = AVURLAsset(url: blob)
        #expect((try? await withoutType.load(.isPlayable)) != true)

        let withType = AVURLAsset(
            url: blob,
            options: [AVURLAssetOverrideMIMETypeKey: RemoteAudioURL.contentTypeMIME(for: blob)!]
        )
        #expect(try await withType.load(.isPlayable))
    }

    // MARK: - Deferred background-session activation

    private final class FactoryCounter: @unchecked Sendable {   // test-only; guarded by lock
        private let lock = NSLock()
        private var count = 0
        private var failuresRemaining: Int
        init(failures: Int = 0) { failuresRemaining = failures }
        var calls: Int { lock.withLock { count } }
        func next() throws {
            try lock.withLock {
                count += 1
                if failuresRemaining > 0 {
                    failuresRemaining -= 1
                    throw URLError(.cannotConnectToHost)
                }
            }
        }
    }

    private func makeManager(
        counter: FactoryCounter,
        relay: OfflineBackgroundEventRelay
    ) throws -> OfflineDownloadManager {
        let defaults = try #require(UserDefaults(suiteName: "offline-activation-\(UUID().uuidString)"))
        let repository = LibraryRepository(database: AppDatabase.makeTemporaryDatabase(named: "offline-activation-\(UUID().uuidString)"))
        return OfflineDownloadManager(
            repository: repository,
            defaults: defaults,
            sessionFactory: { _ in
                try counter.next()
                return URLSession(configuration: .ephemeral)
            },
            backgroundEvents: relay
        )
    }

    @Test func constructionDoesNotCreateSession() throws {
        let counter = FactoryCounter()
        let manager = try makeManager(counter: counter, relay: OfflineBackgroundEventRelay())
        #expect(counter.calls == 0)
        #expect(!manager.isSessionActive)
    }

    @Test func concurrentActivationCreatesOneSession() async throws {
        let counter = FactoryCounter()
        let manager = try makeManager(counter: counter, relay: OfflineBackgroundEventRelay())
        async let a = manager.activateSession()
        async let b = manager.activateSession()
        let results = await [a, b]
        #expect(results == [true, true])
        #expect(await manager.activateSession())
        #expect(counter.calls == 1)
    }

    @Test func failedActivationCanBeRetried() async throws {
        let counter = FactoryCounter(failures: 1)
        let manager = try makeManager(counter: counter, relay: OfflineBackgroundEventRelay())
        #expect(await manager.activateSession() == false)
        #expect(!manager.isSessionActive)
        #expect(await manager.activateSession() == true)
        #expect(counter.calls == 2)
    }

    @Test func backgroundEventsBeforeActivationAreHeldThenCompletedOnce() async throws {
        let counter = FactoryCounter()
        let relay = OfflineBackgroundEventRelay()
        let manager = try makeManager(counter: counter, relay: relay)
        var completions = 0
        relay.receive(identifier: OfflineDownloadManager.sessionIdentifier) { completions += 1 }
        #expect(completions == 0)
        #expect(await manager.activateSession())
        #expect(completions == 0)   // held until the session reports all events handled
        manager.urlSessionDidFinishEvents(forBackgroundURLSession: URLSession(configuration: .ephemeral))
        try await Task.sleep(for: .milliseconds(100))
        #expect(completions == 1)
        manager.urlSessionDidFinishEvents(forBackgroundURLSession: URLSession(configuration: .ephemeral))
        try await Task.sleep(for: .milliseconds(100))
        #expect(completions == 1)
    }

    @Test func backgroundEventsAfterActivationCompleteOnce() async throws {
        let relay = OfflineBackgroundEventRelay()
        let manager = try makeManager(counter: FactoryCounter(), relay: relay)
        #expect(await manager.activateSession())
        var completions = 0
        relay.receive(identifier: OfflineDownloadManager.sessionIdentifier) { completions += 1 }
        #expect(completions == 0)
        manager.urlSessionDidFinishEvents(forBackgroundURLSession: URLSession(configuration: .ephemeral))
        try await Task.sleep(for: .milliseconds(100))
        #expect(completions == 1)
    }

    @Test func unknownSessionIdentifierCompletesImmediately() {
        var completions = 0
        OfflineBackgroundEventRelay().receive(identifier: "other") { completions += 1 }
        #expect(completions == 1)
    }
}
