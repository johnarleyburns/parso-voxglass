import Foundation
import ParsoAudioStreaming

public extension SparseCacheStore {
    /// Test convenience: isolate the streaming and durable tiers under one
    /// throwaway directory. Mirrors the old `StreamCacheStore(directory:)`.
    init(directory: URL) {
        self.init(evictableRoot: directory.appendingPathComponent("stream", isDirectory: true),
                  durableRoot: directory.appendingPathComponent("offline", isDirectory: true))
    }
}
