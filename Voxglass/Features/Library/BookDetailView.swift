import SwiftUI

struct BookDetailView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @EnvironmentObject private var offlineManager: OfflineDownloadManager
    @Environment(\.dismiss) private var dismiss
    var book: BookWithChapters
    @Binding var showingNowPlaying: Bool
    @AppStorage(RecentlyViewedBooksStore.key) private var recentlyViewedRaw = ""
    @State private var showPaywall = false
    @State private var showCellularPrompt = false
    @State private var showRemoveConfirm = false
    @State private var showRemoveOfflineConfirm = false
    @State private var showingBookmarks = false
    @State private var showingPlaylistPicker = false
    @State private var bookmarkCount: Int?

    private var currentBook: BookWithChapters {
        libraryStore.book(withID: book.book.id) ?? book
    }

    private var offlineState: OfflineState {
        offlineManager.state(for: book.book.id)
    }

    var body: some View {
        ZStack {
            VoxglassBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    detailHeader
                    actionGrid
                    summarySection
                    tagSection
                    narratorSection
                    chapterPreview
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("Book")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Remove from My Books", role: .destructive) {
                        showRemoveConfirm = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear {
            recentlyViewedRaw = RecentlyViewedBooksStore.recording(
                bookID: currentBook.book.id,
                in: recentlyViewedRaw
            )
        }
        .sheet(isPresented: $showPaywall) {
            NavigationStack {
                ProPaywallView()
            }
        }
        .sheet(isPresented: $showingBookmarks) {
            NavigationStack {
                BookmarksView()
                    .environmentObject(playback)
                    .environmentObject(libraryStore)
            }
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingPlaylistPicker) {
            NavigationStack {
                AddToPlaylistSheet(bookID: currentBook.book.id)
            }
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "You're on cellular data",
            isPresented: $showCellularPrompt,
            titleVisibility: .visible
        ) {
            Button("Cache now on cellular") {
                UserDefaults.standard.set(true, forKey: AppPreferencesStore.Keys.cacheFullBooksOnCellular)
                Task { await startOffline(allowCellular: true) }
            }
            Button("Wait for Wi-Fi", role: .cancel) {}
        } message: {
            Text("Caching a whole book can use significant cellular data.")
        }
        .confirmationDialog(
            "Remove \"\(currentBook.book.title)\" from My Books?",
            isPresented: $showRemoveConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove from My Books", role: .destructive) {
                Task {
                    await libraryStore.delete(book: currentBook)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the book and its cached audio from this device.")
        }
        .confirmationDialog(
            "Remove the offline copy?",
            isPresented: $showRemoveOfflineConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove offline copy", role: .destructive) {
                Task { await offlineManager.removeOffline(book: currentBook) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The book stays in My Books; only the downloaded audio is freed.")
        }
    }

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                ZStack(alignment: .bottomLeading) {
                    BookArtworkView(title: currentBook.book.title, size: 112, coverURL: currentBook.book.coverURL)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 18, y: 12)

                    if let source = libraryStore.source(for: currentBook.book) {
                        ProvenanceChip(sourceKind: source.kind)
                            .padding(6)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(currentBook.book.title)
                        .scaledFont(size: 20, weight: .heavy)
                        .kerning(-0.5)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(4)
                        .minimumScaleFactor(0.72)

                    authorLinks

                    Text(currentBook.libraryDetailLine(sourceTitle: libraryStore.source(for: currentBook.book)?.kind.displayName))
                        .scaledFont(size: 11.5)
                        .foregroundStyle(Palette.ink3)
                        .lineLimit(2)
                }
            }

            PrimaryActionButton(title: "Play", systemImage: "play.fill") {
                Task {
                    await playback.play(currentBook)
                    showingNowPlaying = true
                }
            }
        }
        .padding(16)
        .glassSurface(cornerRadius: 18)
    }

    private var authorLinks: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(currentBook.book.authors.isEmpty ? ["Unknown author"] : currentBook.book.authors, id: \.self) { author in
                if author == "Unknown author" {
                    Text(author)
                        .scaledFont(size: 14)
                        .foregroundStyle(Palette.ink2)
                } else {
                    NavigationLink {
                        AuthorDetailView(authorName: author, showingNowPlaying: $showingNowPlaying)
                    } label: {
                        Label(author, systemImage: "person.fill")
                            .scaledFont(size: 14, weight: .semibold)
                            .foregroundStyle(Palette.brass)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var actionGrid: some View {
        let isFavorite = currentBook.book.isFavorite

        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            SecondaryActionButton(
                title: isFavorite ? "Favorited" : "Favorite",
                systemImage: isFavorite ? "heart.fill" : "heart"
            ) {
                Task {
                    await libraryStore.setFavorite(!isFavorite, for: currentBook.book.id)
                }
            }

            offlineControl
            SecondaryActionButton(title: "Playlist", systemImage: "text.badge.plus") {
                showingPlaylistPicker = true
            }

            ShareLink(item: shareText) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .scaledFont(size: 14, weight: .semibold)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .foregroundStyle(Palette.ink)
                    .glassSurface(cornerRadius: 18)
            }
        }
    }

    @ViewBuilder
    private var offlineControl: some View {
        switch offlineState {
        case .notCached:
            SecondaryActionButton(title: "Make available offline", systemImage: "arrow.down.circle") {
                Task { await requestOffline() }
            }
        case .downloading(let progress):
            VStack(spacing: 4) {
                ProgressView(value: progress)
                    .tint(Palette.brass)
                Text("Caching… \(Int((progress * 100).rounded()))%")
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(Palette.ink2)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .padding(.horizontal, 12)
            .glassSurface(cornerRadius: 18)
        case .cached:
            Label("Cached for offline use", systemImage: "checkmark.circle.fill")
                .scaledFont(size: 13, weight: .semibold)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .foregroundStyle(Palette.brass)
                .glassSurface(cornerRadius: 18)
                .contextMenu {
                    Button("Remove offline copy", role: .destructive) {
                        showRemoveOfflineConfirm = true
                    }
                }
        case .failed:
            SecondaryActionButton(title: "Retry offline", systemImage: "exclamationmark.arrow.circlepath") {
                Task { await requestOffline() }
            }
        }
    }

    private func requestOffline() async {
        await startOffline(allowCellular: false)
    }

    private func startOffline(allowCellular: Bool) async {
        let decision = await offlineManager.makeAvailableOffline(
            book: currentBook,
            isCellular: NetworkMonitor.shared.isCellular,
            allowCellularOverride: allowCellular
        )
        switch decision {
        case .needsPro:
            showPaywall = true
        case .needsCellularConfirmation:
            showCellularPrompt = true
        case .start:
            break
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Summary")
            Text(currentBook.book.summary?.isEmpty == false ? currentBook.book.summary! : "No summary is available for this audiobook yet.")
                .scaledFont(size: 14)
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .glassSurface(cornerRadius: 14)
        }
    }

    private var tagSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Tags")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                            .scaledFont(size: 11, weight: .semibold)
                            .foregroundStyle(Palette.ink)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .glassSurface(cornerRadius: 15)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private var narratorSection: some View {
        if let narratorLine = currentBook.book.narratorLine {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Narrators")
                DisclosureListRow(
                    icon: "mic.fill",
                    title: narratorLine,
                    detail: "\(currentBook.chapters.count) chapter\(currentBook.chapters.count == 1 ? "" : "s")",
                    count: nil
                )
                .glassSurface(cornerRadius: 14)
            }
        }
    }

    private var chapterPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Chapters")

            VStack(spacing: 0) {
                ForEach(currentBook.chapters.prefix(6)) { chapter in
                    ChapterRow(chapter: chapter, bookNarrators: currentBook.book.narrators, isCurrent: playback.currentSession?.chapter.id == chapter.id) {
                        Task {
                            await playback.play(currentBook, chapter: chapter)
                            showingNowPlaying = true
                        }
                    }
                }

                Group {
                    if let count = playback.bookmarkCount ?? bookmarkCount, count > 0 {
                        Button {
                            showingBookmarks = true
                        } label: {
                            DisclosureListRow(
                                icon: "bookmark.fill",
                                title: "Bookmarks",
                                detail: "\(count) bookmark\(count == 1 ? "" : "s")",
                                count: nil
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    NavigationLink {
                        ChaptersView(book: currentBook, showingNowPlaying: $showingNowPlaying)
                    } label: {
                        DisclosureListRow(
                            icon: "list.bullet",
                            title: "All Chapters",
                            detail: "\(currentBook.chapters.count) total",
                            count: nil
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .glassSurface(cornerRadius: 14)
        }
    }

    private var tags: [String] {
        var values = ["Public Domain", "\(currentBook.chapters.count) Chapters"]
        if let source = libraryStore.source(for: currentBook.book) {
            values.append(source.kind.displayName)
        }
        if currentBook.book.isFavorite {
            values.append("Favorite")
        }
        return values
    }

    private var shareText: String {
        "\(currentBook.book.title) by \(currentBook.book.authorLine)"
    }
}

struct ChaptersView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    var book: BookWithChapters
    @Binding var showingNowPlaying: Bool

    private var currentBook: BookWithChapters {
        libraryStore.book(withID: book.book.id) ?? book
    }

    var body: some View {
        ZStack {
            VoxglassBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(currentBook.book.title)
                        .scaledFont(size: 20, weight: .heavy)
                        .kerning(-0.5)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(2)

                    VStack(spacing: 0) {
                        ForEach(currentBook.chapters) { chapter in
                            ChapterRow(chapter: chapter, bookNarrators: currentBook.book.narrators, isCurrent: playback.currentSession?.chapter.id == chapter.id) {
                                Task {
                                    await playback.play(currentBook, chapter: chapter)
                                    showingNowPlaying = true
                                }
                            }
                        }
                    }
                    .glassSurface(cornerRadius: 14)
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("Chapters")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AuthorDetailView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    var authorName: String
    @Binding var showingNowPlaying: Bool

    private var books: [BookWithChapters] {
        libraryStore.books(byAuthor: authorName)
    }

    var body: some View {
        ZStack {
            VoxglassBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(authorName)
                            .scaledFont(size: 31, weight: .heavy)
                            .kerning(-0.5)
                            .foregroundStyle(Palette.ink)
                            .lineLimit(3)
                            .minimumScaleFactor(0.72)
                        Text("\(books.count) local work\(books.count == 1 ? "" : "s")")
                            .scaledFont(size: 14)
                            .foregroundStyle(Palette.ink2)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(title: "Local Works")
                        if books.isEmpty {
                            EmptyStatePanel(
                                title: "No Local Works",
                                message: "Works by this author will appear here after import.",
                                systemImage: "person.text.rectangle"
                            )
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
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("Author")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ChapterRow: View {
    var chapter: Chapter
    var bookNarrators: [String]
    var isCurrent: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isCurrent ? "waveform.circle.fill" : "play.circle")
                    .scaledFont(size: 18)
                    .foregroundStyle(isCurrent ? Palette.brass : Palette.ink3)
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text(chapter.title)
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(TimeFormatting.clock(chapter.duration))
                            .scaledFont(size: 11.5, design: .monospaced)
                            .foregroundStyle(Palette.ink3)
                        if let narrator = NarratorDisplay.chapterLine(chapter: chapter, bookNarrators: bookNarrators) {
                            Text("·")
                                .foregroundStyle(Palette.ink3)
                            Text(narrator)
                                .scaledFont(size: 11.5)
                                .foregroundStyle(Palette.ink3)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 10)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
    }
}

private struct AddToPlaylistSheet: View {
    @EnvironmentObject private var playlistStore: PlaylistStore
    @Environment(\.dismiss) private var dismiss
    let bookID: UUID
    @State private var newTitle = ""

    var body: some View {
        ZStack {
            VoxglassBackground()
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 36, height: 5)
                    .padding(.top, 6)
                List {
                    Section("Create New") {
                        TextField("Playlist name", text: $newTitle)
                        Button("Create & Add") {
                            Task {
                                if let p = await playlistStore.create(title: newTitle) {
                                    await playlistStore.addBook(bookID, to: p.id)
                                }
                                newTitle = ""
                                dismiss()
                            }
                        }
                        .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Section("Add to Existing") {
                        if playlistStore.playlists.isEmpty {
                            Text("No playlists yet")
                                .foregroundStyle(Palette.ink3)
                        }
                        ForEach(playlistStore.playlists) { playlist in
                            Button {
                                Task {
                                    await playlistStore.addBook(bookID, to: playlist.id)
                                    dismiss()
                                }
                            } label: {
                                Label(playlist.title, systemImage: "text.badge.plus")
                                    .foregroundStyle(Palette.ink)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Add to Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .task { await playlistStore.refresh() }
    }
}
