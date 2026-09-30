import SwiftUI
import VoxglassCore

/// Navigates immediately, while archive metadata and chapters load in the
/// destination instead of blocking the Discover row tap.
struct CatalogBookDestinationView: View {
    let result: InternetArchiveSearchResult
    @Binding var showingNowPlaying: Bool
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var catalogStore: CatalogStore
    @State private var importedBook: BookWithChapters?
    @State private var failed = false

    var body: some View {
        Group {
            if let importedBook {
                BookPageView(book: importedBook, showingNowPlaying: $showingNowPlaying)
            } else if failed {
                ContentUnavailableView("Couldn't Load Book", systemImage: "exclamationmark.triangle")
            } else {
                ProgressView("Loading \(result.title)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: result.identifier) {
            let existingBookIDs = Set(libraryStore.books.map(\.book.id))
            guard let imported = await catalogStore.importResult(result, into: libraryStore) else {
                failed = true
                return
            }
            if !existingBookIDs.contains(imported.book.id) {
                await libraryStore.markBookPending(imported.book.id)
            }
            importedBook = libraryStore.book(withID: imported.book.id) ?? imported
        }
        .navigationTitle("")
    }
}
