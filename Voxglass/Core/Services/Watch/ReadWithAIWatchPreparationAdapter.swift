import AVFoundation
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
        return SHA256Hex.hex(Data("aaclc48-v2|\(textHash)|\(voiceKey)|44100|2|48000".utf8))
    }
}

/// Owns one render's file and completion. Speech buffers are borrowed storage:
/// consume them synchronously inside the synthesizer callback, before returning.
/// The lock serializes file writes, cancellation, and the single continuation
/// resume; no AVFoundation handle escapes this protected state.
public final class ReadWithAIWatchPCMWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var file: AVAudioFile?
    private var continuation: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?

    public init(url: URL) { self.url = url }

    public func start(_ continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        defer { lock.unlock() }
        if let result { continuation.resume(with: result) }
        else { self.continuation = continuation }
    }

    public func consume(_ buffer: AVAudioBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard result == nil else { return }
        do {
            guard let pcm = buffer as? AVAudioPCMBuffer else {
                throw CocoaError(.fileWriteUnknown)
            }
            if pcm.frameLength == 0 {
                guard file != nil else { throw CocoaError(.fileWriteUnknown) }
                finish(.success(url))
            } else {
                if file == nil {
                    file = try AVAudioFile(forWriting: url, settings: pcm.format.settings)
                }
                guard let owned = Self.copyOwned(pcm) else { throw CocoaError(.fileWriteUnknown) }
                try file?.write(from: owned)
            }
        } catch { finish(.failure(error)) }
    }

    /// `write(from:)` is not documented to finish copying every frame out of
    /// `pcm` before returning, and `pcm` is storage the caller (the speech
    /// synthesizer, or this PR's own regression test) reuses for the very
    /// next callback. Deep-copy into buffer-owned memory first so there is
    /// never a window where the write races the next mutation of `pcm`.
    private static func copyOwned(_ pcm: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let owned = AVAudioPCMBuffer(pcmFormat: pcm.format, frameCapacity: pcm.frameLength) else {
            return nil
        }
        owned.frameLength = pcm.frameLength
        let src = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        let dst = UnsafeMutableAudioBufferListPointer(owned.mutableAudioBufferList)
        for i in 0..<src.count {
            guard let srcData = src[i].mData, let dstData = dst[i].mData else { continue }
            dstData.copyMemory(from: srcData, byteCount: Int(src[i].mDataByteSize))
        }
        return owned
    }

    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard result == nil else { return }
        finish(.failure(CancellationError()))
    }

    /// Called only while holding lock. Close the file before publishing its URL.
    private func finish(_ result: Result<URL, Error>) {
        file = nil
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}
