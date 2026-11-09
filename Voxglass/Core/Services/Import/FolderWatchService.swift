import AVFoundation
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Progress for the watched-folder sound index. The estimate is derived from
/// completed tracks and elapsed wall-clock time, so it never presents a
/// fabricated duration before the first track has finished probing.
public struct SoundIndexProgress: Sendable, Equatable {
    public let totalTracks: Int
    public let indexedTracks: Int
    public let startedAt: Date
    public let estimatedSecondsRemaining: TimeInterval?

    public var remainingTracks: Int {
        max(0, totalTracks - indexedTracks)
    }

    public var fractionComplete: Double {
        guard totalTracks > 0 else { return 0 }
        return min(max(Double(indexedTracks) / Double(totalTracks), 0), 1)
    }

    public var estimatedTimeRemainingText: String? {
        guard let seconds = estimatedSecondsRemaining else { return nil }
        let rounded = max(1, Int(seconds.rounded(.up)))
        let formatted = Duration.seconds(Int64(rounded))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
        return String(localized: "~\(formatted) remaining", bundle: .module, comment: "Estimated folder indexing time remaining")
    }

    public init(totalTracks: Int, indexedTracks: Int, startedAt: Date, now: Date) {
        self.totalTracks = max(0, totalTracks)
        self.indexedTracks = min(max(0, indexedTracks), max(0, totalTracks))
        self.startedAt = startedAt

        let elapsed = now.timeIntervalSince(startedAt)
        let rate = elapsed > 0 && self.indexedTracks > 0
            ? Double(self.indexedTracks) / elapsed
            : nil
        let remainingTracks = max(0, self.totalTracks - self.indexedTracks)
        if let rate, remainingTracks > 0 {
            estimatedSecondsRemaining = Double(remainingTracks) / rate
        } else {
            estimatedSecondsRemaining = nil
        }
    }
}

/// Watches user-picked folders of audio files and imports them as local books
/// (§4). Security-scoped bookmarks are persisted so watched folders
/// survive relaunch; a foreground rescan + `NSFilePresenter` keep them live.
@MainActor
public final class FolderWatchService: ObservableObject {
    public struct WatchedFolder: Identifiable, Equatable {
        public let id: String
        public let url: URL
        public var name: String { url.lastPathComponent }
    }

    @Published public private(set) var folders: [WatchedFolder] = []
    @Published public var errorMessage: String?
    @Published public private(set) var soundIndexProgress: SoundIndexProgress?

    private let repository: LibraryRepository
    private let defaults: UserDefaults
    private let bookmarksKey = "voxglass.folderWatch.bookmarks"
    private weak var libraryStore: LibraryStore?
    private var presenters: [FolderPresenter] = []
    private var folderLeases: [PlaybackLease] = []
    private var foregroundObserver: ObserverToken?
    private var isScanning = false
    private let worker: FolderIndexingWorker
    private let now: @Sendable () -> Date

    public init(
        repository: LibraryRepository,
        defaults: UserDefaults = .standard,
        worker: FolderIndexingWorker = FolderIndexingWorker(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.repository = repository
        self.worker = worker
        self.now = now
        self.defaults = defaults
        reloadFolders()
        #if canImport(UIKit) && !os(watchOS)
        // A foreground rescan keeps watched folders live; the notification is
        // iOS-only, so on the host (swift test) there is simply no rescan hook.
        let observer = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.rescanAll() }
        }
        foregroundObserver = ObserverToken(observer)
        #endif
    }

    deinit {
        for presenter in presenters {
            NSFileCoordinator.removeFilePresenter(presenter)
        }
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver.value)
        }
    }

    public func configure(libraryStore: LibraryStore) {
        self.libraryStore = libraryStore
    }

    // MARK: - Pure diff helper (testable, §4)

    /// The subset of `files` that are playable audio and not already known.
    nonisolated public static func newAudioFiles(in files: [URL], knownURLs: Set<URL>) -> [URL] {
        files.filter { url in
            let ext = url.pathExtension.lowercased()
            return AudioFormatSelection.allPlayableExtensions.contains(ext) && !knownURLs.contains(url)
        }
    }

    // MARK: - Public API

    public func addFolder(_ url: URL) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        do {
            let bookmark = try url.bookmarkData()
            var bookmarks = storedBookmarks()
            // A fresh picker selection renews access even for an already-watched
            // folder. Never force users to delete the book to repair permission.
            if let index = bookmarks.firstIndex(where: { data in
                var stale = false
                guard let existing = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return false }
                return Self.canonicalFolder(existing) == Self.canonicalFolder(url)
            }) {
                bookmarks[index] = bookmark
            } else {
                bookmarks.append(bookmark)
            }
            saveBookmarks(bookmarks)
            reloadFolders()
            if let folder = folders.first(where: { Self.canonicalFolder($0.url) == Self.canonicalFolder(url) }) {
                await scan(folder: folder)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func removeFolder(_ id: String) {
        let remaining = storedBookmarks().filter { data in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return false }
            return url.absoluteString != id
        }
        saveBookmarks(remaining)
        reloadFolders()
    }

    public func rescanAll() async {
        for folder in folders {
            await scan(folder: folder)
        }
    }

    public func scan(folder: WatchedFolder) async {
        // A file-presenter callback and a foreground refresh can arrive at the
        // same time. Keep one truthful aggregate progress stream instead of
        // interleaving two scans and producing an impossible ETA.
        guard !isScanning else { return }
        isScanning = true
        defer {
            isScanning = false
            soundIndexProgress = nil
        }

        let url = folder.url
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        // Do not probe AVURLAsset duration for files that are already in the
        // database. This scan runs on every launch and used to reopen every
        // audiobook in every watched folder before bootstrap could finish.
        do {
            if try await repository.repairLocalFileBookmarks(forFolder: url) > 0 {
                await libraryStore?.refresh()
            }
        } catch {
            errorMessage = "Could not restore audio file access: \(error.localizedDescription)"
            return
        }
        let knownURLs = await repository.knownLocalFileURLs(forFolder: url)

        // All file/AV work runs in the worker, off the main actor. It reports
        // throttled (<= 4/s) progress snapshots back here.
        let startedAt = now()
        let imports: [LocalAudioImport]
        do {
            imports = try await worker.index(folder: url, knownURLs: knownURLs) { [weak self] indexed, total in
                await self?.applyProgress(indexed: indexed, total: total, startedAt: startedAt)
            }
        } catch is CancellationError {
            return
        } catch FolderIndexError.unreadableFolder {
            errorMessage = "Could not read the watched folder \(folder.name). Open it in Files and make sure its audio is available on this iPhone."
            return
        } catch FolderIndexError.bookmark(let message) {
            errorMessage = "Could not save audio file access: \(message)"
            return
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        guard !imports.isEmpty else { return }

        do {
            _ = try await repository.importLocalFolder(
                folderURL: url,
                folderName: folder.name,
                files: imports
            )
            await libraryStore?.refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyProgress(indexed: Int, total: Int, startedAt: Date) {
        soundIndexProgress = SoundIndexProgress(
            totalTracks: total,
            indexedTracks: indexed,
            startedAt: startedAt,
            now: now()
        )
    }

    private static func canonicalFolder(_ url: URL) -> URL {
        URL(fileURLWithPath: url.path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    }

    // MARK: - Bookmark persistence

    private func storedBookmarks() -> [Data] {
        (defaults.array(forKey: bookmarksKey) as? [Data]) ?? []
    }

    private func saveBookmarks(_ bookmarks: [Data]) {
        defaults.set(bookmarks, forKey: bookmarksKey)
    }

    private func reloadFolders() {
        unregisterPresenters()
        var resolved: [WatchedFolder] = []
        // Release the previous generation's leases before taking new ones.
        folderLeases.forEach { $0.release() }
        folderLeases.removeAll()
        for data in storedBookmarks() {
            // Hold the user-selected folder readable for playback, not only
            // for the brief scan, for as long as it stays watched. This also
            // covers legacy chapters with no bookmark.
            // A denied scope keeps the folder listed (no lease) so a later
            // scan or reselection can still retry it.
            guard let url = PlaybackSourceResolver.system.bookmarkURL(data) else { continue }
            if let lease = SecurityScopedLeaseRegistry.shared.acquire(url) {
                folderLeases.append(lease)
            }
            resolved.append(WatchedFolder(id: url.absoluteString, url: url))
        }
        folders = resolved
        registerPresenters()
    }

    private func registerPresenters() {
        for folder in folders {
            let presenter = FolderPresenter(url: folder.url) { [weak self] in
                Task { @MainActor in await self?.scan(folder: folder) }
            }
            presenters.append(presenter)
            NSFileCoordinator.addFilePresenter(presenter)
        }
    }

    private func unregisterPresenters() {
        for presenter in presenters {
            NSFileCoordinator.removeFilePresenter(presenter)
        }
        presenters.removeAll()
    }
}

/// Live folder watcher: fires the change handler when the folder's contents
/// change so a rescan can pick up newly added files without a relaunch.
private struct ObserverToken: @unchecked Sendable {
    let value: NSObjectProtocol

    init(_ value: NSObjectProtocol) {
        self.value = value
    }
}

private final class FolderPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    public let presentedItemURL: URL?
    public let presentedItemOperationQueue: OperationQueue = .main
    private let onChange: () -> Void

    public init(url: URL, onChange: @escaping () -> Void) {
        self.presentedItemURL = url
        self.onChange = onChange
        super.init()
    }

    public func presentedSubitemDidChange(at url: URL) {
        onChange()
    }
}
