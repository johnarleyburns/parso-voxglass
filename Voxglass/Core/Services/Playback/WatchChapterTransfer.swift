import Foundation

/// Resolves the on-phone blob for a phone→watch chapter transfer. Extracted so
/// the phone relay and host tests share one implementation: a chapter is
/// transferable only when its blob is complete in the store, and the resolved
/// URL must come from the store — never from a hand-built path (RC2). Never
/// touches the network.
public enum WatchChapterTransfer {
    /// Returns the complete blob's URL for `chapterKey`, or nil when the blob is
    /// absent or incomplete.
    public static func resolvedFileURL(cacheStore: StreamCacheStore, chapterKey: String) async -> URL? {
        guard await cacheStore.isComplete(chapterKey) else { return nil }
        let url = await cacheStore.fileURL(for: chapterKey)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}
