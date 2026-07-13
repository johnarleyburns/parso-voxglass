import Foundation

/// Observable shelf of user playlist metadata (P1-3). Books are loaded on demand
/// in `PlaylistDetailView`; this store just holds the roster.
@MainActor
final class PlaylistStore: ObservableObject {
    @Published private(set) var playlists: [Playlist] = []
    @Published var error: String?

    private let repository: PlaylistRepository

    init(repository: PlaylistRepository) {
        self.repository = repository
    }

    func refresh() async {
        do {
            playlists = try await repository.fetchAll()
        } catch let e {
            error = e.localizedDescription
        }
    }

    func create(title: String) async -> Playlist? {
        do {
            let p = try await repository.create(title: title)
            await refresh()
            return p
        } catch let e { error = e.localizedDescription }
        return nil
    }

    func rename(_ id: UUID, to title: String) async {
        do {
            try await repository.rename(id, to: title)
            await refresh()
        } catch let e { error = e.localizedDescription }
    }

    func delete(_ id: UUID) async {
        do {
            try await repository.delete(id)
            await refresh()
        } catch let e { error = e.localizedDescription }
    }

    func addBook(_ bookID: UUID, to playlistID: UUID) async {
        do {
            try await repository.addBook(bookID, to: playlistID)
        } catch let e { error = e.localizedDescription }
    }

    func removeBook(_ bookID: UUID, from playlistID: UUID) async {
        do {
            try await repository.removeBook(bookID, from: playlistID)
        } catch let e { error = e.localizedDescription }
    }
}
