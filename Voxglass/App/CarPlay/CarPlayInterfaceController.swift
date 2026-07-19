import CarPlay
import Combine
import UIKit
import VoxglassCore

/// Owns the `CPInterfaceController` for the CarPlay scene: builds the pure
/// `CarPlayState` from the live stores, hands it to `CarPlayMenuBuilder`,
/// renders via `CarPlayTemplateRenderer`, and keeps the tabs current with
/// debounced store subscriptions (docs/CARPLAY_DESIGN.md §6.4).
@MainActor
final class CarPlayInterfaceController {
    private let interfaceController: CPInterfaceController
    private let services: AppServices
    private var dispatcher: CarPlayActionDispatcher?
    private var nowPlayingConfigurator: CarPlayNowPlayingConfigurator?
    private var cancellables: Set<AnyCancellable> = []
    private var tabBar: CPTabBarTemplate?
    private var tabTemplates: [CarPlayTabID: CPListTemplate] = [:]

    init(interfaceController: CPInterfaceController, services: AppServices) {
        self.interfaceController = interfaceController
        self.services = services
    }

    func start() {
        let dispatcher = CarPlayActionDispatcher(services: services, controller: self)
        self.dispatcher = dispatcher
        nowPlayingConfigurator = CarPlayNowPlayingConfigurator(
            coordinator: services.playbackCoordinator,
            dispatcher: dispatcher
        )
        buildRoot()
        subscribe()
    }

    func stop() {
        cancellables.removeAll()
        nowPlayingConfigurator = nil
        dispatcher = nil
        tabTemplates = [:]
        tabBar = nil
    }

    // MARK: - State snapshot

    func makeState() -> CarPlayState {
        let library = services.libraryStore
        let coordinator = services.playbackCoordinator

        let lastPlayedByID: [UUID: Date] = Dictionary(
            uniqueKeysWithValues: library.recentlyPlayed.enumerated().map { index, book in
                (book.book.id, Date(timeIntervalSinceNow: -Double(index)))
            }
        )

        return CarPlayState(
            books: library.books.map { makeBookSnapshot($0, lastPlayedAt: lastPlayedByID[$0.book.id]) },
            recentlyPlayed: library.recentlyPlayed.map { makeBookSnapshot($0, lastPlayedAt: lastPlayedByID[$0.book.id]) },
            playlists: services.playlistStore.playlists.map {
                CarPlayPlaylistSnapshot(id: $0.id, name: $0.title, bookIDs: [])
            },
            recommendations: services.homeRecommendationStore.recommendations.map(makeCatalogSnapshot),
            searchResults: services.catalogStore.results.map(makeCatalogSnapshot),
            hasCurrentSession: coordinator.currentSession != nil,
            currentBookID: coordinator.currentSession?.book.id
        )
    }

    func makeCatalogSnapshot(_ result: InternetArchiveSearchResult) -> CarPlayCatalogSnapshot {
        let library = services.libraryStore
        let inLibrary = library.books.first { book in
            library.source(for: book.book)?.url?.lastPathComponent == result.identifier
        }
        return CarPlayCatalogSnapshot(
            id: result.identifier,
            title: result.title,
            authorLine: result.authorLine,
            coverURL: result.coverURL,
            alreadyInLibrary: inLibrary?.book.id
        )
    }

    func makeBookSnapshot(_ book: BookWithChapters, lastPlayedAt: Date?) -> CarPlayBookSnapshot {
        let download: CarPlayDownloadState
        switch services.offlineDownloadManager.state(for: book.book.id) {
        case .cached: download = .downloaded
        case .downloading(let fraction): download = .downloading(fraction)
        case .notCached, .failed: download = .notDownloaded
        }

        var progress: CarPlayProgress?
        if let session = services.playbackCoordinator.currentSession, session.book.id == book.book.id {
            progress = CarPlayProgress(
                chapterIndex: session.chapterIndex,
                chapterCount: session.chapters.count,
                chapterTitle: session.chapter.title,
                position: session.position,
                chapterDuration: session.duration,
                bookRemaining: session.bookRemaining,
                isFinished: false
            )
        } else if let bookProgress = services.libraryStore.progressByBook[book.book.id] {
            let sorted = book.chapters.naturallySorted()
            progress = CarPlayProgress.derive(
                cumulativePosition: bookProgress.lastPosition,
                isFinished: bookProgress.isFinished,
                chapterTitles: sorted.map(\.title),
                chapterDurations: sorted.map(\.duration)
            )
        }

        return CarPlayBookSnapshot(
            id: book.book.id,
            title: book.book.title,
            authorLine: book.book.authorLine,
            authors: book.book.authors,
            narrators: book.book.narrators,
            coverURL: book.book.coverURL,
            chapterCount: book.chapters.count,
            isFavorite: book.book.isFavorite,
            lastPlayedAt: lastPlayedAt,
            progress: progress,
            download: download
        )
    }

    // MARK: - Rendering

    private func buildRoot() {
        guard let dispatcher else { return }
        let interface = CarPlayMenuBuilder.root(makeState())
        tabTemplates = [:]
        let templates = interface.tabs.map { tab in
            let template = CarPlayTemplateRenderer.tabTemplate(
                tab,
                dispatcher: .init(dispatch: { [weak dispatcher] in dispatcher?.dispatch($0) }),
                artwork: .shared
            )
            tabTemplates[tab.id] = template
            return template
        }
        let tabBar = CPTabBarTemplate(templates: templates)
        self.tabBar = tabBar
        interfaceController.setRootTemplate(tabBar, animated: false, completion: nil)
    }

    private func refreshTabs() {
        guard let dispatcher else { return }
        let interface = CarPlayMenuBuilder.root(makeState())
        for tab in interface.tabs {
            guard let template = tabTemplates[tab.id] else { continue }
            template.updateSections(CarPlayTemplateRenderer.sections(
                tab.sections,
                dispatcher: .init(dispatch: { [weak dispatcher] in dispatcher?.dispatch($0) }),
                artwork: .shared
            ))
        }
    }

    private func subscribe() {
        let library = services.libraryStore
        let triggers: [AnyPublisher<Void, Never>] = [
            library.$books.map { _ in }.eraseToAnyPublisher(),
            library.$recentlyPlayed.map { _ in }.eraseToAnyPublisher(),
            library.$progressByBook.map { _ in }.eraseToAnyPublisher(),
            services.playbackCoordinator.$currentSession
                .map { ($0?.book.id, $0?.chapter.id, $0 != nil) }
                .removeDuplicates { $0 == $1 }
                .map { _ in }
                .eraseToAnyPublisher(),
            services.offlineDownloadManager.$state.map { _ in }.eraseToAnyPublisher(),
            services.homeRecommendationStore.$recommendations.map { _ in }.eraseToAnyPublisher(),
            services.playlistStore.$playlists.map { _ in }.eraseToAnyPublisher()
        ]

        // Progress ticks at 1 Hz upstream; the debounce keeps template updates
        // from thrashing the head unit.
        Publishers.MergeMany(triggers)
            .debounce(for: .seconds(0.3), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                self?.refreshTabs()
            }
            .store(in: &cancellables)
    }

    // MARK: - Navigation (called by the dispatcher)

    func selectTab(_ id: CarPlayTabID) {
        guard let tabBar,
              let index = CarPlayTabID.allCases.firstIndex(of: id),
              tabBar.templates.indices.contains(index) else { return }
        interfaceController.popToRootTemplate(animated: true, completion: nil)
        tabBar.selectTemplate(at: index)
    }

    func push(sections: [CarPlaySection], title: String) {
        guard let dispatcher else { return }
        let template = CarPlayTemplateRenderer.listTemplate(
            title: title,
            sections: sections,
            dispatcher: .init(dispatch: { [weak dispatcher] in dispatcher?.dispatch($0) }),
            artwork: .shared
        )
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    func push(_ template: CPTemplate) {
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    func pushNowPlaying() {
        guard !(interfaceController.topTemplate is CPNowPlayingTemplate) else { return }
        interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    func present(_ template: CPTemplate) {
        interfaceController.presentTemplate(template, animated: true, completion: nil)
    }

    func dismissPresented() {
        guard interfaceController.presentedTemplate != nil else { return }
        interfaceController.dismissTemplate(animated: true, completion: nil)
    }
}
