import Foundation
import VoxglassWatchProtocol

/// Filesystem operations the worker performs; injectable so tests can block deletion.
public protocol WatchFileOperations: Sendable {
    func exists(_ url: URL) -> Bool
    func remove(_ url: URL) throws
}

public struct WatchLiveFileOperations: WatchFileOperations {
    public init() {}
    public func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    public func remove(_ url: URL) throws { try FileManager.default.removeItem(at: url) }
}

/// The single serial owner of Watch downloaded-file mutation (install, per-book removal, reset).
/// Every operation runs on one private serial queue, never on the caller's actor. `install` stays
/// synchronous because WCSession deletes its temporary file when the delegate callback returns;
/// it is only ever called from WCSession's background queue, never MainActor.
public final class WatchDownloadedFiles: Sendable {
    public struct ResetResult: Sendable, Equatable { public var removed: [String] }

    /// Files beside the downloads root that belong to playback state. Narration outboxes are
    /// deliberately absent: unsubmitted review events must never be erased by a reset.
    public static let playbackFileNames = ["watch-playback-positions.json", "watch-playback-speeds.json"]

    private let queue = DispatchQueue(label: "voxglass.watch.downloaded-files")
    private let operations: any WatchFileOperations

    public init(operations: any WatchFileOperations = WatchLiveFileOperations()) {
        self.operations = operations
    }

    public func resetDownloadedState(at root: URL) async throws -> ResetResult {
        try await run { [operations] in
            var removed: [String] = []
            var targets = [root]
            targets += Self.playbackFileNames.map { root.deletingLastPathComponent().appendingPathComponent($0) }
            for url in targets where operations.exists(url) {
                try operations.remove(url)
                removed.append(url.lastPathComponent)
            }
            return ResetResult(removed: removed)
        }
    }

    public func removeBook(bookID: WatchBookID, at root: URL) async throws {
        guard WatchPhonePushFiles.safeComponent(bookID.rawValue) else {
            throw WatchDownloadPipelineError.invalidFilename
        }
        try await run { [operations] in
            let directory = root.appendingPathComponent(bookID.rawValue, isDirectory: true)
            if operations.exists(directory) { try operations.remove(directory) }
        }
    }

    /// Synchronous by necessity (see type docs); blocks only the calling background thread.
    public func install(source: URL, root: URL, bookID: String, filename: String,
                        expectedBytes: Int64, expectedSHA256: String,
                        validateAudio: (@Sendable (URL) throws -> Void)? = nil) throws -> URL {
        try queue.sync {
            try WatchPhonePushFiles.install(source: source, root: root, bookID: bookID,
                filename: filename, expectedBytes: expectedBytes,
                expectedSHA256: expectedSHA256, validateAudio: validateAudio)
        }
    }

    private func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }
}
