import Foundation

/// Pure static builders: injected `CarPlayState` snapshots in, a value-typed
/// `CarPlayInterface` out. No I/O, no store references — every browse decision
/// (tab order, Continue-first, caps, empty states, dedup, the download gate)
/// is asserted host-side (docs/CARPLAY_DESIGN.md §4).
public enum CarPlayMenuBuilder {
    /// CarPlay truncates long lists while the car is moving. We cap ourselves so
    /// the tail is never silently dropped by the system mid-book.
    public static let drivingItemCap = 12

    // MARK: - Root

    public static func root(_ state: CarPlayState) -> CarPlayInterface {
        CarPlayInterface(tabs: [
            continueTab(state),
            libraryTab(state),
            downloadedTab(state),
            discoverTab(state),
            searchTab(state)
        ])
    }

    // MARK: - Tabs

    public static func continueTab(_ state: CarPlayState) -> CarPlayTab {
        var sections: [CarPlaySection] = []

        if state.hasCurrentSession,
           let currentID = state.currentBookID,
           let current = state.books.first(where: { $0.id == currentID }) {
            var item = bookItem(current, action: .resumeCurrent)
            item.id = "now-playing"
            item.accessory = .nowPlaying
            sections.append(CarPlaySection(header: "Now Playing", items: [item]))
        }

        let excludedID = state.hasCurrentSession ? state.currentBookID : nil
        let inProgress = newestFirst(state.books.filter { book in
            guard book.id != excludedID, let progress = book.progress else { return false }
            return !progress.isFinished
        })
        if !inProgress.isEmpty {
            sections.append(CarPlaySection(
                header: sections.isEmpty ? nil : "In Progress",
                items: applyCap(inProgress.map { bookItem($0, action: .playBook(bookID: $0.id)) })
            ))
        }

        let finished = newestFirst(state.books.filter { $0.progress?.isFinished == true && $0.id != excludedID })
        if !finished.isEmpty {
            sections.append(CarPlaySection(
                header: "Recently Finished",
                items: applyCap(finished.map { bookItem($0, action: .playBook(bookID: $0.id)) })
            ))
        }

        if sections.isEmpty {
            sections.append(emptyState(.continueListening))
        }

        return CarPlayTab(
            id: .continueListening,
            title: "Continue",
            systemImage: "arrow.clockwise.circle.fill",
            sections: sections
        )
    }

    public static func libraryTab(_ state: CarPlayState) -> CarPlayTab {
        var sections: [CarPlaySection] = []

        var routes: [CarPlayItem] = []
        if state.books.contains(where: { $0.isFavorite }) {
            routes.append(routeItem(id: "route-favorites", title: "Favorites",
                                    symbol: "heart.fill", route: .favorites))
        }
        if !state.playlists.isEmpty {
            routes.append(routeItem(id: "route-playlists", title: "Playlists",
                                    symbol: "music.note.list", route: .allPlaylists))
        }
        if state.books.contains(where: { !$0.authors.isEmpty }) {
            routes.append(routeItem(id: "route-authors", title: "Browse by Author",
                                    symbol: "person.fill", route: .browseByAuthor))
        }
        if state.books.contains(where: { !$0.narrators.isEmpty }) {
            routes.append(routeItem(id: "route-narrators", title: "Browse by Narrator",
                                    symbol: "waveform", route: .browseByNarrator))
        }
        if !routes.isEmpty {
            sections.append(CarPlaySection(items: routes))
        }

        let books = alphabetical(state.books)
        if books.isEmpty {
            sections.append(emptyState(.library))
        } else {
            sections.append(CarPlaySection(
                header: "Books",
                items: applyCap(books.map { bookItem($0, action: .openBook(bookID: $0.id)) })
            ))
        }

        return CarPlayTab(
            id: .library,
            title: "Library",
            systemImage: "books.vertical.fill",
            sections: sections
        )
    }

    public static func downloadedTab(_ state: CarPlayState) -> CarPlayTab {
        let downloaded = newestFirst(state.books.filter { $0.download == .downloaded })
        let sections: [CarPlaySection]
        if downloaded.isEmpty {
            sections = [emptyState(.downloaded)]
        } else {
            sections = [CarPlaySection(
                items: applyCap(downloaded.map { bookItem($0, action: .playBook(bookID: $0.id)) })
            )]
        }
        return CarPlayTab(
            id: .downloaded,
            title: "Downloaded",
            systemImage: "arrow.down.circle.fill",
            sections: sections
        )
    }

    public static func discoverTab(_ state: CarPlayState) -> CarPlayTab {
        var sections: [CarPlaySection] = []

        let recommendations = dedupedByIdentifier(state.recommendations)
        if recommendations.isEmpty {
            sections.append(emptyState(.discover))
        } else {
            sections.append(CarPlaySection(
                header: "For You",
                items: applyCap(recommendations.map(catalogItem))
            ))
        }

        let categories = [LibriVoxBrowseCategory.popular] + LibriVoxBrowseGroup.categories
        sections.append(CarPlaySection(
            header: "Browse LibriVox",
            items: applyCap(categories.map { category in
                CarPlayItem(
                    id: "genre-\(category.id)",
                    title: category.title,
                    artwork: .symbol(category.systemImage),
                    accessory: .disclosure,
                    action: .openRoute(.genre(collectionID: category.id, name: category.title))
                )
            })
        ))

        return CarPlayTab(
            id: .discover,
            title: "Discover",
            systemImage: "sparkles",
            sections: sections
        )
    }

    public static func searchTab(_ state: CarPlayState) -> CarPlayTab {
        CarPlayTab(
            id: .search,
            title: "Search",
            systemImage: "magnifyingglass",
            sections: [CarPlaySection(items: [
                CarPlayItem(
                    id: "search-launcher",
                    title: "Search LibriVox",
                    subtitle: "Tap, then speak a title or author",
                    artwork: .symbol("magnifyingglass"),
                    accessory: .disclosure,
                    action: .beginSearch
                )
            ])]
        )
    }

    // MARK: - Nested pushes

    public static func chapterList(
        book: CarPlayBookSnapshot,
        chapters: [CarPlayChapterSnapshot],
        nowPlayingChapterID: UUID?
    ) -> [CarPlaySection] {
        let items = chapters.sorted { $0.index < $1.index }.map { chapter in
            CarPlayItem(
                id: chapter.id.uuidString,
                title: chapter.title,
                detailText: chapter.duration.map { CarPlayTimeFormat.compact($0) },
                artwork: .none,
                accessory: chapter.id == nowPlayingChapterID ? .nowPlaying : .none,
                isEnabled: chapter.hasPlayableURL,
                action: .playChapter(bookID: book.id, chapterID: chapter.id)
            )
        }
        return [CarPlaySection(items: items)]
    }

    public static func routeList(_ route: CarPlayBrowseRoute, _ state: CarPlayState) -> [CarPlaySection] {
        switch route {
        case .favorites:
            return bookSections(alphabetical(state.books.filter { $0.isFavorite }))
        case .finished:
            return bookSections(newestFirst(state.books.filter { $0.progress?.isFinished == true }))
        case .inProgress:
            return bookSections(newestFirst(state.books.filter {
                guard let progress = $0.progress else { return false }
                return !progress.isFinished
            }))
        case .playlist(let id, _):
            guard let playlist = state.playlists.first(where: { $0.id == id }) else { return [] }
            let byID = Dictionary(uniqueKeysWithValues: state.books.map { ($0.id, $0) })
            return bookSections(playlist.bookIDs.compactMap { byID[$0] })
        case .author(let name):
            return bookSections(alphabetical(state.books.filter { book in
                book.authors.contains { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }
            }))
        case .narrator(let name):
            return bookSections(alphabetical(state.books.filter { book in
                book.narrators.contains { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }
            }))
        case .genre:
            return []
        case .allPlaylists:
            return [CarPlaySection(items: applyCap(state.playlists.map { playlist in
                CarPlayItem(
                    id: "playlist-\(playlist.id.uuidString)",
                    title: playlist.name,
                    detailText: "\(playlist.bookIDs.count) books",
                    artwork: .symbol("music.note.list"),
                    accessory: .disclosure,
                    action: .openRoute(.playlist(id: playlist.id, name: playlist.name))
                )
            }))]
        case .browseByAuthor:
            return nameSections(names: distinctNames(state.books.map(\.authors))) {
                .openRoute(.author($0))
            }
        case .browseByNarrator:
            return nameSections(names: distinctNames(state.books.map(\.narrators))) {
                .openRoute(.narrator($0))
            }
        }
    }

    public static func searchResults(_ results: [CarPlayCatalogSnapshot]) -> [CarPlaySection] {
        let deduped = dedupedByIdentifier(results)
        guard !deduped.isEmpty else {
            return [CarPlaySection(items: [
                CarPlayItem(
                    id: "search-empty",
                    title: "No results",
                    subtitle: "Try a different title or author",
                    artwork: .symbol("magnifyingglass"),
                    isEnabled: false,
                    action: .none
                )
            ])]
        }
        return [CarPlaySection(items: applyCap(deduped.map(catalogItem)))]
    }

    // MARK: - Pure helpers

    public static func progressDetail(_ p: CarPlayProgress) -> String {
        if p.isFinished {
            return "Finished"
        }
        let chapterNumber = p.chapterIndex + 1
        if let duration = p.chapterDuration, duration > 0, duration - p.position <= 60 {
            return "Finishing Ch \(chapterNumber)"
        }
        if let remaining = p.bookRemaining {
            return "Ch \(chapterNumber) of \(p.chapterCount) · \(CarPlayTimeFormat.compact(remaining)) left"
        }
        if let duration = p.chapterDuration {
            let remaining = max(0, duration - p.position)
            return "Ch \(chapterNumber) of \(p.chapterCount) · \(CarPlayTimeFormat.compact(remaining)) left in chapter"
        }
        return "Ch \(chapterNumber) of \(p.chapterCount)"
    }

    public static func bookItem(_ b: CarPlayBookSnapshot, action: CarPlayAction) -> CarPlayItem {
        let accessory: CarPlayAccessory
        if case .openBook = action {
            accessory = .disclosure
        } else {
            switch b.download {
            case .downloaded: accessory = .downloaded
            case .downloading(let fraction): accessory = .downloading(fraction)
            case .notDownloaded: accessory = .cloud
            }
        }
        return CarPlayItem(
            id: b.id.uuidString,
            title: b.title,
            subtitle: b.authorLine,
            detailText: b.progress.map(progressDetail),
            artwork: b.coverURL.map { .url($0) } ?? .symbol("headphones"),
            progress: b.progress.map(\.fraction),
            accessory: accessory,
            action: action
        )
    }

    public static func downloadAction(for b: CarPlayBookSnapshot, isDownloadsPro: Bool) -> CarPlayAction {
        switch b.download {
        case .downloaded:
            return .removeDownload(bookID: b.id)
        case .downloading:
            return .none
        case .notDownloaded:
            return isDownloadsPro
                ? .download(bookID: b.id)
                : .showProUpsell(.offlineDownloads)
        }
    }

    public static func applyCap(_ items: [CarPlayItem], limit: Int = drivingItemCap) -> [CarPlayItem] {
        Array(items.prefix(limit))
    }

    public static func emptyState(_ tab: CarPlayTabID) -> CarPlaySection {
        switch tab {
        case .continueListening:
            return CarPlaySection(items: [CarPlayItem(
                id: "empty-continue",
                title: "Nothing in progress yet",
                subtitle: "Find your next book in Discover",
                artwork: .symbol("sparkles"),
                accessory: .disclosure,
                action: .openTab(.discover)
            )])
        case .library:
            return CarPlaySection(items: [CarPlayItem(
                id: "empty-library",
                title: "Your library is empty",
                subtitle: "Find free audiobooks in Discover",
                artwork: .symbol("sparkles"),
                accessory: .disclosure,
                action: .openTab(.discover)
            )])
        case .downloaded:
            return CarPlaySection(items: [CarPlayItem(
                id: "empty-downloaded",
                title: "No downloads yet",
                subtitle: "Download books on Wi-Fi to listen offline.",
                artwork: .symbol("arrow.down.circle"),
                accessory: .disclosure,
                action: .openTab(.library)
            )])
        case .discover:
            return CarPlaySection(items: [CarPlayItem(
                id: "empty-discover",
                title: "Recommendations are warming up",
                subtitle: "Browse LibriVox below",
                artwork: .symbol("sparkles"),
                isEnabled: false,
                action: .none
            )])
        case .search:
            return CarPlaySection(items: [CarPlayItem(
                id: "empty-search",
                title: "Search LibriVox",
                artwork: .symbol("magnifyingglass"),
                accessory: .disclosure,
                action: .beginSearch
            )])
        }
    }

    // MARK: - Private

    private static func catalogItem(_ snapshot: CarPlayCatalogSnapshot) -> CarPlayItem {
        let action: CarPlayAction = snapshot.alreadyInLibrary.map { .playBook(bookID: $0) }
            ?? .playCatalogItem(identifier: snapshot.id)
        return CarPlayItem(
            id: "catalog-\(snapshot.id)",
            title: snapshot.title,
            subtitle: snapshot.authorLine,
            artwork: snapshot.coverURL.map { .url($0) } ?? .symbol("headphones"),
            action: action
        )
    }

    private static func routeItem(id: String, title: String, symbol: String, route: CarPlayBrowseRoute) -> CarPlayItem {
        CarPlayItem(
            id: id,
            title: title,
            artwork: .symbol(symbol),
            accessory: .disclosure,
            action: .openRoute(route)
        )
    }

    private static func bookSections(_ books: [CarPlayBookSnapshot]) -> [CarPlaySection] {
        [CarPlaySection(items: applyCap(books.map { bookItem($0, action: .openBook(bookID: $0.id)) }))]
    }

    private static func nameSections(names: [String], action: (String) -> CarPlayAction) -> [CarPlaySection] {
        [CarPlaySection(items: applyCap(names.map { name in
            CarPlayItem(
                id: "name-\(name)",
                title: name,
                artwork: .symbol("person.fill"),
                accessory: .disclosure,
                action: action(name)
            )
        }))]
    }

    private static func distinctNames(_ groups: [[String]]) -> [String] {
        let trimmed = groups.flatMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(Set(trimmed)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Newest-first by `lastPlayedAt` (nil last); stable for equal keys so the
    /// driving cap keeps the most relevant head deterministically.
    private static func newestFirst(_ books: [CarPlayBookSnapshot]) -> [CarPlayBookSnapshot] {
        books.enumerated().sorted { lhs, rhs in
            switch (lhs.element.lastPlayedAt, rhs.element.lastPlayedAt) {
            case (nil, nil): return lhs.offset < rhs.offset
            case (nil, _): return false
            case (_, nil): return true
            case (let l?, let r?):
                if l != r { return l > r }
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    private static func alphabetical(_ books: [CarPlayBookSnapshot]) -> [CarPlayBookSnapshot] {
        books.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private static func dedupedByIdentifier(_ snapshots: [CarPlayCatalogSnapshot]) -> [CarPlayCatalogSnapshot] {
        var seen = Set<String>()
        return snapshots.filter { seen.insert($0.id).inserted }
    }
}
