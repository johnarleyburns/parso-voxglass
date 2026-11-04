import AVFoundation
import Foundation
import VoxglassCore

/// AVSpeechSynthesizer-backed implementation of the existing playback seam.
/// `.voxtext` chapters are local, app-owned UTF-8 files; all other URLs remain
/// the responsibility of AVPlayerAudioEngine.
@MainActor
final class ReadWithAISpeechAudioEngine: NSObject, AudioEngine, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var text = ""
    private var utteranceStart = 0
    private var position: TimeInterval = 0
    private var estimatedDuration: TimeInterval?
    private var speaking = false
    private var activeRate: Float = 1
    private var activeVolume: Float = 1
    private var speechGeneration = 0

    var onPlaybackEnded: (@MainActor () -> Void)?
    var onPlaybackIssue: (@MainActor (AudioEngineIssue) -> Void)?
    var onItemChanged: (@MainActor () -> Void)?
    var onSilenceChanged: (@MainActor (Bool) -> Void)?
    var currentTime: TimeInterval { position }
    var duration: TimeInterval? { estimatedDuration }
    var isPlaying: Bool { speaking }
    var isReady: Bool { !text.isEmpty }
    var rate: Float { activeRate }
    var volume: Float { get { activeVolume } set { activeVolume = newValue } }
    var isEQEngaged: Bool { false }
    var hasPreloadedItem: Bool { false }
    var isCurrentItemPreloaded: Bool { false }
    var lastEndPosition: TimeInterval = 0
    var lastEndDuration: TimeInterval?
    var lastEndWasVerified = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.allowAirPlay, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            onPlaybackIssue?(.failed(error.localizedDescription))
        }
    }

    func load(url: URL, startTime: TimeInterval, lease: PlaybackLease?) async throws {
        defer { lease?.release() }
        guard url.pathExtension == "voxtext" else { throw AudioEngineError.unplayableAudio }
        stopImmediately()
        text = try String(contentsOf: url, encoding: .utf8)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AudioEngineError.unplayableAudio }
        estimatedDuration = Self.duration(for: text, rate: activeRate)
        position = min(max(0, startTime), estimatedDuration ?? startTime)
        utteranceStart = Self.characterOffset(in: text, at: position, rate: activeRate)
        lastEndPosition = 0
        lastEndDuration = estimatedDuration
        lastEndWasVerified = false
    }

    func play() { speak(from: utteranceStart) }
    func pause() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.pauseSpeaking(at: .word)
    }
    func seek(to position: TimeInterval) async {
        self.position = min(max(0, position), estimatedDuration ?? position)
        utteranceStart = Self.characterOffset(in: text, at: self.position, rate: activeRate)
        let resume = speaking
        stopImmediately()
        if resume { speak(from: utteranceStart) }
    }
    func setRate(_ rate: Float) {
        activeRate = min(max(rate, 0.5), 2.0)
    }
    func preloadNext(url: URL, lease: PlaybackLease?) { lease?.release() }
    func cancelPreload() {}
    func releasePlaybackLeases() {}
    func prefetchIntoCache(urls: [URL]) {}
    func setEQEngaged(_ engaged: Bool) {}
    func applyEQPreset(_ preset: EQPreset) {}
    func setEQGain(_ gain: Float, at band: Int) {}
    func setEQGains(_ gains: [Float]) {}

    private func speak(from offset: Int) {
        guard !text.isEmpty else { return }
        configureAudioSession()
        speechGeneration &+= 1
        let range = text.index(text.startIndex, offsetBy: min(offset, text.count))..<text.endIndex
        let utterance = AVSpeechUtterance(string: String(text[range]))
        utterance.rate = Self.appleRate(for: activeRate)
        utterance.volume = activeVolume
        utteranceStart = offset
        speaking = true
        synthesizer.speak(utterance)
    }

    private func stopImmediately() {
        speechGeneration &+= 1
        synthesizer.stopSpeaking(at: .immediate)
        speaking = false
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        let offset = utteranceStart + characterRange.location
        position = Self.time(forCharacterOffset: offset, rate: activeRate)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) { speaking = false }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) { speaking = true }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        speaking = false
        position = estimatedDuration ?? position
        lastEndPosition = position
        lastEndDuration = estimatedDuration
        lastEndWasVerified = estimatedDuration != nil
        onPlaybackEnded?()
    }

    private static func appleRate(for rate: Float) -> Float {
        AVSpeechUtteranceDefaultSpeechRate * min(max(rate, 0.5), 2.0)
    }
    private static func charactersPerSecond(rate: Float) -> Double { 14 * Double(min(max(rate, 0.5), 2.0)) }
    private static func duration(for text: String, rate: Float) -> TimeInterval { Double(text.count) / charactersPerSecond(rate: rate) }
    private static func characterOffset(in text: String, at time: TimeInterval, rate: Float) -> Int {
        min(text.count, max(0, Int((time * charactersPerSecond(rate: rate)).rounded())))
    }
    private static func time(forCharacterOffset offset: Int, rate: Float) -> TimeInterval {
        Double(offset) / charactersPerSecond(rate: rate)
    }
}

