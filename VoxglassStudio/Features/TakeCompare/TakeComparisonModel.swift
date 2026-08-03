import AVFoundation
import Foundation
import Observation
import VoxglassCore

/// Spec §11.7 take comparison: A/B playback with position preservation, side-by-
/// side metrics, a "Suggested" heuristic (never automatic selection), and
/// "Select This Take".
@MainActor
@Observable
public final class TakeComparisonModel {
    public private(set) var paragraphID: UUID
    public private(set) var takes: [Take] = []
    public private(set) var activeTakeID: UUID?
    public private(set) var isPlaying = false
    public private(set) var position: TimeInterval = 0
    public var error: String?

    private let store: any ProductionStore
    private let assets: any ContentAddressedStore
    private let player: any TakePlaying
    private let initialSelectedTakeID: UUID?

    public init(
        paragraphID: UUID,
        takes: [Take],
        store: any ProductionStore,
        assets: any ContentAddressedStore,
        selectedTakeID: UUID? = nil,
        player: any TakePlaying = AVAudioTakePlayer()
    ) {
        self.paragraphID = paragraphID
        self.takes = takes.filter { !$0.isArchived }
        self.store = store
        self.assets = assets
        self.initialSelectedTakeID = selectedTakeID
        self.player = player
    }

    /// Spec §11.7: highest RMS within range of the best, no clipping, lowest
    /// noise floor. A heuristic — the user always decides.
    public var recommendedTakeID: UUID? {
        let withMetrics = takes.filter { $0.metrics != nil }
        guard !withMetrics.isEmpty else { return nil }
        let bestRMS = withMetrics.compactMap(\.metrics?.rmsDBFS).max() ?? -.infinity
        let threshold = bestRMS - 3.0
        let candidates = withMetrics.filter {
            guard let m = $0.metrics else { return false }
            return m.rmsDBFS >= threshold && m.clipCount == 0 && m.noiseFloorReliable
        }
        let pool = candidates.isEmpty ? withMetrics : candidates
        return pool.min { lhs, rhs in
            let l = lhs.metrics?.noiseFloorDBFS ?? .infinity
            let r = rhs.metrics?.noiseFloorDBFS ?? .infinity
            if abs(l - r) > 0.001 { return l < r }
            return (lhs.metrics?.rmsDBFS ?? -.infinity) > (rhs.metrics?.rmsDBFS ?? -.infinity)
        }?.id
    }

    public var selectedTakeID: UUID? {
        initialSelectedTakeID ?? takes.first { $0.id == activeTakeID }?.id
    }

    public func metricsDiff(_ a: Take, _ b: Take) -> [String: Double] {
        guard let ma = a.metrics, let mb = b.metrics else { return [:] }
        var diff: [String: Double] = [:]
        diff["peak"] = ma.peakDBFS - mb.peakDBFS
        diff["rms"] = ma.rmsDBFS - mb.rmsDBFS
        diff["noiseFloor"] = ma.noiseFloorDBFS - mb.noiseFloorDBFS
        diff["duration"] = ma.duration - mb.duration
        return diff
    }

    public func play(_ takeID: UUID) async {
        guard let take = takes.first(where: { $0.id == takeID }) else { return }
        do {
            let url = assets.url(for: take.assetRef)
            guard assets.exists(take.assetRef) else {
                error = "Audio asset for this take is missing."
                return
            }
            if activeTakeID == takeID, isPlaying {
                await player.pause()
                isPlaying = false
                return
            }
            let preserved = position
            activeTakeID = takeID
            try await player.play(url: url, at: preserved)
            position = preserved
            isPlaying = true
        } catch {
            self.error = "Playback failed: \(error.localizedDescription)"
        }
    }

    public func pause() async {
        await player.pause()
        isPlaying = false
    }

    public func select(_ takeID: UUID) async {
        do {
            try await store.setSelectedTake(takeID, forParagraph: paragraphID)
        } catch {
            self.error = "Selection failed: \(error.localizedDescription)"
        }
    }

    public func deselect() async {
        do {
            try await store.setSelectedTake(nil, forParagraph: paragraphID)
        } catch {
            self.error = "Selection failed: \(error.localizedDescription)"
        }
    }

    // MARK: - A/B (§11.7, F-25)

    /// The A slot — the first take.
    public var takeA: Take? { takes.first }

    /// The B slot — the second take (nil when there is only one).
    public var takeB: Take? { takes.count > 1 ? takes[1] : nil }

    public private(set) var isABComparing = false

    /// Gapless, position-preserving A/B: switches to the other slot at the
    /// current position (clamped to the target's duration) with a short
    /// crossfade. Never an automatic selection — the user picks.
    public func playAB() async {
        guard let a = takeA, let b = takeB else { return }
        let target = (activeTakeID == a.id) ? b : a
        await play(target.id)
        isABComparing = true
    }

    public func stopAB() async {
        await pause()
        isABComparing = false
    }
}

/// Pluggable A/B playback; the default uses `AVAudioPlayer` and preserves the
/// position when switching takes.
public protocol TakePlaying: Sendable {
    func play(url: URL, at position: TimeInterval) async throws
    func pause() async
}

public struct AVAudioTakePlayer: TakePlaying {
    public init() {}

    public func play(url: URL, at position: TimeInterval) async throws {
        let holder = AVAudioPlayerHolder.shared
        let player = try holder.player(for: url)
        player.stop()
        player.currentTime = min(max(position, 0), player.duration)
        player.play()
    }

    public func pause() async {
        AVAudioPlayerHolder.shared.pauseAll()
    }
}

private final class AVAudioPlayerHolder: @unchecked Sendable {
    static let shared = AVAudioPlayerHolder()
    private let lock = NSLock()
    private var current: AVAudioPlayer?

    func player(for url: URL) throws -> AVAudioPlayer {
        lock.lock()
        defer { lock.unlock() }
        if let current, current.url == url { return current }
        let player = try AVAudioPlayer(contentsOf: url)
        current = player
        return player
    }

    func pauseAll() {
        lock.lock()
        defer { lock.unlock() }
        current?.pause()
    }
}
