import AVFoundation
import Foundation
import VoxglassCore
import os

/// AVSpeechSynthesizer-backed implementation of the existing playback seam.
/// `.voxtext` chapters are local, app-owned UTF-8 files; all other URLs remain
/// the responsibility of AVPlayerAudioEngine.
@MainActor
final class ReadWithAISpeechAudioEngine: NSObject, AudioEngine, @preconcurrency AVSpeechSynthesizerDelegate {
    private static let log = Logger(subsystem: "guru.parso.voxglass", category: "speech-audio")
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
            // A route can briefly reject a category transition (notably while
            // Bluetooth or AirPlay is settling) even though the synthesizer is
            // able to keep speaking through the already-active session. This
            // is not a playback failure; reporting it used to show the
            // "Playback Interrupted" alert over successfully playing text.
            // AVPlayerAudioEngine follows the same recoverable-error policy.
            Self.log.error("Speech audio session configuration failed: \(error, privacy: .public)")
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

    func play() {
        if synthesizer.isPaused {
            speaking = true
            synthesizer.continueSpeaking()
        } else {
            speak(from: utteranceStart)
        }
    }
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
        utterance.voice = Self.selectedOrPreferredOnDeviceVoice()
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

    /// Prefer an installed Premium or Enhanced system voice before falling
    /// back to the device default. These voices remain entirely on-device;
    /// iOS only exposes qualities that are already installed by the user.
    private static func selectedOrPreferredOnDeviceVoice() -> AVSpeechSynthesisVoice? {
        if let identifier = UserDefaults.standard.string(forKey: AppPreferencesStore.Keys.readWithAIVoiceIdentifier),
           let selected = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.identifier == identifier }) {
            return selected
        }
        return preferredOnDeviceVoice()
    }

    private static func preferredOnDeviceVoice() -> AVSpeechSynthesisVoice? {
        let locale = Locale.autoupdatingCurrent
        let languageCode = locale.language.languageCode?.identifier
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let sameLanguage = voices.filter {
            Locale(identifier: $0.language).language.languageCode?.identifier == languageCode
        }
        let candidates = sameLanguage.isEmpty ? voices : sameLanguage

        return candidates.max { lhs, rhs in
            let lhsScore = voiceScore(lhs, preferredLocale: locale)
            let rhsScore = voiceScore(rhs, preferredLocale: locale)
            if lhsScore != rhsScore { return lhsScore < rhsScore }
            return lhs.identifier > rhs.identifier
        } ?? AVSpeechSynthesisVoice(language: locale.identifier)
    }

    private static func voiceScore(_ voice: AVSpeechSynthesisVoice, preferredLocale: Locale) -> Int {
        let quality: Int
        switch voice.quality {
        case .premium: quality = 3
        case .enhanced: quality = 2
        default: quality = 1
        }
        let localeBonus = voice.language == preferredLocale.identifier ? 1 : 0
        return quality * 10 + localeBonus
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

