import SwiftUI
import VoxglassCore

/// Navigates immediately, while archive metadata and chapters load in the
/// destination instead of blocking the Discover row tap.
struct CatalogBookDestinationView: View {
    let result: InternetArchiveSearchResult
    @Binding var showingNowPlaying: Bool
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var catalogStore: CatalogStore
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.dismiss) private var dismiss
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
            // Shared resolver keeps an existing Book.id (and its bookmarks and
            // progress) and only marks genuinely new imports pending.
            guard let resolved = await catalogStore.resolveForNavigation(result, into: libraryStore) else {
                failed = true
                return
            }
            if CatalogResultImporter.opensNowPlayingDirectly(resolved) {
                // Already in My Books: skip the preview page, go to Now Playing.
                playback.selectAndPlay(resolved)
                showingNowPlaying = true
                dismiss()
                return
            }
            importedBook = resolved
        }
        .navigationTitle("")
    }
}
