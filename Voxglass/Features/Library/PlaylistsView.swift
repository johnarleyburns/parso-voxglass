import SwiftUI
import VoxglassCore

/// Lists the user's playlists; enter from the "Library" section in Settings.
struct PlaylistsView: View {
    @EnvironmentObject private var playlistStore: PlaylistStore
    let repository: PlaylistRepository
    @State private var showCreate = false
    @State private var newTitle = ""

    var body: some View {
        ZStack {
            VoxglassBackground()
            if playlistStore.playlists.isEmpty {
                ContentUnavailableView("No Playlists", systemImage: "music.note.list")
                    .foregroundStyle(.white)
            } else {
                List {
                    ForEach(playlistStore.playlists) { playlist in
                        NavigationLink {
                            PlaylistDetailView(playlist: playlist, repository: repository)
                        } label: {
                            Label(playlist.title, systemImage: "text.badge.plus")
                                .foregroundStyle(Palette.ink)
                        }
                    }
                    .onDelete { idxs in
                        for i in idxs {
                            Task { await playlistStore.delete(playlistStore.playlists[i].id) }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Playlists")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showCreate = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("New Playlist", isPresented: $showCreate) {
            TextField("Title", text: $newTitle)
            Button("Create") {
                Task { _ = await playlistStore.create(title: newTitle); newTitle = "" }
            }
            Button("Cancel", role: .cancel) { newTitle = "" }
        }
        .task { await playlistStore.refresh() }
    }
}

struct PlaylistDetailView: View {
    @EnvironmentObject private var playlistStore: PlaylistStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @EnvironmentObject private var libraryStore: LibraryStore
    let playlist: Playlist
    let repository: PlaylistRepository

    @State private var books: [BookWithChapters] = []
    @State private var showRemoveConfirm: BookWithChapters?

    init(playlist: Playlist, repository: PlaylistRepository) {
        self.playlist = playlist
        self.repository = repository
    }

    var body: some View {
        ZStack {
            VoxglassBackground()
            if books.isEmpty {
                ContentUnavailableView("No Books Yet", systemImage: "text.badge.plus")
                    .foregroundStyle(.white)
            } else {
                List {
                    ForEach(books) { book in
                        Button {
                            Task { await playback.play(book) }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(book.book.title).foregroundStyle(Palette.ink)
                                Text(book.book.authorLine).font(.caption).foregroundStyle(Palette.ink3)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                showRemoveConfirm = book
                            } label: {
                                Label("Remove", systemImage: "minus.circle")
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle(playlist.title)
        .confirmationDialog(
            showRemoveConfirm.map { "Remove \"\($0.book.title)\" from playlist?" } ?? "",
            isPresented: .init(
                get: { showRemoveConfirm != nil },
                set: { if !$0 { showRemoveConfirm = nil } }
            )
        ) {
            Button("Remove", role: .destructive) {
                if let b = showRemoveConfirm {
                    Task { await playlistStore.removeBook(b.book.id, from: playlist.id) }
                    books.removeAll { $0.book.id == b.book.id }
                }
                showRemoveConfirm = nil
            }
        }
        .task { await load() }
    }

    private func load() async {
        books = (try? await repository.fetchBooks(for: playlist.id)) ?? []
    }
}
