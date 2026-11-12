import Foundation
import VoxglassWatchCore

/// Speech synthesis stays on MainActor (AVSpeechSynthesizer callbacks require it).
/// Implementations write PCM to a temporary file and return its URL.
@MainActor
public protocol ReadWithAIWatchSpeechRendering: Sendable {
    func renderPCM(textURL: URL, preference: ReadWithAIVoicePreference) async throws -> URL
}

/// Cache of finished narration output keyed by profile+text+voice.
public protocol ReadWithAIWatchNarrationCaching: Sendable {
    /// Returns a validated, managed `.m4a`, or nil (removing the bad entry).
    func validCachedOutput(for key: String) -> URL?
    func storeValidated(_ output: URL, for key: String)
    func removeOutput(for key: String)
    func purgeLegacyEntries() throws
}

/// Runs the non-speech half of Read with AI Watch preparation off MainActor.
public actor ReadWithAIWatchPreparationAdapter {
    private let chapterID: UUID
    private let chapterKey: String
    private let directory: URL

    public init(chapterID: UUID, chapterKey: String, directory: URL) {
        self.chapterID = chapterID; self.chapterKey = chapterKey; self.directory = directory
    }

    /// Hashing, conversion, duration and size inspection run in the worker actor.
    public func prepareRenderedPCM(_ pcm: URL, worker: WatchAudioPreparationWorker) async throws -> PreparedWatchChapter {
        try await worker.prepareNarrationPCM(pcm, chapterID: chapterID, chapterKey: chapterKey, directory: directory)
    }

    /// Cache lookup (no speech when hit) -> MainActor speech render -> background conversion.
    /// The temporary PCM is always removed; the cached/finished output is never touched on failure.
    public func prepareNarration(
        textURL: URL,
        preference: ReadWithAIVoicePreference,
        renderer: any ReadWithAIWatchSpeechRendering,
        cache: any ReadWithAIWatchNarrationCaching,
        worker: WatchAudioPreparationWorker
    ) async throws -> PreparedWatchChapter {
        let key = try Self.cacheKey(textURL: textURL, preference: preference)
        try cache.purgeLegacyEntries()
        if let cached = cache.validCachedOutput(for: key) {
            do {
                return try await worker.prepareCachedNarration(cached, chapterID: chapterID, chapterKey: chapterKey)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                cache.removeOutput(for: key)
            }
        }
        try Task.checkCancellation()
        let pcm = try await renderer.renderPCM(textURL: textURL, preference: preference)
        defer { try? FileManager.default.removeItem(at: pcm) }
        let chapter = try await prepareRenderedPCM(pcm, worker: worker)
        do { try WatchAACAssetValidator.validate(chapter.url) }
        catch {
            try? FileManager.default.removeItem(at: chapter.url)
            throw error
        }
        cache.storeValidated(chapter.url, for: key)
        return chapter
    }

    static func cacheKey(textURL: URL, preference: ReadWithAIVoicePreference) throws -> String {
        let textHash = try WatchChecksum.sha256(of: textURL)
        let voiceKey = preference.identifier.isEmpty ? "automatic" : preference.identifier
        return SHA256Hex.hex(Data("aaclc48-v1|\(textHash)|\(voiceKey)|44100|2|48000".utf8))
    }
}
