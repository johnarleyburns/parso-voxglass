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
            return searchScope == .myBooks ? services.libraryStore.books : []
        }
        let query = searchText.lowercased()
        return services.libraryStore.books.filter { book in
            book.book.title.lowercased().contains(query)
                || book.book.authors.contains(where: { $0.lowercased().contains(query) })
        }
    }

    var body: some View {
        NavigationStack {
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
                } else {
                    if searchScope == .librivox {
                        if services.catalogStore.isSearching {
                            ProgressView("Searching...")
                        } else if let error = services.catalogStore.catalogError {
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
                            List(services.catalogStore.results, id: \.identifier) { result in
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
                    } else {
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
            }
            .searchable(text: $searchText, prompt: "Search books")
            .onChange(of: searchText) { _, newValue in
                guard !newValue.isEmpty else { return }
                Task {
                    if searchScope == .librivox {
                        await services.catalogStore.searchLibriVox(newValue)
                    }
                }
            }
            .onChange(of: searchScope) { _, _ in
                Task {
                    if searchScope == .librivox, !searchText.isEmpty {
                        await services.catalogStore.searchLibriVox(searchText)
                    }
                }
            }
            .accessibilityIdentifier(WatchAccessibilityID.rootSearch)
        }
    }
}

struct WatchRemoteBookDetailView: View {
    let identifier: String
    let title: String
    @EnvironmentObject var services: WatchAppServices
    @State private var isAdding = false
    @State private var addedBookID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .lineLimit(3)

                Text("Add to your library to stream or download.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isAdding {
                    ProgressView("Adding...")
                } else if let bookID = addedBookID {
                    VStack(spacing: 8) {
                        Text("Added to Library")
                            .font(.caption)
                            .foregroundStyle(.green)
                        Button {
                            playBook(bookID: bookID)
                        } label: {
                            HStack {
                                Image(systemName: "play.circle")
                                Text("Stream")
                            }
                        }
                        .accessibilityIdentifier(WatchAccessibilityID.bookStream)
                    }
                }

                if addedBookID == nil {
                    Button {
                        Task { await addToLibrary() }
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle")
                            Text("Add to My Books")
                        }
                    }
                    .disabled(isAdding)
                    .accessibilityIdentifier(WatchAccessibilityID.bookAdd)
                }
            }
            .padding()
        }
        .task {
            await services.libraryStore.refresh()
        }
    }

    private func addToLibrary() async {
        isAdding = true
        do {
            let client = InternetArchiveClient()
            let metadata = try await client.metadata(for: identifier)
            let result = try await services.libraryRepository.importInternetArchiveItem(
                metadata,
                sourceKind: .librivox
            )
            addedBookID = result.book.id
            await services.libraryStore.refresh()
        } catch {
            // Error adding book
        }
        isAdding = false
    }

    private func playBook(bookID: UUID) {
        guard let book = services.libraryStore.books.first(where: { $0.book.id == bookID }) else { return }
        services.playbackCoordinator.present(book)
    }
}
