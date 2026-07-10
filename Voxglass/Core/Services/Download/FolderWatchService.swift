import Foundation

final class FolderWatchService: NSObject, NSFilePresenter, @unchecked Sendable {
    static let shared = FolderWatchService()

    var presentedItemURL: URL?
    var presentedItemOperationQueue: OperationQueue = .main

    private let defaults = UserDefaults.standard
    private let bookmarkKey = "voxglass.watchedFolderBookmark"
    private var isWatching = false
    private var knownFiles: Set<String> = []
    var onNewFiles: (([URL]) -> Void)?

    private override init() {
        super.init()
    }

    var watchedFolderURL: URL? {
        guard let data = defaults.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        if isStale {
            defaults.removeObject(forKey: bookmarkKey)
            return nil
        }
        return url
    }

    func startWatching(folderURL: URL) {
        guard ProFeature.isEnabled(.folderWatch) else { return }
        stopWatching()

        let didStart = folderURL.startAccessingSecurityScopedResource()
        defer { if didStart { folderURL.stopAccessingSecurityScopedResource() } }

        guard let bookmarkData = try? folderURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }

        defaults.set(bookmarkData, forKey: bookmarkKey)

        presentedItemURL = folderURL
        NSFileCoordinator.addFilePresenter(self)
        isWatching = true
        knownFiles = currentFileSet(at: folderURL)

        // Initial scan
        scanForNewFiles(folderURL: folderURL)
    }

    func stopWatching() {
        if isWatching {
            NSFileCoordinator.removeFilePresenter(self)
            isWatching = false
        }
        presentedItemURL = nil
        knownFiles.removeAll()
    }

    func scanForNewFiles(folderURL: URL) {
        guard let url = folderURL as URL? ?? presentedItemURL else { return }
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        let currentFiles = currentFileSet(at: url)
        let newFiles = currentFiles.subtracting(knownFiles)
        knownFiles = currentFiles

        if !newFiles.isEmpty {
            let urls = newFiles.compactMap { name -> URL? in
                let fileURL = url.appendingPathComponent(name)
                guard LocalAudioImporter.isSupportedAudioURL(fileURL) else { return nil }
                return fileURL
            }
            if !urls.isEmpty {
                onNewFiles?(urls)
            }
        }
    }

    func rescanOnForeground() {
        guard let url = presentedItemURL else { return }
        scanForNewFiles(folderURL: url)
    }

    func presentedSubitemDidChange(at url: URL) {
        guard let folderURL = presentedItemURL else { return }
        scanForNewFiles(folderURL: folderURL)
    }

    private func currentFileSet(at url: URL) -> Set<String> {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return Set(contents.map { $0.lastPathComponent })
    }
}
