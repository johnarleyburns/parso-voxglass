import Foundation
import VoxglassCore

/// Routes app-owned text chapters to system speech while keeping the established
/// AVPlayer pipeline untouched for every audiobook source.
@MainActor
final class SwitchingAudioEngine: AudioEngine {
    private let audio: any AudioEngine
    private let speech: any AudioEngine
    private var active: any AudioEngine

    init(audio: any AudioEngine, speech: any AudioEngine) {
        self.audio = audio
        self.speech = speech
        self.active = audio
        wire(audio); wire(speech)
    }
    var onPlaybackEnded: (@MainActor () -> Void)? { didSet { wire(audio); wire(speech) } }
    var onPlaybackIssue: (@MainActor (AudioEngineIssue) -> Void)? { didSet { wire(audio); wire(speech) } }
    var onItemChanged: (@MainActor () -> Void)? { didSet { wire(audio); wire(speech) } }
    var onSilenceChanged: (@MainActor (Bool) -> Void)? { didSet { wire(audio); wire(speech) } }
    var currentTime: TimeInterval { active.currentTime }; var duration: TimeInterval? { active.duration }
    var isPlaying: Bool { active.isPlaying }; var isReady: Bool { active.isReady }; var rate: Float { active.rate }
    var volume: Float { get { active.volume } set { active.volume = newValue } }; var isEQEngaged: Bool { active.isEQEngaged }
    var hasPreloadedItem: Bool { active.hasPreloadedItem }; var isCurrentItemPreloaded: Bool { active.isCurrentItemPreloaded }
    var lastEndPosition: TimeInterval { active.lastEndPosition }; var lastEndDuration: TimeInterval? { active.lastEndDuration }; var lastEndWasVerified: Bool { active.lastEndWasVerified }
    func configureAudioSession() { active.configureAudioSession() }
    func load(url: URL, startTime: TimeInterval, lease: PlaybackLease?) async throws {
        active.pause(); active.releasePlaybackLeases()
        active = url.pathExtension == "voxtext" ? speech : audio
        try await active.load(url: url, startTime: startTime, lease: lease)
    }
    func play() { active.play() }; func pause() { active.pause() }; func seek(to position: TimeInterval) async { await active.seek(to: position) }
    func setRate(_ rate: Float) { audio.setRate(rate); speech.setRate(rate) }
    func preloadNext(url: URL, lease: PlaybackLease?) { active.preloadNext(url: url, lease: lease) }
    func cancelPreload() { active.cancelPreload() }; func releasePlaybackLeases() { active.releasePlaybackLeases() }
    func prefetchIntoCache(urls: [URL]) { active.prefetchIntoCache(urls: urls) }
    func setEQEngaged(_ engaged: Bool) { active.setEQEngaged(engaged) }; func applyEQPreset(_ preset: EQPreset) { active.applyEQPreset(preset) }
    func setEQGain(_ gain: Float, at band: Int) { active.setEQGain(gain, at: band) }; func setEQGains(_ gains: [Float]) { active.setEQGains(gains) }
    private func wire(_ engine: any AudioEngine) {
        engine.onPlaybackEnded = { [weak self] in self?.onPlaybackEnded?() }
        engine.onPlaybackIssue = { [weak self] issue in self?.onPlaybackIssue?(issue) }
        engine.onItemChanged = { [weak self] in self?.onItemChanged?() }
        engine.onSilenceChanged = { [weak self] value in self?.onSilenceChanged?(value) }
    }
}
