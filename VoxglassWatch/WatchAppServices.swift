import Combine
import Foundation
import VoxglassCore

@MainActor
final class WatchAppServices: ObservableObject {
    static let shared = WatchAppServices()

    private var cancellables = Set<AnyCancellable>()

    let database: AppDatabase
    let libraryStore: LibraryStore
    let catalogStore: CatalogStore
    let libraryRepository: LibraryRepository
    let positionStore: SQLitePositionStore
    let snapshotStore: LastPlaybackSnapshotStore
    let bookmarkStore: SQLiteBookmarkStore
    let playbackCoordinator: WatchPlaybackCoordinator
    let offlineManager: WatchStorageManager
    let relay: WatchAudioRelay

    @Published private(set) var phoneBooks: [BookWithChapters] = []
    @Published private(set) var searchResults: [InternetArchiveSearchResult] = []
    @Published private(set) var isSearching = false
    @Published var watchError: String?

    var books: [BookWithChapters] {
        Self.mergedBooks(phoneBooks: phoneBooks, localBooks: libraryStore.books)
    }

    init(relay providedRelay: WatchAudioRelay? = nil) {
        let relay = providedRelay ?? WatchAudioRelay.shared
        let database = AppDatabase.makeApplicationDatabase()
        let libraryRepository = LibraryRepository(database: database)
        let positionStore = SQLitePositionStore(database: database)
        let bookmarkStore = SQLiteBookmarkStore(database: database)

        self.database = database
        self.libraryRepository = libraryRepository
        self.libraryStore = LibraryStore(repository: libraryRepository)
        self.catalogStore = CatalogStore()
        self.positionStore = positionStore
        self.snapshotStore = LastPlaybackSnapshotStore()
        self.bookmarkStore = bookmarkStore
        self.playbackCoordinator = WatchPlaybackCoordinator(
            positionStore: positionStore,
            snapshotStore: snapshotStore
        )
        self.offlineManager = WatchStorageManager(
            repository: libraryRepository,
            positionStore: positionStore
        )
        self.relay = relay
        if let snapshot = relay.librarySnapshot {
            self.phoneBooks = snapshot.books
        }

        playbackCoordinator.localURLProvider = { [weak self] chapter in
            self?.offlineManager.localURL(for: chapter)
        }

        offlineManager.onStorageChanged = { [weak relay] snapshot in
            relay?.publishStorageSnapshot(snapshot)
        }

        libraryStore.onBookImported = { [weak self] _ in
            guard let self else { return }
            await self.libraryStore.refresh()
            await self.offlineManager.updateLibrary(self.books)
        }

        libraryStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        relay.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        playbackCoordinator.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        offlineManager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        relay.onReachabilityChanged = { [weak self] isReachable in
            guard isReachable else { return }
            Task { @MainActor in
                self?.publishWatchStorageSnapshot()
            }
        }

        relay.onLibrarySnapshot = { [weak self] snapshot in
            guard let self else { return }
            Task { @MainActor in
                await self.applyPhoneSnapshot(snapshot)
            }
        }

        relay.onFileReceived = { [weak self] fileURL, chapterKey in
            guard let self else { return }
            Task { @MainActor in
                for book in self.books {
                    for chapter in book.chapters where WatchChapterCache.key(for: chapter) == chapterKey {
                        await self.offlineManager.ingestFile(at: fileURL, for: chapter, bookID: book.book.id)
                        return
                    }
                }
            }
        }
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        if Self.shouldResetSmokeCache {
            await offlineManager.clearAllCache()
        }
        await libraryStore.refresh()
        await refreshFromPhone()
        await offlineManager.updateLibrary(books)
        publishWatchStorageSnapshot()
        await restoreBookmark()
    }

    func refreshFromPhone() async {
        if let snapshot = await relay.requestLibrarySnapshot() {
            await applyPhoneSnapshot(snapshot)
        } else if let error = relay.lastError {
            watchError = error
        }
    }

    func refreshLocalLibrary() async {
        await libraryStore.refresh()
        await offlineManager.updateLibrary(books)
    }

    func searchLibriVox(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            watchError = nil
            return
        }

        isSearching = true
        defer { isSearching = false }

        if relay.isReachable {
            let relayed = await relay.searchLibriVox(trimmed)
            if !relayed.isEmpty || relay.lastError == nil {
                searchResults = relayed
                watchError = relay.lastError
                return
            }
        }

        await catalogStore.searchLibriVox(trimmed)
        searchResults = catalogStore.results
        watchError = catalogStore.catalogError
    }

    func downloadBook(_ book: BookWithChapters) async {
        if relay.isReachable && relay.isCompanionAppInstalled {
            for chapter in book.chapters where offlineManager.localURL(for: chapter) == nil {
                if let key = WatchChapterCache.key(for: chapter) {
                    relay.requestChapter(book.book.title, chapterKey: key)
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }

        for chapter in book.chapters where offlineManager.localURL(for: chapter) == nil {
            do {
                try await offlineManager.downloadChapter(chapter, bookID: book.book.id)
            } catch {
                watchError = error.localizedDescription
            }
        }
        await offlineManager.updateLibrary(books)
        publishWatchStorageSnapshot()
    }

    func restoreBookmark() async {
        if let row = try? await positionStore.latestPosition(),
           let book = books.first(where: { $0.book.id == row.bookID }) {
            let chapters = book.chapters.naturallySorted()
            if let target = PlaybackCoordinator.resolveResume(chapters: chapters, saved: row) {
                playbackCoordinator.present(book, chapter: target.chapter)
            } else {
                playbackCoordinator.present(book)
            }
        }
    }

    private var didBootstrap = false

    private func applyPhoneSnapshot(_ snapshot: WatchPhoneLibrarySnapshot) async {
        phoneBooks = snapshot.books
        watchError = nil
        await offlineManager.updateLibrary(books)
    }

    private func publishWatchStorageSnapshot() {
        relay.publishStorageSnapshot(offlineManager.storageSnapshot())
    }

    private static var shouldResetSmokeCache: Bool {
        let key = "VOXGLASS_WATCH_SMOKE_RESET_CACHE"
        let processInfo = ProcessInfo.processInfo
        return processInfo.environment[key] == "1"
            || processInfo.arguments.contains("-\(key)")
            || UserDefaults.standard.bool(forKey: key)
    }

    private static func mergedBooks(
        phoneBooks: [BookWithChapters],
        localBooks: [BookWithChapters]
    ) -> [BookWithChapters] {
        var seen = Set<String>()
        var merged: [BookWithChapters] = []
        for book in phoneBooks + localBooks {
            let key = [
                book.book.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                book.book.authorLine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            ].joined(separator: "|")
            if seen.insert(key).inserted {
                merged.append(book)
            }
        }
        return merged.sorted {
            $0.book.title.localizedCaseInsensitiveCompare($1.book.title) == .orderedAscending
        }
    }
}
