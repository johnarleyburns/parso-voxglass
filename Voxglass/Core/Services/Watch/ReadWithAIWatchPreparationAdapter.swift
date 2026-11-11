import Foundation
import VoxglassWatchCore

/// Speech synthesis stays on MainActor (AVSpeechSynthesizer callbacks require it).
/// Implementations write PCM to a temporary file and return its URL.
@MainActor
public protocol ReadWithAIWatchSpeechRendering: Sendable {
    func renderPCM(textURL: URL, preference: ReadWithAIVoicePreference) async throws -> URL
}

/// Cache of finished narration output keyed by text+voice.
public protocol ReadWithAIWatchNarrationCaching: Sendable {
    func cachedOutput(for key: String) -> URL?
    func store(_ output: URL, for key: String)
    /// Forgets (and deletes from disk) an output that failed validation.
    func remove(for key: String)
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
        if let cached = cache.cachedOutput(for: key) {
            do {
                try WatchAACAssetValidator.validate(cached)
                return try await worker.prepareCachedNarration(cached, chapterID: chapterID, chapterKey: chapterKey)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A cache hit that fails validation is a miss: drop it and regenerate.
                cache.remove(for: key)
                try? FileManager.default.removeItem(at: cached)
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
        cache.store(chapter.url, for: key)
        return chapter
    }

    static func cacheKey(textURL: URL, preference: ReadWithAIVoicePreference) throws -> String {
        let textHash = try WatchChecksum.sha256(of: textURL)
        let voiceKey = preference.identifier.isEmpty ? "automatic" : preference.identifier
        return textHash + "-" + SHA256Hex.hex(Data(voiceKey.utf8)).prefix(12)
    }
}
