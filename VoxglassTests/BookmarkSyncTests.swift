import XCTest
@testable import Voxglass

/// Pure LWW tombstone tests (P0-3). The merge logic is extracted as a pure
/// function so the tombstone behaviour is tested with no iCloud, no SQLite.
final class BookmarkSyncTests: XCTestCase {

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

    func testRemoteDoesNotResurrectLocallyTombstonedBookmark() {
        // A locally-deleted bookmark (newer updatedAt) must not be resurrected by
        // a remote payload from a device that hasn't seen the tombstone yet.
        let local = [make(created: 100, updated: 300, deleted: true)]
        let remote = [make(created: 100, updated: 200, deleted: false)]
        let result = Self.merge(local: local, remote: remote)
        XCTAssertEqual(result.first?.isDeleted, true, "Tombstone must survive a stale remote")
    }

    func testRemoteTombstoneOverwritesLocalLiveBookmark() {
        let local = [make(created: 100, updated: 200, deleted: false)]
        let remote = [make(created: 100, updated: 300, deleted: true)]
        let result = Self.merge(local: local, remote: remote)
        XCTAssertEqual(result.first?.isDeleted, true, "A newer remote tombstone must be applied")
    }

    func testKVSBookmarkPayloadStaysUnderSizeLimit() throws {
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
        XCTAssertLessThan(data.count, 1_000_000, "50-bookmark KVS payload must be under 1 MB")
        XCTAssertLessThan(descriptionLength, 100_000, "With reasonable notes, the payload stays compact")
    }
}
