import Foundation
@testable import Voxglass

/// Test double for `AudioEngine` (Step 0 of the competitive gap plan). Records an
/// ordered call log so speed, sleep timer, bookmark, and skip-interval decisions
/// can be asserted with no AVFoundation and no simulator. Tests can set
/// `currentTime`/`duration`/`isPlaying` directly and fire the engine callbacks
/// synchronously via `firePlaybackEnded()` / `fireItemChanged()`.
@MainActor
final class FakeAudioEngine: AudioEngine {
    enum Call: Equatable {
        case configureAudioSession
        case load(url: URL, startTime: TimeInterval)
        case play
        case pause
        case seek(TimeInterval)
        case setRate(Float)
        case preloadNext(url: URL)
        case cancelPreload
        case prefetchIntoCache(urls: [URL])
        case setEQEngaged(Bool)
        case applyEQPreset(gains: [Float])
        case setEQGain(gain: Float, band: Int)
        case setEQGains([Float])
        case setVolume(Float)
    }

    private(set) var calls: [Call] = []

    var currentTime: TimeInterval = 0
    var duration: TimeInterval?
    var isPlaying: Bool = false
    private(set) var rate: Float = 1.0
    var isEQEngaged: Bool = false

    var volume: Float = 1.0 {
        didSet { calls.append(.setVolume(volume)) }
    }

    var onPlaybackEnded: (@MainActor () -> Void)?
    var onItemChanged: (@MainActor () -> Void)?

    func configureAudioSession() { calls.append(.configureAudioSession) }

    func load(url: URL, startTime: TimeInterval) async throws {
        calls.append(.load(url: url, startTime: startTime))
        currentTime = startTime
    }

    func play() {
        calls.append(.play)
        isPlaying = true
    }

    func pause() {
        calls.append(.pause)
        isPlaying = false
    }

    func seek(to position: TimeInterval) async {
        calls.append(.seek(position))
        currentTime = position
    }

    func setRate(_ rate: Float) {
        self.rate = rate
        calls.append(.setRate(rate))
    }

    func preloadNext(url: URL) { calls.append(.preloadNext(url: url)) }
    func cancelPreload() { calls.append(.cancelPreload) }
    func prefetchIntoCache(urls: [URL]) { calls.append(.prefetchIntoCache(urls: urls)) }

    func setEQEngaged(_ engaged: Bool) {
        isEQEngaged = engaged
        calls.append(.setEQEngaged(engaged))
    }

    func applyEQPreset(_ preset: EQPreset) { calls.append(.applyEQPreset(gains: preset.gains)) }
    func setEQGain(_ gain: Float, at band: Int) { calls.append(.setEQGain(gain: gain, band: band)) }
    func setEQGains(_ gains: [Float]) { calls.append(.setEQGains(gains)) }

    // MARK: - Test helpers

    /// The engine callbacks are `@MainActor`; fire them synchronously in tests.
    func firePlaybackEnded() { onPlaybackEnded?() }
    func fireItemChanged() { onItemChanged?() }

    func reset() { calls.removeAll() }

    /// All `.setRate` values in order.
    var rateCalls: [Float] {
        calls.compactMap { if case let .setRate(r) = $0 { return r } else { return nil } }
    }

    /// All `.load` calls in order.
    var loadCalls: [(url: URL, startTime: TimeInterval)] {
        calls.compactMap { if case let .load(url, startTime) = $0 { return (url, startTime) } else { return nil } }
    }

    var didCancelPreload: Bool { calls.contains(.cancelPreload) }

    func contains(_ call: Call) -> Bool { calls.contains(call) }
}
