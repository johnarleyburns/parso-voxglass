import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @State private var query = ""

    var body: some View {
        VoxglassScreen(title: "Search") {
            VStack(alignment: .leading, spacing: 16) {
                TextField("Title or author", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(.top, 12)

                if results.isEmpty {
                    ContentUnavailableView("No Results", systemImage: "magnifyingglass")
                        .padding()
                        .glassPanel()
                } else {
                    ForEach(results) { book in
                        BookRowView(
                            book: book,
                            isCurrent: playback.currentSession?.book.id == book.book.id
                        ) {
                            Task { await playback.play(book) }
                        }
                    }
                }
            }
        }
    }

    private var results: [BookWithChapters] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return libraryStore.books }
        return libraryStore.books.filter { book in
            book.book.title.localizedCaseInsensitiveContains(trimmed)
                || book.book.authorLine.localizedCaseInsensitiveContains(trimmed)
        }
    }
}

