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
        if rounded < 60 { return String(format: "~%ds remaining", rounded) }

        let minutes = rounded / 60
        let secondsRemainder = rounded % 60
        if minutes < 60 {
            return secondsRemainder == 0
                ? String(format: "~%dm remaining", minutes)
                : String(format: "~%dm %ds remaining", minutes, secondsRemainder)
        }

        let hours = minutes / 60
        let minutesRemainder = minutes % 60
        return minutesRemainder == 0
            ? String(format: "~%dh remaining", hours)
            : String(format: "~%dh %dm remaining", hours, minutesRemainder)
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
    private var foregroundObserver: ObserverToken?
    private var isScanning = false

    public init(repository: LibraryRepository, defaults: UserDefaults = .standard) {
        self.repository = repository
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
    public static func newAudioFiles(in files: [URL], knownURLs: Set<URL>) -> [URL] {
        files.filter { url in
            let ext = url.pathExtension.lowercased()
            return AudioFormatSelection.allPlayableExtensions.contains(ext) && !knownURLs.contains(url)
        }
    }

    // MARK: - Public API

    public func addFolder(_ url: URL) async {
        guard !folders.contains(where: { $0.url == url }) else { return }

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        do {
            let bookmark = try url.bookmarkData()
            var bookmarks = storedBookmarks()
            bookmarks.append(bookmark)
            saveBookmarks(bookmarks)
            reloadFolders()
            if let folder = folders.first(where: { $0.url == url }) {
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

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let audioURLs = Self.newAudioFiles(in: contents, knownURLs: [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        var imports: [LocalAudioImport] = []
        let startedAt = Date()
        soundIndexProgress = SoundIndexProgress(
            totalTracks: audioURLs.count,
            indexedTracks: 0,
            startedAt: startedAt,
            now: startedAt
        )

        for (index, fileURL) in audioURLs.enumerated() {
            if Task.isCancelled { return }
            let duration = await Self.duration(of: fileURL)
            imports.append(LocalAudioImport(
                url: fileURL,
                title: fileURL.deletingPathExtension().lastPathComponent,
                sortKey: fileURL.lastPathComponent,
                duration: duration
            ))
            soundIndexProgress = SoundIndexProgress(
                totalTracks: audioURLs.count,
                indexedTracks: index + 1,
                startedAt: startedAt,
                now: Date()
            )
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
        for data in storedBookmarks() {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { continue }
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

    private static func duration(of url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        guard let cm = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(cm)
        return seconds.isFinite && seconds > 0 ? seconds : nil
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
