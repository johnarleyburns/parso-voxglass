import SwiftUI

/// Lists bookmarks for the current book, grouped by chapter. Tap to jump,
/// swipe to delete, tap note to edit.
struct BookmarksView: View {
    @EnvironmentObject private var playback: PlaybackCoordinator
    @EnvironmentObject private var libraryStore: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var bookmarks: [Bookmark] = []
    @State private var showingDeleteConfirm: Bookmark?
    @State private var editingNote: Bookmark?
    @State private var editText = ""

    private var chaptersByID: [UUID: Chapter] {
        guard let session = playback.currentSession else { return [:] }
        return Dictionary(uniqueKeysWithValues: session.chapters.map { ($0.id, $0) })
    }

    var body: some View {
        ZStack {
            VoxglassTheme.warmBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                // Grabber
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 36, height: 5)
                    .padding(.top, 6)

                if bookmarks.isEmpty {
                    Spacer()
                    ContentUnavailableView("No Bookmarks", systemImage: "bookmark.slash")
                        .foregroundStyle(.white)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(bookmarks, id: \.id) { bookmark in
                                bookmarkRowView(bookmark)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                        .padding(.bottom, 20)
                    }
                }
            }
        }
        .navigationTitle("Bookmarks")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .confirmationDialog(
            "Delete this bookmark?",
            isPresented: .init(
                get: { showingDeleteConfirm != nil },
                set: { if !$0 { showingDeleteConfirm = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let bm = showingDeleteConfirm, let id = bm.id {
                    Task {
                        try? await playback.bookmarkStore?.delete(id: id)
                        await load()
                    }
                }
                showingDeleteConfirm = nil
            }
        }
        .alert("Edit Note", isPresented: .init(
            get: { editingNote != nil },
            set: { if !$0 { editingNote = nil } }
        )) {
            TextField("Note", text: $editText)
            Button("Save") {
                if let bm = editingNote, let id = bm.id {
                    Task {
                        _ = try? await playback.bookmarkStore?.updateNote(editText, id: id)
                        await load()
                    }
                }
                editingNote = nil
            }
            Button("Cancel", role: .cancel) { editingNote = nil }
        }
    }

    @ViewBuilder
    private func bookmarkRowView(_ bookmark: Bookmark) -> some View {
        let chapter = chaptersByID[bookmark.chapterID]
        Button {
            Task { await playback.jump(to: bookmark); dismiss() }
        } label: {
            bookmarkRow(bookmark, chapter: chapter)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                showingDeleteConfirm = bookmark
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button("Jump") { Task { await playback.jump(to: bookmark); dismiss() } }
            Button("Edit Note") {
                editingNote = bookmark
                editText = bookmark.note ?? ""
            }
            Button("Delete", role: .destructive) { showingDeleteConfirm = bookmark }
        }
    }

    private func bookmarkRow(_ bookmark: Bookmark, chapter: Chapter?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(chapter?.title ?? "Chapter")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(TimeFormatting.clock(bookmark.position))
                    .scaledFont(size: 11.5, design: .monospaced)
                    .foregroundStyle(Palette.ink3)
                if let note = bookmark.note, !note.isEmpty {
                    Text(note)
                        .scaledFont(size: 11)
                        .foregroundStyle(Palette.ink2)
                        .lineLimit(2)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(Palette.ink3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .glassSurface(cornerRadius: 12, fill: Color.white.opacity(0.06))
    }

    private func load() async {
        guard let session = playback.currentSession else { return }
        let all = (try? await playback.bookmarkStore?.bookmarks(forBookID: session.book.id)) ?? []
        bookmarks = all
    }
}
