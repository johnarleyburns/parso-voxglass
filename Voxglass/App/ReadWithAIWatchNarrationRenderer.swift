import AVFoundation
import Foundation
import VoxglassCore
import VoxglassWatchCore

/// Narrow MainActor adapter: only `AVSpeechSynthesizer` rendering lives here.
/// PCM hashing, AAC conversion, duration/size inspection and chapter assembly
/// run in `ReadWithAIWatchPreparationAdapter` / `WatchAudioPreparationWorker`.
@MainActor
final class ReadWithAIWatchNarrationRenderer: ReadWithAIWatchSpeechRendering {
    private let synthesizer = AVSpeechSynthesizer()
    private var pcmFile: AVAudioFile?
    private var pcmURL: URL?
    private var continuation: CheckedContinuation<URL, Error>?
    private let directory: URL

    init(directory: URL) { self.directory = directory }

    func renderPCM(textURL: URL, preference: ReadWithAIVoicePreference) async throws -> URL {
        let text = try String(contentsOf: textURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let voiceKey = preference.identifier.isEmpty ? "automatic" : preference.identifier
        let voiceHash = SHA256Hex.hex(Data(voiceKey.utf8)).prefix(12)
        let pcm = directory.appendingPathComponent(
            "\(textURL.deletingPathExtension().lastPathComponent)-\(voiceHash)-speech.caf")
        do {
            try await writePCM(text: text, voice: preference, to: pcm)
        } catch {
            try? FileManager.default.removeItem(at: pcm)
            throw error
        }
        return pcm
    }

    private func writePCM(text: String, voice preference: ReadWithAIVoicePreference, to url: URL) async throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        pcmFile = nil
        pcmURL = url
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = ReadWithAISpeechAudioEngine.resolvedVoice(for: preference)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                self.continuation = continuation
                synthesizer.write(utterance) { [weak self] buffer in
                    Task { @MainActor in self?.consume(buffer) }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.synthesizer.stopSpeaking(at: .immediate)
                self?.finish(.failure(CancellationError()))
            }
        }
    }

    private func consume(_ buffer: AVAudioBuffer) {
        guard let continuation else { return }
        guard let pcm = buffer as? AVAudioPCMBuffer else {
            finish(.failure(CocoaError(.fileWriteUnknown)))
            return
        }
        if pcm.frameLength == 0 {
            guard let pcmURL else {
                finish(.failure(CocoaError(.fileWriteUnknown)))
                return
            }
            finish(.success(pcmURL))
            return
        }
        do {
            if pcmFile == nil {
                guard let pcmURL else { throw CocoaError(.fileWriteUnknown) }
                pcmFile = try AVAudioFile(forWriting: pcmURL, settings: pcm.format.settings)
            }
            try pcmFile?.write(from: pcm)
        } catch {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        let continuation = continuation
        self.continuation = nil
        pcmFile = nil
        pcmURL = nil
        switch result {
        case .success(let url): continuation?.resume(returning: url)
        case .failure(let error): continuation?.resume(throwing: error)
        }
    }
}

/// UserDefaults-backed cache of finished narration output (survives relaunch).
struct ReadWithAIWatchNarrationUserDefaultsCache: ReadWithAIWatchNarrationCaching {
    private static let prefix = "readWithAI.watchNarration."
    func cachedOutput(for key: String) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: Self.prefix + key),
              (try? WatchAACAssetValidator.validate(URL(fileURLWithPath: path))) != nil else { return nil }
        return URL(fileURLWithPath: path)
    }
    func remove(for key: String) {
        if let path = UserDefaults.standard.string(forKey: Self.prefix + key) {
            try? FileManager.default.removeItem(atPath: path)
        }
        UserDefaults.standard.removeObject(forKey: Self.prefix + key)
    }
    func store(_ output: URL, for key: String) {
        UserDefaults.standard.set(output.path, forKey: Self.prefix + key)
    }
}
