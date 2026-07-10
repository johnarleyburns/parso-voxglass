import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @Binding var showingNowPlaying: Bool
    @State private var showingImporter = false

    var body: some View {
        VoxglassScreen(title: "Library") {
            VStack(alignment: .leading, spacing: 18) {
                importPanel
                categoryHub
                allAudiobooksPreview
            }
            .padding(.top, 12)
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: UTType.voxglassImportTypes,
            allowsMultipleSelection: true
        ) { result in
            Task { await handleImportResult(result) }
        }
        .alert("Import Failed", isPresented: importErrorBinding) {
            Button("OK", role: .cancel) {
                libraryStore.importError = nil
            }
        } message: {
            Text(libraryStore.importError ?? "")
        }
        .task {
            await libraryStore.refreshRecentlyPlayed()
        }
    }

    private var importPanel: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 18))
                .foregroundStyle(Palette.brass)
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text("Local Audio")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("MP3, M4A, M4B, and folders")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.ink3)
            }
            Spacer()
            Button {
                showingImporter = true
            } label: {
                if libraryStore.isImporting {
                    ProgressView()
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.brass)
            .accessibilityLabel("Import local audio")
        }
        .padding(14)
        .glassSurface(cornerRadius: 14)
    }

    private var categoryHub: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Library")
            VStack(spacing: 0) {
                ForEach(LibraryCategory.allCases) { category in
                    NavigationLink {
                        LibraryCategoryDetailView(
                            category: category,
                            showingNowPlaying: $showingNowPlaying
                        )
                    } label: {
                        DisclosureListRow(
                            icon: category.icon,
                            title: category.title,
                            detail: category.detail,
                            count: count(for: category),
                            isEnabled: true
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .glassSurface(cornerRadius: 14)
        }
    }

    @ViewBuilder
    private var allAudiobooksPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "All Audiobooks")

            if libraryStore.books.isEmpty {
                EmptyStatePanel(
                    title: "No Audiobooks",
                    message: "Import files or add an Internet Archive URL to build your library.",
                    systemImage: "books.vertical"
                )
            } else {
                ForEach(libraryStore.books.prefix(6)) { book in
                    NavigationLink {
                        BookDetailView(book: book, showingNowPlaying: $showingNowPlaying)
                    } label: {
                        CompactBookRowView(
                            book: book,
                            sourceTitle: libraryStore.source(for: book.book)?.title
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var importErrorBinding: Binding<Bool> {
        Binding {
            libraryStore.importError != nil
        } set: { isPresented in
            if !isPresented {
                libraryStore.importError = nil
            }
        }
    }

    private func count(for category: LibraryCategory) -> Int {
        switch category {
        case .allAudiobooks:
            return libraryStore.books.count
        case .downloaded:
            return 0
        case .favorites:
            return libraryStore.favoriteBooks.count
        case .authors:
            return libraryStore.authorNames.count
        case .genres:
            return 0
        case .recentlyPlayed:
            return libraryStore.recentlyPlayed.count
        case .playlists:
            return 0
        }
    }

    private func handleImportResult(_ result: Result<[URL], Error>) async {
        switch result {
        case .success(let urls):
            let imported = await libraryStore.importLocalAudio(from: urls)
            if let first = imported.first {
                await playback.play(first)
                showingNowPlaying = true
            }
        case .failure(let error):
            libraryStore.importError = error.localizedDescription
        }
    }
}

struct LibraryCategoryDetailView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    var category: LibraryCategory
    @Binding var showingNowPlaying: Bool

    var body: some View {
        ZStack {
            VoxglassBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if category == .recentlyPlayed {
                await libraryStore.refreshRecentlyPlayed()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch category {
        case .allAudiobooks:
            bookList(libraryStore.books, emptyTitle: "No Audiobooks", emptyMessage: "Your imported books will appear here.")
        case .downloaded:
            EmptyStatePanel(
                title: "No Downloads",
                message: "Offline download controls are visible in book detail, but the download manager is a later phase.",
                systemImage: "arrow.down.circle"
            )
        case .favorites:
            bookList(libraryStore.favoriteBooks, emptyTitle: "No Favorites", emptyMessage: "Tap Favorite on a book detail screen to keep it here.")
        case .authors:
            authorList
        case .genres:
            genreList
        case .recentlyPlayed:
            bookList(libraryStore.recentlyPlayed, emptyTitle: "No Recent Plays", emptyMessage: "Started audiobooks will appear here after playback is saved.")
        case .playlists:
            EmptyStatePanel(
                title: "No Playlists",
                message: "Playlist editing is reserved for a later phase.",
                systemImage: "text.badge.plus"
            )
        }
    }

    private func bookList(
        _ books: [BookWithChapters],
        emptyTitle: String,
        emptyMessage: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if books.isEmpty {
                EmptyStatePanel(title: emptyTitle, message: emptyMessage, systemImage: category.icon)
            } else {
                ForEach(books) { book in
                    NavigationLink {
                        BookDetailView(book: book, showingNowPlaying: $showingNowPlaying)
                    } label: {
                        CompactBookRowView(
                            book: book,
                            sourceTitle: libraryStore.source(for: book.book)?.title
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var authorList: some View {
        if libraryStore.authorNames.isEmpty {
            EmptyStatePanel(
                title: "No Authors",
                message: "Authors are indexed from local book metadata.",
                systemImage: "person.2"
            )
        } else {
            VStack(spacing: 0) {
                ForEach(libraryStore.authorNames, id: \.self) { author in
                    NavigationLink {
                        AuthorDetailView(authorName: author, showingNowPlaying: $showingNowPlaying)
                    } label: {
                        DisclosureListRow(
                            icon: "person.fill",
                            title: author,
                            detail: "Local works",
                            count: libraryStore.books(byAuthor: author).count
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .glassSurface(cornerRadius: 14)
        }
    }

    private var genreList: some View {
        VStack(alignment: .leading, spacing: 12) {
            EmptyStatePanel(
                title: "No Subject Index",
                message: "Subject counts need richer catalog metadata and remain a later phase.",
                systemImage: "tag"
            )
        }
    }
}

enum LibraryCategory: String, CaseIterable, Identifiable {
    case allAudiobooks
    case downloaded
    case favorites
    case authors
    case genres
    case recentlyPlayed
    case playlists

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allAudiobooks:
            return "All Audiobooks"
        case .downloaded:
            return "Downloaded"
        case .favorites:
            return "Favorites"
        case .authors:
            return "Authors"
        case .genres:
            return "Genres & Subjects"
        case .recentlyPlayed:
            return "Recently Played"
        case .playlists:
            return "My Playlists"
        }
    }

    var detail: String {
        switch self {
        case .allAudiobooks:
            return "Everything on this device"
        case .downloaded:
            return "Offline items"
        case .favorites:
            return "Saved titles"
        case .authors:
            return "Local author index"
        case .genres:
            return "Subject collections"
        case .recentlyPlayed:
            return "Playback history"
        case .playlists:
            return "Custom lists"
        }
    }

    var icon: String {
        switch self {
        case .allAudiobooks:
            return "books.vertical.fill"
        case .downloaded:
            return "arrow.down.circle.fill"
        case .favorites:
            return "heart.fill"
        case .authors:
            return "person.2.fill"
        case .genres:
            return "tag.fill"
        case .recentlyPlayed:
            return "clock.arrow.circlepath"
        case .playlists:
            return "music.note.list"
        }
    }
}
