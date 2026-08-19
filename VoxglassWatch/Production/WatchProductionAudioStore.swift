import Foundation
import Observation
import VoxglassCore

/// Stores paragraph audio files received from the phone and applies the watch's
/// 200 MB production-audio cap (spec §13.6 rule 4). `WatchProductionStoragePolicy`
/// owns the pure eviction math; this owns the filesystem. Used only from the main
/// actor, so it stays a plain `@Observable` class.
@Observable
public final class WatchProductionAudioStore {

    public let rootDirectory: URL
    public private(set) var usedBytes = 0

    private var audio: [UUID: URL] = [:]
    private var lastQueuedAt: [UUID: Date] = [:]

    public init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory ?? WatchProductionAudioStore.defaultRoot
        try? FileManager.default.createDirectory(at: self.rootDirectory, withIntermediateDirectories: true)
    }

    public func ingest(fileAt sourceURL: URL, for paragraphID: UUID) throws {
        let destination = rootDirectory
            .appendingPathComponent("\(paragraphID.uuidString).wav")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: sourceURL, to: destination)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
        audio[paragraphID] = destination
        lastQueuedAt[paragraphID] = Date()
        usedBytes += bytes
    }

    public func localURL(for paragraphID: UUID) -> URL? {
        audio[paragraphID]
    }

    public func hasAudio(for paragraphID: UUID) -> Bool {
        audio[paragraphID] != nil
    }

    /// Removes audio for the given paragraphs, then continues evicting
    /// least-recently-queued items until the store fits the policy cap.
    public func evict(toCap cap: Int = WatchProductionStoragePolicy.maxProductionBytes, keeping keep: Set<UUID> = []) {
        let items = audio.map { id, url in
            WatchProductionStoragePolicy.Item(
                paragraphID: id,
                byteCount: (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0,
                lastQueuedAt: lastQueuedAt[id] ?? .distantPast
            )
        }
        let policy = WatchProductionStoragePolicy()
        let candidates = policy.evictionCandidates(items: items, cap: cap, keep: keep)
        for id in candidates {
            remove(paragraphID: id)
        }
    }

    public func remove(paragraphID: UUID) {
        guard let url = audio.removeValue(forKey: paragraphID) else { return }
        lastQueuedAt.removeValue(forKey: paragraphID)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        try? FileManager.default.removeItem(at: url)
        usedBytes = max(0, usedBytes - bytes)
    }

    public func clear() {
        for id in Array(audio.keys) { remove(paragraphID: id) }
    }

    /// Smoke/testing hook: writes a short deterministic WAV for each item so the
    /// review player has playable local audio without the phone.
    public func preload(_ items: [WatchAudioItem]) {
        for item in items {
            let url = rootDirectory.appendingPathComponent("\(item.paragraphID.uuidString).wav")
            let samples = 48000 / 2
            var data = Data()
            data.append("RIFF".data(using: .ascii)!)
            var fileSize = UInt32(36 + samples * 2).littleEndian
            data.append(Data(bytes: &fileSize, count: 4))
            data.append("WAVEfmt ".data(using: .ascii)!)
            var chunk = UInt32(16).littleEndian
            data.append(Data(bytes: &chunk, count: 4))
            var pcm = UInt16(1).littleEndian
            data.append(Data(bytes: &pcm, count: 2))
            var channels = UInt16(1).littleEndian
            data.append(Data(bytes: &channels, count: 2))
            var rate = UInt32(48000).littleEndian
            data.append(Data(bytes: &rate, count: 4))
            var byteRate = UInt32(48000 * 2).littleEndian
            data.append(Data(bytes: &byteRate, count: 4))
            var blockAlign = UInt16(2).littleEndian
            data.append(Data(bytes: &blockAlign, count: 2))
            var bits = UInt16(16).littleEndian
            data.append(Data(bytes: &bits, count: 2))
            data.append("data".data(using: .ascii)!)
            var dataSize = UInt32(samples * 2).littleEndian
            data.append(Data(bytes: &dataSize, count: 4))
            for index in 0..<samples {
                let sample = Int16(cos(Double(index) / 480.0) * 800)
                data.append(Data(bytes: [UInt8(sample & 0xFF), UInt8((sample >> 8) & 0xFF)], count: 2))
            }
            try? data.write(to: url, options: .atomic)
            audio[item.paragraphID] = url
            lastQueuedAt[item.paragraphID] = Date()
            usedBytes += data.count
        }
    }

    static let defaultRoot: URL = {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ProductionAudio", isDirectory: true)
    }()
}
