import XCTest
@testable import VoxglassCore

final class CarPlayMenuBuilderTests: XCTestCase {

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

    func testRootHasFiveTabsInCanonicalOrder() {
        let interface = CarPlayMenuBuilder.root(CarPlayState())
        let ids = interface.tabs.map(\.id)
        XCTAssertEqual(ids, [.continueListening, .library, .downloaded, .discover, .search])
    }

    // MARK: - Continue tab

    func testContinueTabTopRowIsNowPlayingWhenSessionExists() {
        let id = UUID()
        let book = makeBook(id: id, title: "Current", lastPlayedAt: Date())
        let state = CarPlayState(books: [book], hasCurrentSession: true, currentBookID: id)
        let tab = CarPlayMenuBuilder.continueTab(state)
        guard let firstSection = tab.sections.first, let topItem = firstSection.items.first else {
            XCTFail("Expected now-playing section")
            return
        }
        XCTAssertEqual(firstSection.header, "Now Playing")
        XCTAssertEqual(topItem.title, "Current")
        XCTAssertEqual(topItem.action, .resumeCurrent)
        XCTAssertEqual(topItem.accessory, .nowPlaying)
    }

    func testContinueTabListsInProgressBooksNewestFirst() {
        let now = Date()
        let older = makeBook(id: UUID(), title: "Older", lastPlayedAt: now.addingTimeInterval(-3600), progress: makeProgress())
        let newer = makeBook(id: UUID(), title: "Newer", lastPlayedAt: now, progress: makeProgress())
        let state = CarPlayState(books: [older, newer])
        let tab = CarPlayMenuBuilder.continueTab(state)
        let inProgressItems = tab.sections.flatMap(\.items)
            .filter { $0.action != .openTab(.discover) } // exclude empty-state CTA
        let titles = inProgressItems.map(\.title)
        XCTAssertEqual(titles.first, "Newer")
        XCTAssertEqual(titles.last, "Older")
    }

    func testContinueTabExcludesFinishedBooksFromInProgress() {
        let active = makeBook(id: UUID(), title: "Active", lastPlayedAt: Date(), progress: makeProgress(isFinished: false))
        let done = makeBook(id: UUID(), title: "Done", lastPlayedAt: Date(), progress: makeProgress(isFinished: true))
        let state = CarPlayState(books: [active, done])
        let tab = CarPlayMenuBuilder.continueTab(state)
        let inProgressTitles = tab.sections
            .filter { $0.header != "Recently Finished" }
            .flatMap(\.items).map(\.title)
        XCTAssertTrue(inProgressTitles.contains("Active"))
        XCTAssertFalse(inProgressTitles.contains("Done"))
        let finishedTitles = tab.sections
            .first { $0.header == "Recently Finished" }?
            .items.map(\.title) ?? []
        XCTAssertEqual(finishedTitles, ["Done"])
    }

    func testContinueTabEmptyStateWhenNothingPlayed() {
        let state = CarPlayState(books: [])
        let tab = CarPlayMenuBuilder.continueTab(state)
        let items = tab.sections.flatMap(\.items)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.action, .openTab(.discover))
    }

    // MARK: - Library tab

    func testLibraryTabBookRowPushesChapterList() {
        let book = makeBook(id: UUID(), title: "Test Book")
        let state = CarPlayState(books: [book])
        let tab = CarPlayMenuBuilder.libraryTab(state)
        let bookItems = tab.sections.flatMap(\.items).filter { $0.id == book.id.uuidString }
        XCTAssertEqual(bookItems.count, 1)
        XCTAssertEqual(bookItems.first?.action, .openBook(bookID: book.id))
    }

    func testLibraryTabExposesFavoritesRouteOnlyWhenFavoritesExist() {
        let fav = makeBook(id: UUID(), title: "Fav", isFavorite: true)
        let state = CarPlayState(books: [fav])
        let tab = CarPlayMenuBuilder.libraryTab(state)
        let routeItems = tab.sections.flatMap(\.items).filter { $0.id.hasPrefix("route-") }
        XCTAssertTrue(routeItems.contains { $0.id == "route-favorites" })
    }

    func testLibraryTabExposesPlaylistsRouteOnlyWhenPlaylistsExist() {
        let playlist = CarPlayPlaylistSnapshot(id: UUID(), name: "My List", bookIDs: [])
        let state = CarPlayState(playlists: [playlist])
        let tab = CarPlayMenuBuilder.libraryTab(state)
        let routeItems = tab.sections.flatMap(\.items).filter { $0.id.hasPrefix("route-") }
        XCTAssertTrue(routeItems.contains { $0.id == "route-playlists" })
    }

    // MARK: - Downloaded tab

    func testDownloadedTabIncludesOnlyDownloadedBooks() {
        let downloaded = makeBook(id: UUID(), title: "Offline", download: .downloaded)
        let streaming = makeBook(id: UUID(), title: "Streaming", download: .notDownloaded)
        let state = CarPlayState(books: [downloaded, streaming])
        let tab = CarPlayMenuBuilder.downloadedTab(state)
        let titles = tab.sections.flatMap(\.items).map(\.title)
        XCTAssertTrue(titles.contains("Offline"))
        XCTAssertFalse(titles.contains("Streaming"))
    }

    func testDownloadedTabEmptyStateCopy() {
        let state = CarPlayState()
        let tab = CarPlayMenuBuilder.downloadedTab(state)
        let items = tab.sections.flatMap(\.items)
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items.first?.subtitle?.contains("Wi-Fi") ?? false)
    }

    // MARK: - Discover tab

    func testDiscoverTabMapsRecommendationsToPlayCatalogItem() {
        let rec = CarPlayCatalogSnapshot(id: "test-id", title: "A Great Book", authorLine: "Author X")
        let state = CarPlayState(recommendations: [rec])
        let tab = CarPlayMenuBuilder.discoverTab(state)
        let forYouItems = tab.sections.first(where: { $0.header == "For You" })?.items ?? []
        let catalogItem = forYouItems.first { $0.id == "catalog-test-id" }
        XCTAssertEqual(catalogItem?.action, .playCatalogItem(identifier: "test-id"))
    }

    func testDiscoverTabDedupsByIdentifier() {
        let rec1 = CarPlayCatalogSnapshot(id: "dup-id", title: "First", authorLine: "Author")
        let rec2 = CarPlayCatalogSnapshot(id: "dup-id", title: "Second", authorLine: "Author")
        let state = CarPlayState(recommendations: [rec1, rec2])
        let tab = CarPlayMenuBuilder.discoverTab(state)
        let catalogItems = tab.sections.flatMap(\.items).filter { $0.id.contains("catalog-") }
        XCTAssertEqual(catalogItems.count, 1)
    }

    func testDiscoverItemAlreadyInLibraryUsesPlayBookNotImport() {
        let bookID = UUID()
        let rec = CarPlayCatalogSnapshot(id: "instack", title: "In Library", authorLine: "Author", alreadyInLibrary: bookID)
        let state = CarPlayState(recommendations: [rec])
        let tab = CarPlayMenuBuilder.discoverTab(state)
        let item = tab.sections.flatMap(\.items).first { $0.id == "catalog-instack" }
        XCTAssertEqual(item?.action, .playBook(bookID: bookID))
    }

    // MARK: - Search

    func testSearchResultsMapToCatalogItems() {
        let result = CarPlayCatalogSnapshot(id: "sr1", title: "Search Hit", authorLine: "Author")
        let sections = CarPlayMenuBuilder.searchResults([result])
        let items = sections.flatMap(\.items)
        XCTAssertTrue(items.first?.id == "catalog-sr1")
    }

    // MARK: - Chapter list

    func testChapterListMarksCurrentChapterAsNowPlaying() {
        let bookID = UUID()
        let book = makeBook(id: bookID, title: "Book")
        let ch1 = CarPlayChapterSnapshot(id: UUID(), title: "Ch 1", index: 0)
        let ch2 = CarPlayChapterSnapshot(id: UUID(), title: "Ch 2", index: 1)
        let sections = CarPlayMenuBuilder.chapterList(book: book, chapters: [ch1, ch2], nowPlayingChapterID: ch2.id)
        let allItems = sections.flatMap(\.items)
        XCTAssertEqual(allItems[0].accessory, .none)
        XCTAssertEqual(allItems[1].accessory, .nowPlaying)
    }

    func testChapterListDisabledWhenNoPlayableURL() {
        let bookID = UUID()
        let book = makeBook(id: bookID, title: "Book")
        let chapter = CarPlayChapterSnapshot(id: UUID(), title: "Broken", index: 0, hasPlayableURL: false)
        let sections = CarPlayMenuBuilder.chapterList(book: book, chapters: [chapter], nowPlayingChapterID: nil)
        XCTAssertEqual(sections.flatMap(\.items).first?.isEnabled, false)
    }

    // MARK: - Tab metadata

    func testEachTabHasExpectedTitle() {
        let state = CarPlayState()
        let tabs = CarPlayMenuBuilder.root(state).tabs
        let titles = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.title) })
        XCTAssertEqual(titles[.continueListening], "Continue")
        XCTAssertEqual(titles[.library], "Library")
        XCTAssertEqual(titles[.downloaded], "Downloaded")
        XCTAssertEqual(titles[.discover], "Discover")
        XCTAssertEqual(titles[.search], "Search")
    }
}
