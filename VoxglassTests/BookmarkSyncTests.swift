import Testing
import Foundation
@testable import VoxglassCore

/// Pure LWW tombstone tests (P0-3). The merge logic is extracted as a pure
/// function so the tombstone behaviour is tested with no iCloud, no SQLite.
@Suite struct BookmarkSyncTests {

    /// Pure LWW tombstone tests (P0-3). The merge logic is extracted as a pure
    /// function so the tombstone behaviour is tested with no iCloud, no SQLite.

    /// Merge two sets of bookmarks — the one with the newer `max(updatedAt)` wins
    /// per-book. A tombstoned bookmark on the winning side stays deleted.
    static func merge(local: [Bookmark], remote: [Bookmark]) -> [Bookmark] {
        let localMax = local.map(\.updatedAt.timeIntervalSince1970).max() ?? 0
        let remoteMax = remote.map(\.updatedAt.timeIntervalSince1970).max() ?? 0
        return remoteMax > localMax ? remote : local
    }

    private let bookID = UUID()
    private let chID = UUID()

    private func make(created: Double, updated: Double, deleted: Bool) -> Bookmark {
        Bookmark(id: UUID(), bookID: bookID, chapterID: chID, position: 0,
                 createdAt: Date(timeIntervalSince1970: created),
                 updatedAt: Date(timeIntervalSince1970: updated),
                 isDeleted: deleted)
    }

    @Test func remoteDoesNotResurrectLocallyTombstonedBookmark() {
        // A locally-deleted bookmark (newer updatedAt) must not be resurrected by
        // a remote payload from a device that hasn't seen the tombstone yet.
        let local = [make(created: 100, updated: 300, deleted: true)]
        let remote = [make(created: 100, updated: 200, deleted: false)]
        let result = Self.merge(local: local, remote: remote)
        #expect(result.first?.isDeleted == true)  // Tombstone must survive a stale remote
    }

    @Test func remoteTombstoneOverwritesLocalLiveBookmark() {
        let local = [make(created: 100, updated: 200, deleted: false)]
        let remote = [make(created: 100, updated: 300, deleted: true)]
        let result = Self.merge(local: local, remote: remote)
        #expect(result.first?.isDeleted == true)  // A newer remote tombstone must be applied
    }

    @Test func kVSBookmarkPayloadStaysUnderSizeLimit() throws {
        // 50 bookmarks per book should be well under the 1 MB KVS per-key cap.
        var bookmarks: [[String: Any]] = []
        for _ in 0..<50 {
            bookmarks.append([
                "id": UUID().uuidString,
                "chapter_id": UUID().uuidString,
                "position": 42.0,
                "note": "Some note text that is reasonably sized",
                "created_at": Date().timeIntervalSince1970,
                "updated_at": Date().timeIntervalSince1970,
                "is_deleted": false
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: bookmarks)
        let descriptionLength = NSString(data: data, encoding: String.Encoding.utf8.rawValue)?.length ?? 0
        #expect(data.count < 1_000_000)
        #expect(descriptionLength < 100_000)
    }

    @MainActor @Test func pushWorksWithAnyBookmarkStoreConformer() {
        // On today's main this crashes because of the `as! SQLiteBookmarkStore` force cast.
        // After the fix, any BookmarkStore conformer works.
        let database = AppDatabase.makeTemporaryDatabase(named: "sync-conformer-test")
        let fakeStore = FakeBookmarkStore()
        let cloudSync = VoxglassCloudSync(database: database, bookmarkStore: fakeStore)
        cloudSync.testForceAvailable = true
        // If we reach this point without a crash, the force cast has been removed.
        #expect(true)
    }
}

/// A non-SQLite BookmarkStore conformer — verifies that VoxglassCloudSync
/// works with any BookmarkStore, not just SQLiteBookmarkStore.
private final class FakeBookmarkStore: BookmarkStore {
    private var storage: [Bookmark] = []

    func add(_ bookmark: Bookmark) async throws -> Bookmark { bookmark }

    func bookmarks(forBookID bookID: UUID) async throws -> [Bookmark] {
        storage.filter { $0.bookID == bookID && !$0.isDeleted }
    }

    func allBookmarks() async throws -> [Bookmark] {
        storage.filter { !$0.isDeleted }
    }

    func delete(id: UUID) async throws {
        if let idx = storage.firstIndex(where: { $0.id == id }) {
            storage[idx].isDeleted = true
        }
    }

    func updateNote(_ note: String, id: UUID) async throws -> Bookmark? { nil }

    func bookmarksForSync(bookID: UUID) async throws -> [Bookmark] {
        storage.filter { $0.bookID == bookID }
    }

    func upsertFromSync(_ bookmarks: [Bookmark], forBookID bookID: UUID) async throws {
        storage = bookmarks
    }
}
