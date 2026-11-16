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
        let writer = ReadWithAIWatchPCMWriter(url: url)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = ReadWithAISpeechAudioEngine.resolvedVoice(for: preference)

        do {
            _ = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                    writer.start(continuation)
                    guard !Task.isCancelled else { writer.cancel(); return }
                    synthesizer.write(utterance) { buffer in
                        writer.consume(buffer)
                    }
                }
            } onCancel: {
                writer.cancel()
            }
        } catch {
            // Stop this render before returning; a delayed cancellation task
            // could otherwise stop the next chapter's utterance.
            synthesizer.stopSpeaking(at: .immediate)
            throw error
        }
    }
}
