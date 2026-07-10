import SwiftUI

struct BookDetailView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    var book: BookWithChapters
    @Binding var showingNowPlaying: Bool
    @AppStorage(RecentlyViewedBooksStore.key) private var recentlyViewedRaw = ""

    private var currentBook: BookWithChapters {
        libraryStore.book(withID: book.book.id) ?? book
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
                    chapterPreview
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("Book")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            recentlyViewedRaw = RecentlyViewedBooksStore.recording(
                bookID: currentBook.book.id,
                in: recentlyViewedRaw
            )
        }
    }

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                BookArtworkView(title: currentBook.book.title, size: 112, coverURL: currentBook.book.coverURL)
                    .shadow(color: .black.opacity(0.22), radius: 18, y: 12)

                VStack(alignment: .leading, spacing: 8) {
                    Text(currentBook.book.title)
                        .font(.system(.title2, design: .serif, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(4)
                        .minimumScaleFactor(0.72)

                    authorLinks

                    Text(currentBook.libraryDetailLine(sourceTitle: libraryStore.source(for: currentBook.book)?.kind.displayName))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.66))
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
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(VoxglassTheme.deepGlass)
        }
    }

    private var authorLinks: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(currentBook.book.authors.isEmpty ? ["Unknown author"] : currentBook.book.authors, id: \.self) { author in
                if author == "Unknown author" {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.72))
                } else {
                    NavigationLink {
                        AuthorDetailView(authorName: author, showingNowPlaying: $showingNowPlaying)
                    } label: {
                        Label(author, systemImage: "person.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(VoxglassTheme.accent)
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

            SecondaryActionButton(title: "Download", systemImage: "arrow.down.circle", isEnabled: false) {}
            SecondaryActionButton(title: "Playlist", systemImage: "text.badge.plus", isEnabled: false) {}

            ShareLink(item: shareText) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .foregroundStyle(VoxglassTheme.ink)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(VoxglassTheme.paperRaised)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(VoxglassTheme.softLine, lineWidth: 1)
                    }
            }
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Summary")
            Text(currentBook.book.summary?.isEmpty == false ? currentBook.book.summary! : "No summary is available for this audiobook yet.")
                .font(.subheadline)
                .foregroundStyle(VoxglassTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .glassPanel()
        }
    }

    private var tagSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Tags")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(VoxglassTheme.ink)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background {
                                Capsule()
                                    .fill(VoxglassTheme.paperRaised)
                            }
                            .overlay {
                                Capsule()
                                    .stroke(VoxglassTheme.softLine, lineWidth: 1)
                            }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var chapterPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Chapters")

            VStack(spacing: 0) {
                ForEach(currentBook.chapters.prefix(6)) { chapter in
                    ChapterRow(chapter: chapter, isCurrent: playback.currentSession?.chapter.id == chapter.id) {
                        Task {
                            await playback.play(currentBook, chapter: chapter)
                            showingNowPlaying = true
                        }
                    }
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
            .glassPanel()
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
                        .font(.system(.title3, design: .serif, weight: .bold))
                        .foregroundStyle(VoxglassTheme.ink)
                        .lineLimit(2)

                    VStack(spacing: 0) {
                        ForEach(currentBook.chapters) { chapter in
                            ChapterRow(chapter: chapter, isCurrent: playback.currentSession?.chapter.id == chapter.id) {
                                Task {
                                    await playback.play(currentBook, chapter: chapter)
                                    showingNowPlaying = true
                                }
                            }
                        }
                    }
                    .glassPanel()
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
                            .font(.system(.largeTitle, design: .serif, weight: .bold))
                            .foregroundStyle(VoxglassTheme.ink)
                            .lineLimit(3)
                            .minimumScaleFactor(0.72)
                        Text("\(books.count) local work\(books.count == 1 ? "" : "s")")
                            .font(.subheadline)
                            .foregroundStyle(VoxglassTheme.secondaryInk)
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

                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(title: "Author Metadata")
                        DisclosureListRow(
                            icon: "link",
                            title: "External Link",
                            detail: "Bundled metadata is not available yet",
                            count: nil,
                            isEnabled: false
                        )
                        .glassPanel()
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
    var isCurrent: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isCurrent ? "waveform.circle.fill" : "play.circle")
                    .font(.title3)
                    .foregroundStyle(isCurrent ? VoxglassTheme.accent : VoxglassTheme.secondaryInk)
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text(chapter.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(VoxglassTheme.ink)
                        .lineLimit(2)
                    Text(TimeFormatting.clock(chapter.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(VoxglassTheme.secondaryInk)
                }

                Spacer(minLength: 10)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
    }
}
