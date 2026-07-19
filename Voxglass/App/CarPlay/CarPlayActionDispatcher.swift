import CarPlay
import UIKit
import VoxglassCore

/// The thin glue between `CarPlayAction` values and the real services. Every
/// case is a 1–3 line call into the existing coordinator/stores — CarPlay adds
/// zero new playback paths (docs/CARPLAY_DESIGN.md §6.4).
@MainActor
final class CarPlayActionDispatcher {
    private let services: AppServices
    private weak var controller: CarPlayInterfaceController?
    private var searchDelegate: CarPlaySearchDelegate?

    init(services: AppServices, controller: CarPlayInterfaceController) {
        self.services = services
        self.controller = controller
    }

    func dispatch(_ action: CarPlayAction) {
        let coordinator = services.playbackCoordinator
        let library = services.libraryStore

        switch action {
        case .resumeCurrent:
            if let bookID = coordinator.currentSession?.book.id,
               let book = library.book(withID: bookID) {
                Task { await coordinator.play(book) }
            }
            controller?.pushNowPlaying()

        case .playBook(let bookID):
            guard let book = library.book(withID: bookID) else { return }
            Task { await coordinator.play(book) }
            controller?.pushNowPlaying()

        case .openBook(let bookID):
            pushChapterList(bookID: bookID)

        case .playChapter(let bookID, let chapterID):
            guard let book = library.book(withID: bookID),
                  let chapter = book.chapters.first(where: { $0.id == chapterID }) else { return }
            Task { await coordinator.play(book, chapter: chapter) }
            controller?.pushNowPlaying()

        case .openTab(let tabID):
            controller?.selectTab(tabID)

        case .openRoute(let route):
            openRoute(route)

        case .playCatalogItem(let identifier):
            importThenPlay(identifier: identifier)

        case .openCatalogItem(let identifier):
            importThenPlay(identifier: identifier)

        case .download(let bookID):
            guard let book = library.book(withID: bookID) else { return }
            Task {
                _ = await services.offlineDownloadManager.makeAvailableOffline(
                    book: book,
                    isCellular: NetworkMonitor.shared.isCellular
                )
            }

        case .removeDownload(let bookID):
            guard let book = library.book(withID: bookID) else { return }
            Task { await services.offlineDownloadManager.removeOffline(book: book) }

        case .beginSearch:
            beginSearch()

        case .runSearch(let query):
            runSearch(query: query)

        case .setSleepTimer(let mode):
            coordinator.setSleepTimer(mode)

        case .addBookmark:
            coordinator.addBookmark()
            presentTransientAlert("Bookmarked")

        case .showChapters:
            guard let bookID = coordinator.currentSession?.book.id else { return }
            pushChapterList(bookID: bookID)

        case .setRate(let rate):
            coordinator.setPlaybackRate(rate)

        case .none:
            break
        }
    }

    // MARK: - Now Playing button intents

    /// Cycles the system speed ladder — the same ladder the already-wired
    /// `changePlaybackRateCommand` advertises.
    func cycleRate() {
        let coordinator = services.playbackCoordinator
        let ladder = PlaybackRate.systemLadder
        let current = coordinator.playbackRate
        let index = ladder.firstIndex(where: { abs($0 - current) < 0.01 }) ?? -1
        let next = ladder[(index + 1) % ladder.count]
        coordinator.setPlaybackRate(next)
    }

    /// The "stop at a clean break" sheet: End of chapter · 30 min · 60 min · Off
    /// (docs/CARPLAY_DESIGN.md §5.2).
    func presentSleepSheet() {
        let actions = CarPlayNowPlayingModel.sleepOptions.map { mode in
            CPAlertAction(title: Self.sleepOptionTitle(mode), style: .default) { [weak self] _ in
                self?.services.playbackCoordinator.setSleepTimer(mode)
                self?.controller?.dismissPresented()
            }
        }
        let sheet = CPActionSheetTemplate(title: "Sleep Timer", message: nil, actions: actions)
        controller?.present(sheet)
    }

    static func sleepOptionTitle(_ mode: SleepTimer.Mode) -> String {
        switch mode {
        case .endOfChapter: return "End of chapter"
        case .duration(let seconds): return "\(Int(seconds / 60)) min"
        case .off: return "Off"
        }
    }

    // MARK: - Private

    private func pushChapterList(bookID: UUID) {
        guard let book = services.libraryStore.book(withID: bookID),
              let controller else { return }
        let chapters = book.chapters.naturallySorted().map { chapter in
            CarPlayChapterSnapshot(
                id: chapter.id,
                title: chapter.title,
                index: chapter.index,
                duration: chapter.duration,
                hasPlayableURL: chapter.resolvedPlayableURL() != nil
            )
        }
        let nowPlayingChapterID = services.playbackCoordinator.currentSession?.book.id == bookID
            ? services.playbackCoordinator.currentChapterID
            : nil
        let sections = CarPlayMenuBuilder.chapterList(
            book: controller.makeBookSnapshot(book, lastPlayedAt: nil),
            chapters: chapters,
            nowPlayingChapterID: nowPlayingChapterID
        )
        controller.push(sections: sections, title: book.book.title)
    }

    private func openRoute(_ route: CarPlayBrowseRoute) {
        guard let controller else { return }
        if case .genre(let collectionID, let name) = route {
            openGenre(collectionID: collectionID, name: name)
            return
        }
        let sections = CarPlayMenuBuilder.routeList(route, controller.makeState())
        controller.push(sections: sections, title: Self.routeTitle(route))
    }

    private func openGenre(collectionID: String, name: String) {
        let categories = [LibriVoxBrowseCategory.popular] + LibriVoxBrowseGroup.categories
        guard let category = categories.first(where: { $0.id == collectionID }) else { return }
        Task { [weak self] in
            let results = (try? await InternetArchiveClient()
                .searchAdvanced(query: category.archiveQuery, rows: 25)) ?? []
            guard let self, let controller = self.controller else { return }
            let sections = CarPlayMenuBuilder.searchResults(results.map(controller.makeCatalogSnapshot))
            controller.push(sections: sections, title: name)
        }
    }

    private func importThenPlay(identifier: String) {
        Task { [weak self] in
            guard let self else { return }
            let library = self.services.libraryStore
            if let existing = library.books.first(where: { book in
                library.source(for: book.book)?.url?.lastPathComponent == identifier
            }) {
                await self.services.playbackCoordinator.play(existing)
                self.controller?.pushNowPlaying()
                return
            }
            guard let metadata = try? await InternetArchiveClient().metadata(for: identifier) else {
                self.presentTransientAlert("Couldn't load that book")
                return
            }
            let sourceKind: SourceKind = metadata.sourceKind == .librivox ? .librivox : .internetArchiveURL
            guard let imported = await library.importInternetArchiveItem(metadata, sourceKind: sourceKind) else {
                self.presentTransientAlert("Couldn't load that book")
                return
            }
            await self.services.playbackCoordinator.play(imported)
            self.controller?.pushNowPlaying()
        }
    }

    private func beginSearch() {
        let template = CPSearchTemplate()
        let delegate = CarPlaySearchDelegate(dispatcher: self, controller: controller)
        searchDelegate = delegate
        template.delegate = delegate
        controller?.push(template)
    }

    private func runSearch(query: String) {
        Task { [weak self] in
            let results = (try? await InternetArchiveClient().searchLibriVox(query: query, rows: 25)) ?? []
            guard let self, let controller = self.controller else { return }
            let sections = CarPlayMenuBuilder.searchResults(results.map(controller.makeCatalogSnapshot))
            controller.push(sections: sections, title: "Results")
        }
    }

    private func presentTransientAlert(_ title: String) {
        let alert = CPAlertTemplate(titleVariants: [title], actions: [])
        controller?.present(alert)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            self?.controller?.dismissPresented()
        }
    }

    private static func routeTitle(_ route: CarPlayBrowseRoute) -> String {
        switch route {
        case .favorites: return "Favorites"
        case .finished: return "Finished"
        case .inProgress: return "In Progress"
        case .playlist(_, let name): return name
        case .author(let name): return name
        case .narrator(let name): return name
        case .genre(_, let name): return name
        case .allPlaylists: return "Playlists"
        case .browseByAuthor: return "Authors"
        case .browseByNarrator: return "Narrators"
        }
    }
}

/// Voice-first search: results stream into the search template's own list; a
/// selected result imports-then-plays through the dispatcher.
@MainActor
private final class CarPlaySearchDelegate: NSObject, CPSearchTemplateDelegate {
    private weak var dispatcher: CarPlayActionDispatcher?
    private weak var controller: CarPlayInterfaceController?
    private var latestResults: [InternetArchiveSearchResult] = []
    private var searchTask: Task<Void, Never>?

    init(dispatcher: CarPlayActionDispatcher, controller: CarPlayInterfaceController?) {
        self.dispatcher = dispatcher
        self.controller = controller
    }

    nonisolated func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        updatedSearchText searchText: String,
        completionHandler: @escaping ([CPListItem]) -> Void
    ) {
        Task { @MainActor in
            self.searchTask?.cancel()
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else {
                completionHandler([])
                return
            }
            self.searchTask = Task { [weak self] in
                let results = (try? await InternetArchiveClient().searchLibriVox(query: trimmed, rows: 12)) ?? []
                guard let self, !Task.isCancelled else {
                    completionHandler([])
                    return
                }
                self.latestResults = results
                completionHandler(results.map { result in
                    let item = CPListItem(text: result.title, detailText: result.authorLine)
                    item.handler = { [weak self] _, done in
                        Task { @MainActor in
                            self?.dispatcher?.dispatch(.playCatalogItem(identifier: result.identifier))
                            done()
                        }
                    }
                    return item
                })
            }
        }
    }

    nonisolated func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        selectedResult item: CPListItem,
        completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            if let match = self.latestResults.first(where: { $0.title == item.text }) {
                self.dispatcher?.dispatch(.playCatalogItem(identifier: match.identifier))
            }
            completionHandler()
        }
    }
}
