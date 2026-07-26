import Testing
import Foundation
@testable import VoxglassCore

@Suite struct CarPlayMenuBuilderTests {

    // MARK: - Fixtures

    private func makeBook(
        id: UUID = UUID(),
        title: String,
        chapterCount: Int = 10,
        lastPlayedAt: Date? = nil,
        progress: CarPlayProgress? = nil,
        download: CarPlayDownloadState = .notDownloaded,
        authors: [String] = ["Author Name"],
        isFavorite: Bool = false
    ) -> CarPlayBookSnapshot {
        CarPlayBookSnapshot(
            id: id,
            title: title,
            authorLine: authors.joined(separator: ", "),
            authors: authors,
            chapterCount: chapterCount,
            isFavorite: isFavorite,
            lastPlayedAt: lastPlayedAt,
            progress: progress,
            download: download
        )
    }

    private func makeProgress(chapterIndex: Int = 0, chapterCount: Int = 10, isFinished: Bool = false) -> CarPlayProgress {
        CarPlayProgress(
            chapterIndex: chapterIndex,
            chapterCount: chapterCount,
            chapterTitle: "Ch \(chapterIndex + 1)",
            position: 300,
            chapterDuration: 1800,
            bookRemaining: 3600,
            isFinished: isFinished
        )
    }

    // MARK: - Root

    @Test func rootHasFiveTabsInCanonicalOrder() {
        let interface = CarPlayMenuBuilder.root(CarPlayState())
        let ids = interface.tabs.map(\.id)
        #expect(ids == [.continueListening, .library, .downloaded, .discover, .search])
    }

    // MARK: - Continue tab

    @Test func continueTabTopRowIsNowPlayingWhenSessionExists() {
        let id = UUID()
        let book = makeBook(id: id, title: "Current", lastPlayedAt: Date())
        let state = CarPlayState(books: [book], hasCurrentSession: true, currentBookID: id)
        let tab = CarPlayMenuBuilder.continueTab(state)
        guard let firstSection = tab.sections.first, let topItem = firstSection.items.first else {
            Issue.record("Expected now-playing section")
            return
        }
        #expect(firstSection.header == "Now Playing")
        #expect(topItem.title == "Current")
        #expect(topItem.action == .resumeCurrent)
        #expect(topItem.accessory == .nowPlaying)
    }

    @Test func continueTabListsInProgressBooksNewestFirst() {
        let now = Date()
        let older = makeBook(id: UUID(), title: "Older", lastPlayedAt: now.addingTimeInterval(-3600), progress: makeProgress())
        let newer = makeBook(id: UUID(), title: "Newer", lastPlayedAt: now, progress: makeProgress())
        let state = CarPlayState(books: [older, newer])
        let tab = CarPlayMenuBuilder.continueTab(state)
        let inProgressItems = tab.sections.flatMap(\.items)
            .filter { $0.action != .openTab(.discover) } // exclude empty-state CTA
        let titles = inProgressItems.map(\.title)
        #expect(titles.first == "Newer")
        #expect(titles.last == "Older")
    }

    @Test func continueTabExcludesFinishedBooksFromInProgress() {
        let active = makeBook(id: UUID(), title: "Active", lastPlayedAt: Date(), progress: makeProgress(isFinished: false))
        let done = makeBook(id: UUID(), title: "Done", lastPlayedAt: Date(), progress: makeProgress(isFinished: true))
        let state = CarPlayState(books: [active, done])
        let tab = CarPlayMenuBuilder.continueTab(state)
        let inProgressTitles = tab.sections
            .filter { $0.header != "Recently Finished" }
            .flatMap(\.items).map(\.title)
        #expect(inProgressTitles.contains("Active"))
        #expect(!(inProgressTitles.contains("Done")))
        let finishedTitles = tab.sections
            .first { $0.header == "Recently Finished" }?
            .items.map(\.title) ?? []
        #expect(finishedTitles == ["Done"])
    }

    @Test func continueTabEmptyStateWhenNothingPlayed() {
        let state = CarPlayState(books: [])
        let tab = CarPlayMenuBuilder.continueTab(state)
        let items = tab.sections.flatMap(\.items)
        #expect(items.count == 1)
        #expect(items.first?.action == .openTab(.discover))
    }

    // MARK: - Library tab

    @Test func libraryTabBookRowPushesChapterList() {
        let book = makeBook(id: UUID(), title: "Test Book")
        let state = CarPlayState(books: [book])
        let tab = CarPlayMenuBuilder.libraryTab(state)
        let bookItems = tab.sections.flatMap(\.items).filter { $0.id == book.id.uuidString }
        #expect(bookItems.count == 1)
        #expect(bookItems.first?.action == .openBook(bookID: book.id))
    }

    @Test func libraryTabExposesFavoritesRouteOnlyWhenFavoritesExist() {
        let fav = makeBook(id: UUID(), title: "Fav", isFavorite: true)
        let state = CarPlayState(books: [fav])
        let tab = CarPlayMenuBuilder.libraryTab(state)
        let routeItems = tab.sections.flatMap(\.items).filter { $0.id.hasPrefix("route-") }
        #expect(routeItems.contains { $0.id == "route-favorites" })
    }

    @Test func libraryTabExposesPlaylistsRouteOnlyWhenPlaylistsExist() {
        let playlist = CarPlayPlaylistSnapshot(id: UUID(), name: "My List", bookIDs: [])
        let state = CarPlayState(playlists: [playlist])
        let tab = CarPlayMenuBuilder.libraryTab(state)
        let routeItems = tab.sections.flatMap(\.items).filter { $0.id.hasPrefix("route-") }
        #expect(routeItems.contains { $0.id == "route-playlists" })
    }

    // MARK: - Downloaded tab

    @Test func downloadedTabIncludesOnlyDownloadedBooks() {
        let downloaded = makeBook(id: UUID(), title: "Offline", download: .downloaded)
        let streaming = makeBook(id: UUID(), title: "Streaming", download: .notDownloaded)
        let state = CarPlayState(books: [downloaded, streaming])
        let tab = CarPlayMenuBuilder.downloadedTab(state)
        let titles = tab.sections.flatMap(\.items).map(\.title)
        #expect(titles.contains("Offline"))
        #expect(!(titles.contains("Streaming")))
    }

    @Test func downloadedTabEmptyStateCopy() {
        let state = CarPlayState()
        let tab = CarPlayMenuBuilder.downloadedTab(state)
        let items = tab.sections.flatMap(\.items)
        #expect(items.count == 1)
        #expect(items.first?.subtitle?.contains("Wi-Fi") ?? false)
    }

    // MARK: - Discover tab

    @Test func discoverTabMapsRecommendationsToPlayCatalogItem() {
        let rec = CarPlayCatalogSnapshot(id: "test-id", title: "A Great Book", authorLine: "Author X")
        let state = CarPlayState(recommendations: [rec])
        let tab = CarPlayMenuBuilder.discoverTab(state)
        let forYouItems = tab.sections.first(where: { $0.header == "For You" })?.items ?? []
        let catalogItem = forYouItems.first { $0.id == "catalog-test-id" }
        #expect(catalogItem?.action == .playCatalogItem(identifier: "test-id"))
    }

    @Test func discoverTabDedupsByIdentifier() {
        let rec1 = CarPlayCatalogSnapshot(id: "dup-id", title: "First", authorLine: "Author")
        let rec2 = CarPlayCatalogSnapshot(id: "dup-id", title: "Second", authorLine: "Author")
        let state = CarPlayState(recommendations: [rec1, rec2])
        let tab = CarPlayMenuBuilder.discoverTab(state)
        let catalogItems = tab.sections.flatMap(\.items).filter { $0.id.contains("catalog-") }
        #expect(catalogItems.count == 1)
    }

    @Test func discoverItemAlreadyInLibraryUsesPlayBookNotImport() {
        let bookID = UUID()
        let rec = CarPlayCatalogSnapshot(id: "instack", title: "In Library", authorLine: "Author", alreadyInLibrary: bookID)
        let state = CarPlayState(recommendations: [rec])
        let tab = CarPlayMenuBuilder.discoverTab(state)
        let item = tab.sections.flatMap(\.items).first { $0.id == "catalog-instack" }
        #expect(item?.action == .playBook(bookID: bookID))
    }

    // MARK: - Search

    @Test func searchResultsMapToCatalogItems() {
        let result = CarPlayCatalogSnapshot(id: "sr1", title: "Search Hit", authorLine: "Author")
        let sections = CarPlayMenuBuilder.searchResults([result])
        let items = sections.flatMap(\.items)
        #expect(items.first?.id == "catalog-sr1")
    }

    // MARK: - Chapter list

    @Test func chapterListMarksCurrentChapterAsNowPlaying() {
        let bookID = UUID()
        let book = makeBook(id: bookID, title: "Book")
        let ch1 = CarPlayChapterSnapshot(id: UUID(), title: "Ch 1", index: 0)
        let ch2 = CarPlayChapterSnapshot(id: UUID(), title: "Ch 2", index: 1)
        let sections = CarPlayMenuBuilder.chapterList(book: book, chapters: [ch1, ch2], nowPlayingChapterID: ch2.id)
        let allItems = sections.flatMap(\.items)
        #expect(allItems[0].accessory == .none)
        #expect(allItems[1].accessory == .nowPlaying)
    }

    @Test func chapterListDisabledWhenNoPlayableURL() {
        let bookID = UUID()
        let book = makeBook(id: bookID, title: "Book")
        let chapter = CarPlayChapterSnapshot(id: UUID(), title: "Broken", index: 0, hasPlayableURL: false)
        let sections = CarPlayMenuBuilder.chapterList(book: book, chapters: [chapter], nowPlayingChapterID: nil)
        #expect(sections.flatMap(\.items).first?.isEnabled == false)
    }

    // MARK: - Tab metadata

    @Test func eachTabHasExpectedTitle() {
        let state = CarPlayState()
        let tabs = CarPlayMenuBuilder.root(state).tabs
        let titles = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.title) })
        #expect(titles[.continueListening] == "Continue")
        #expect(titles[.library] == "Library")
        #expect(titles[.downloaded] == "Downloaded")
        #expect(titles[.discover] == "Discover")
        #expect(titles[.search] == "Search")
    }
}
