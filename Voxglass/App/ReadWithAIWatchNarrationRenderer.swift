import AVFoundation
import Foundation
import VoxglassCore
import VoxglassWatchCore

/// Renders a Read With AI text chapter once on the iPhone, then hands the
/// compact, ordinary AAC file to the existing Watch transfer path. The Watch
/// never needs to install the lower-quality system voice used for live speech.
@MainActor
final class ReadWithAIWatchNarrationRenderer {
    private static let cacheKeyPrefix = "readWithAI.watchNarration."
    private let synthesizer = AVSpeechSynthesizer()
    private var pcmFile: AVAudioFile?
    private var pcmURL: URL?
    private var continuation: CheckedContinuation<URL, Error>?

    func render(textURL: URL, directory: URL, preference: ReadWithAIVoicePreference) async throws -> URL {
        let text = try String(contentsOf: textURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let textHash = try WatchChecksum.sha256(of: textURL)
        let voiceKey = preference.identifier.isEmpty ? "automatic" : preference.identifier
        let voiceHash = SHA256Hex.hex(Data(voiceKey.utf8)).prefix(12)
        let cacheKey = Self.cacheKeyPrefix + textHash + "-" + voiceHash
        if let path = UserDefaults.standard.string(forKey: cacheKey),
           let audio = try? AVAudioFile(forReading: URL(fileURLWithPath: path)), audio.length > 0 {
            return URL(fileURLWithPath: path)
        }
        let pcm = directory.appendingPathComponent("\(textHash)-\(voiceHash)-speech.caf")
        defer { try? FileManager.default.removeItem(at: pcm) }

        // Prefer HE-AAC for speech at 32 kbps. Core Audio availability varies
        // by device/voice, so retry with universally supported AAC-LC at 48
        // kbps rather than making a chosen book impossible to transfer.
        if !FileManager.default.fileExists(atPath: pcm.path) {
            try await writePCM(text: text, voice: preference, to: pcm)
        }
        let pcmHash = try WatchChecksum.sha256(of: pcm)
        let output: URL
        do {
            output = try await WatchChapterTransfer.prepareAAC(
                source: pcm, directory: directory, sourceHash: pcmHash,
                bitRate: WatchNarrationEstimate.preferredBitRate,
                formatID: kAudioFormatMPEG4AAC_HE
            )
        } catch {
            output = try await WatchChapterTransfer.prepareAAC(
                source: pcm, directory: directory, sourceHash: pcmHash,
                bitRate: 48_000,
                formatID: kAudioFormatMPEG4AAC
            )
        }
        UserDefaults.standard.set(output.path, forKey: cacheKey)
        return output
    }

    private func writePCM(text: String, voice preference: ReadWithAIVoicePreference, to url: URL) async throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        pcmFile = nil
        pcmURL = url
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = ReadWithAISpeechAudioEngine.resolvedVoice(for: preference)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                self.continuation = continuation
                synthesizer.write(utterance) { [weak self] buffer in
                    Task { @MainActor in self?.consume(buffer) }
                }
            }
        } onCancel: {
            synthesizer.stopSpeaking(at: .immediate)
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
