import AVFoundation
import Foundation
import Testing
@testable import VoxglassCore
import VoxglassWatchCore
import VoxglassWatchProtocol

/// A real narration artifact: produced by the live `WatchChapterTransfer.prepareAAC` path.
struct WatchNarrationFixture: Sendable {
    let url: URL
    let filename: String
    let bytes: Int64
    let sha256: String
    let duration: Double
    let bookID: WatchBookID
    let chapterID: WatchChapterID
    let chapterDTO: WatchChapterDTO
    let bookDTO: WatchBookDTO
    /// Generated profile, printed in failure diagnostics.
    static let profile = "AAC-LC/48kbps/44.1kHz/1ch"
}

/// Builds real PCM → AAC-LC M4A fixtures. Never fakes the final M4A with arbitrary Data
/// (except `makeUtf8NamedM4A`, which is deliberately the malformed negative case).
enum WatchNarrationFixtureFactory {
    static func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Tiny `.voxtext` input (content is never logged).
    static func makeVoxtext(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("chapter-\(UUID().uuidString).voxtext")
        try Data("fixture narration text".utf8).write(to: url)
        return url
    }

    /// Short deterministic mono PCM tone as `.caf`.
    static func makePCM(in dir: URL, seconds: Double = 1) throws -> URL {
        let url = dir.appendingPathComponent("pcm-\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = sinf(Float(i) * 0.05) * 0.3 }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    static func makeAACLCNarration(in directory: URL? = nil) async throws -> WatchNarrationFixture {
        let dir = try directory ?? makeDirectory()
        _ = try makeVoxtext(in: dir)
        let pcm = try makePCM(in: dir)
        let m4a = try await WatchChapterTransfer.prepareAAC(
            source: pcm, directory: dir.appendingPathComponent("out", isDirectory: true),
            bitRate: WatchNarrationEstimate.watchAACLCBitRate, formatID: kAudioFormatMPEG4AAC)
        return try fixture(for: m4a)
    }

    /// A non-audio file named `.m4a`, with self-consistent byte/hash metadata so integrity passes.
    static func makeUtf8NamedM4A(in directory: URL? = nil) throws -> WatchNarrationFixture {
        let dir = try directory ?? makeDirectory()
        let url = dir.appendingPathComponent("not-audio-\(UUID().uuidString).m4a")
        try Data("this is utf8 text, not AAC".utf8).write(to: url)
        return try fixture(for: url, duration: 1)
    }

    static func fixture(for url: URL, duration: Double? = nil) throws -> WatchNarrationFixture {
        let bytes = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let sha = try WatchChecksum.sha256(of: url)
        let resolved: Double
        if let duration { resolved = duration }
        else {
            let audio = try AVAudioFile(forReading: url)
            resolved = Double(audio.length) / audio.processingFormat.sampleRate
        }
        let bookID = WatchBookID("book-\(UUID().uuidString)")
        let chapterID = WatchChapterID("chapter-\(UUID().uuidString)")
        let filename = url.lastPathComponent
        let chapter = WatchChapterDTO(id: chapterID, index: 0, title: "Read With AI", duration: resolved,
            startTime: 0, expectedBytes: bytes, expectedSHA256: sha, durableFilename: filename)
        let book = WatchBookDTO(id: bookID, title: "Fixture", duration: resolved, chapters: [chapter])
        return WatchNarrationFixture(url: url, filename: filename, bytes: bytes, sha256: sha,
            duration: resolved, bookID: bookID, chapterID: chapterID, chapterDTO: chapter, bookDTO: book)
    }

    /// Diagnostics for failures. Never includes listener text.
    static func diagnostics(_ f: WatchNarrationFixture, error: Error? = nil) -> String {
        var format = "unreadable"
        if let audio = try? AVAudioFile(forReading: f.url) { format = audio.fileFormat.description }
        let validator = (error as? WatchAACAssetValidationError).map { "\($0)" } ?? error.map { "\($0)" } ?? "none"
        return "artifact=\(f.url.path) bytes=\(f.bytes) sha256=\(f.sha256) format=[\(format)] validatorError=\(validator) profile=\(WatchNarrationFixture.profile)"
    }

    static func validate(_ f: WatchNarrationFixture) throws {
        do { try WatchAACAssetValidator.validate(f.url) }
        catch {
            Issue.record(Comment(rawValue: diagnostics(f, error: error)))
            throw error
        }
    }
}

@MainActor
private final class RealPCMRenderer: ReadWithAIWatchSpeechRendering {
    var calls = 0
    let directory: URL
    init(directory: URL) { self.directory = directory }
    func renderPCM(textURL: URL, preference: ReadWithAIVoicePreference) async throws -> URL {
        calls += 1
        return try WatchNarrationFixtureFactory.makePCM(in: directory)
    }
}

@Suite struct WatchNarrationEndToEndTests {
    private func install(_ f: WatchNarrationFixture, root: URL) throws -> URL {
        try WatchPhonePushFiles.install(
            source: f.url, root: root, bookID: f.bookID.rawValue, filename: f.filename,
            expectedBytes: f.bytes, expectedSHA256: f.sha256,
            validateAudio: WatchAACAssetValidator.validate)
    }

    @Test func generatedReadWithAINarrationPassesSharedWatchValidator() async throws {
        let fixture = try await WatchNarrationFixtureFactory.makeAACLCNarration()
        try WatchNarrationFixtureFactory.validate(fixture)
        #expect(fixture.bytes > 0)
        #expect(fixture.duration > 0)
        let audio = try AVAudioFile(forReading: fixture.url)
        #expect(audio.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        #expect(fixture.url.lastPathComponent.contains("watch-aac48"))
    }

    @Test func validNarrationInstallsAndProducesCompleteWatchManifest() async throws {
        let fixture = try await WatchNarrationFixtureFactory.makeAACLCNarration()
        let root = try WatchNarrationFixtureFactory.makeDirectory()
        do { _ = try install(fixture, root: root) }
        catch {
            Issue.record(Comment(rawValue: WatchNarrationFixtureFactory.diagnostics(fixture, error: error)))
            throw error
        }
        let report = WatchPhonePushFiles.report(book: fixture.bookDTO, root: root)
        #expect(report.complete)
        #expect(report.installedChapterIDs == [fixture.chapterID])
        #expect(report.installedBytes == fixture.bytes)
    }

    @Test func checksumValidButNonAudioNarrationIsRejectedBeforeInstall() throws {
        let corrupt = try WatchNarrationFixtureFactory.makeUtf8NamedM4A()
        let root = try WatchNarrationFixtureFactory.makeDirectory()
        let destination = root.appendingPathComponent(corrupt.bookID.rawValue)
            .appendingPathComponent(corrupt.filename)
        // Integrity passes: the failure must come from audio validation specifically.
        #expect(try WatchChecksum.sha256(of: corrupt.url) == corrupt.sha256)
        #expect(throws: WatchAACAssetValidationError.self) { _ = try install(corrupt, root: root) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let report = WatchPhonePushFiles.report(book: corrupt.bookDTO, root: root)
        #expect(!report.complete && report.installedChapterIDs == [])
    }

    @Test func installRejectionPropagatesToPhoneAsFailedWithDetail() async throws {
        let corrupt = try WatchNarrationFixtureFactory.makeUtf8NamedM4A()
        let root = try WatchNarrationFixtureFactory.makeDirectory()
        var reason = ""
        do { _ = try install(corrupt, root: root) }
        catch { reason = error.localizedDescription }
        #expect(!reason.isEmpty)

        let message = WatchTransferStatusCopy.watchRejection(chapterOrdinal: 1, reason: reason)
        var ack = WatchManifestAcknowledgement(bookID: corrupt.bookID, revision: 1, complete: false, installedBytes: 0)
        ack.failureMessage = message

        let store = PhoneWatchProjectionStore(
            url: root.appendingPathComponent("projection.json"), libraryID: "library")
        try await store.markSubmitted(corrupt.bookID, at: Date(timeIntervalSince1970: 0))
        try await store.acknowledge(ack)
        let state = await store.current()
        #expect(state.desired[corrupt.bookID] == .failed(message))
        #expect(await store.isTruthfullyDownloaded(corrupt.bookID) == false)

        let desired = state.desired[corrupt.bookID]
        let storage = WatchAcknowledgedStorageResolver.resolve(
            acknowledgement: ack, desiredState: desired, priorStorageState: nil)
        #expect(storage == .failed)
        #expect(WatchTransferStatusCopy.resolve(state: desired, acknowledgement: ack) == message)
        #expect(message.contains(reason))
        #expect(!WatchTransferStatusCopy.isInstalled(state: desired, acknowledgement: ack))
        let banner = WatchTransferStatusBannerResolver.resolve(
            desiredStates: state.desired, storageStates: [corrupt.bookID: storage])
        #expect(banner?.downloadedCount == 0)
        #expect(banner?.failedCount == 1)
    }

    @Test @MainActor func legacyCacheEntryTriggersFreshAACLCRenderValidateAndInstall() async throws {
        let dir = try WatchNarrationFixtureFactory.makeDirectory()
        let name = "rwai-e2e-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let cache = ReadWithAIWatchNarrationUserDefaultsCache(suiteName: name, managedRoot: dir)
        let text = try WatchNarrationFixtureFactory.makeVoxtext(in: dir)
        let pref = ReadWithAIVoicePreference(identifier: "")
        let key = try ReadWithAIWatchPreparationAdapter.cacheKey(textURL: text, preference: pref)

        // Legacy artifact: wrong format (not AAC-LC), stored under the old key prefix.
        let legacy = dir.appendingPathComponent("legacy.m4a")
        try Data("legacy artifact".utf8).write(to: legacy)
        defaults.set(legacy.path, forKey: ReadWithAIWatchNarrationUserDefaultsCache.legacyPrefix + key)

        let renderer = RealPCMRenderer(directory: dir)
        let adapter = ReadWithAIWatchPreparationAdapter(
            chapterID: UUID(), chapterKey: "k", directory: dir.appendingPathComponent("out", isDirectory: true))
        let chapter = try await adapter.prepareNarration(
            textURL: text, preference: pref, renderer: renderer, cache: cache,
            worker: WatchAudioPreparationWorker(dependencies: .live(artwork: { _ in nil })))
        #expect(renderer.calls == 1)
        #expect(chapter.url != legacy)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))

        let fixture = try WatchNarrationFixtureFactory.fixture(for: chapter.url)
        try WatchNarrationFixtureFactory.validate(fixture)
        #expect(fixture.sha256 == chapter.sha256 && fixture.bytes == chapter.bytes)

        let root = try WatchNarrationFixtureFactory.makeDirectory()
        _ = try install(fixture, root: root)
        let report = WatchPhonePushFiles.report(book: fixture.bookDTO, root: root)
        #expect(report.complete)
    }
}
