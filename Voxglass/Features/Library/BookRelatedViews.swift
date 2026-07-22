import SwiftUI
import VoxglassCore

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
                        .foregroundStyle(Palette.ink)
                        .lineLimit(2)

                    VoxglassGroupedSection(title: "All Chapters") {
                        let chapters = currentBook.chapters
                        ForEach(chapters.indices, id: \.self) { index in
                            let chapter = chapters[index]
                            ChapterRow(chapter: chapter, bookNarrators: currentBook.book.narrators, isCurrent: playback.currentSession?.chapter.id == chapter.id) {
                                Task {
                                    await playback.play(currentBook, chapter: chapter)
                                    showingNowPlaying = true
                                }
                            }
                            if index < chapters.count - 1 {
                                VoxglassListDivider()
                            }
                        }
                    }
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
                                    BookPageView(book: book, showingNowPlaying: $showingNowPlaying)
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

struct NarratorDetailView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    var narratorName: String
    @Binding var showingNowPlaying: Bool

    private var books: [BookWithChapters] {
        libraryStore.books(byNarrator: narratorName)
    }

    var body: some View {
        ZStack {
            VoxglassBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(narratorName)
                            .scaledFont(size: 31, weight: .heavy)
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
                                message: "Works narrated by this reader will appear here after import.",
                                systemImage: "mic"
                            )
                        } else {
                            ForEach(books) { book in
                                NavigationLink {
                                    BookPageView(book: book, showingNowPlaying: $showingNowPlaying)
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
        .navigationTitle("Narrator")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ChapterRow: View {
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(chapter.title)
        .accessibilityValue(isCurrent ? "Now playing" : TimeFormatting.clock(chapter.duration))
        .accessibilityHint("Plays this chapter")
    }
}

struct AddToPlaylistSheet: View {
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
