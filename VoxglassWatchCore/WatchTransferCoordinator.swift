import Foundation
import VoxglassWatchProtocol

public protocol WatchPhoneAssetTransfer: Sendable {
    func transfer(_ asset: WatchDownloadAsset, from source: URL) async throws
}

public actor WatchTransferCoordinator {
    public struct Progress: Equatable, Sendable {
        public var state: WatchDownloadState
        public var completed: Int
        public var total: Int
        public var bytes: Int64
        public init(state: WatchDownloadState, completed: Int = 0, total: Int = 0, bytes: Int64 = 0) {
            self.state = state; self.completed = completed; self.total = total; self.bytes = bytes
        }
    }

    private var progress: [WatchBookID: Progress] = [:]
    private var cancelled: Set<WatchBookID> = []
    public init() {}
    public func progress(for bookID: WatchBookID) -> Progress? { progress[bookID] }

    /// Sends no more than two files concurrently. A failed or missing source
    /// leaves the root resumable and never reports `downloaded`.
    public func start(plan: WatchDownloadPlan, transfer: WatchPhoneAssetTransfer) async -> Progress {
        cancelled.remove(plan.bookID)
        var current = Progress(state: .preparing, total: plan.assets.count)
        progress[plan.bookID] = current
        current.state = .transferring; progress[plan.bookID] = current
        do {
            try await withThrowingTaskGroup(of: Int64.self) { group in
                var next = 0
                var active = 0
                while next < plan.assets.count || active > 0 {
                    guard !cancelled.contains(plan.bookID) else { throw WatchDownloadPipelineError.cancelled }
                    while active < 2, next < plan.assets.count {
                        let asset = plan.assets[next]; next += 1; active += 1
                        guard let source = asset.sourceURL else { throw WatchDownloadPipelineError.missingSource(asset.chapterID) }
                        group.addTask { try await transfer.transfer(asset, from: source); return asset.expectedBytes ?? 0 }
                    }
                    if let bytes = try await group.next() {
                        active -= 1; current.completed += 1; current.bytes += bytes; progress[plan.bookID] = current
                    }
                }
            }
            current.state = .installing
        } catch {
            current.state = .failed(Self.errorCode(error)); progress[plan.bookID] = current; return current
        }
        progress[plan.bookID] = current
        return current
    }

    public func cancel(bookID: WatchBookID) { cancelled.insert(bookID); progress[bookID] = Progress(state: .removing) }
    private static func errorCode(_ error: Error) -> String {
        if let error = error as? WatchDownloadPipelineError { return String(describing: error) }
        return "transfer-failed"
    }
}
