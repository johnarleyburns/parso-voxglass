import SwiftUI
import VoxglassCore

struct WatchSearchView: View {
    @EnvironmentObject var services: WatchAppServices
    @State private var searchText = ""
    @State private var searchScope: WatchSearchScope = .myBooks

    enum WatchSearchScope: String, CaseIterable {
        case myBooks = "My Books"
        case librivox = "LibriVox"
    }

    private var filteredMyBooks: [BookWithChapters] {
        guard searchScope == .myBooks, !searchText.isEmpty else {
            return searchScope == .myBooks ? services.books : []
        }
        let query = searchText.lowercased()
        return services.books.filter { book in
            book.book.title.lowercased().contains(query)
                || book.book.authors.contains(where: { $0.lowercased().contains(query) })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Scope", selection: $searchScope) {
                ForEach(WatchSearchScope.allCases, id: \.self) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.automatic)

            if searchText.isEmpty {
                VStack(spacing: 8) {
                    Text("Search")
                        .font(.headline)
                    Text("Type to search My Books or LibriVox")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else if searchScope == .librivox {
                librivoxResults
            } else {
                myBooksResults
            }
        }
        .searchable(text: $searchText, prompt: "Search books")
        .onChange(of: searchText) { _, newValue in
            guard !newValue.isEmpty else { return }
            Task {
                if searchScope == .librivox {
                    await services.searchLibriVox(newValue)
                }
            }
        }
        .onChange(of: searchScope) { _, _ in
            Task {
                if searchScope == .librivox, !searchText.isEmpty {
                    await services.searchLibriVox(searchText)
                }
            }
        }
        .accessibilityIdentifier(WatchAccessibilityID.rootSearch)
    }

    @ViewBuilder
    private var librivoxResults: some View {
        if services.isSearching {
            ProgressView("Searching...")
        } else if let error = services.watchError, services.searchResults.isEmpty {
            VStack(spacing: 8) {
                Text("Search Error")
                    .font(.caption)
                    .foregroundStyle(.red)
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        } else {
            List(services.searchResults, id: \.identifier) { result in
                NavigationLink {
                    WatchRemoteBookDetailView(identifier: result.identifier, title: result.title)
                        .accessibilityIdentifier(WatchAccessibilityID.bookDetail)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.title)
                            .font(.caption)
                            .lineLimit(2)
                        if !result.creators.isEmpty {
                            Text(result.creators.joined(separator: ", "))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var myBooksResults: some View {
        if filteredMyBooks.isEmpty {
            Text("No books found")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            List(filteredMyBooks) { book in
                NavigationLink {
                    WatchBookDetailView(book: book)
                        .accessibilityIdentifier(WatchAccessibilityID.bookDetail)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(book.book.title)
                            .font(.caption)
                            .lineLimit(2)
                        Text(book.book.authorLine)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

struct WatchRemoteBookDetailView: View {
    let identifier: String
    let title: String
    @EnvironmentObject var services: WatchAppServices
    @State private var isAdding = false
    @State private var isPlaying = false
    @State private var addedBookID: UUID?
    @State private var showNowPlaying = false
    @State private var detailError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .lineLimit(3)

                Text("Add to your library to stream or download.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isAdding || isPlaying {
                    ProgressView(isPlaying ? "Starting..." : "Adding...")
                } else if let bookID = addedBookID {
                    VStack(spacing: 8) {
                        Text("Added to Library")
                            .font(.caption)
                            .foregroundStyle(.green)
                        Button {
                            Task { await playBook(bookID: bookID) }
                        } label: {
                            HStack {
                                Image(systemName: "play.circle")
                                Text("Stream")
                            }
                        }
                        .accessibilityIdentifier(WatchAccessibilityID.bookStream)
                    }
                }

                if let detailError {
                    Text(detailError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(4)
                }

                if addedBookID == nil {
                    Button {
                        Task { await addToLibrary(playAfterImport: true) }
                    } label: {
                        HStack {
                            Image(systemName: "play.circle")
                            Text("Stream")
                        }
                    }
                    .disabled(isAdding || isPlaying)
                    .accessibilityIdentifier(WatchAccessibilityID.bookStream)

                    Button {
                        Task { await addToLibrary(playAfterImport: false) }
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle")
                            Text("Add to My Books")
                        }
                    }
                    .disabled(isAdding || isPlaying)
                    .accessibilityIdentifier(WatchAccessibilityID.bookAdd)
                }

            }
            .padding()
        }
        .navigationDestination(isPresented: $showNowPlaying) {
            WatchNowPlayingView()
        }
        .task { await services.refreshLocalLibrary() }
    }

    private func addToLibrary(playAfterImport: Bool) async {
        isAdding = true
        detailError = nil
        defer { isAdding = false }

        do {
            let client = InternetArchiveClient()
            let metadata = try await client.metadata(for: identifier)
            let result = try await services.libraryRepository.importInternetArchiveItem(
                metadata,
                sourceKind: metadata.sourceKind == .librivox ? .librivox : .internetArchive
            )
            addedBookID = result.book.id
            await services.refreshLocalLibrary()
            if playAfterImport {
                await playBook(bookID: result.book.id)
            }
        } catch {
            detailError = error.localizedDescription
        }
    }

    private func playBook(bookID: UUID) async {
        guard let book = services.books.first(where: { $0.book.id == bookID }) else { return }
        isPlaying = true
        detailError = nil
        await services.playbackCoordinator.play(book)
        isPlaying = false
        if services.playbackCoordinator.currentSession?.isPlaying == true {
            showNowPlaying = true
        } else {
            detailError = services.playbackCoordinator.playbackError
        }
    }
}
