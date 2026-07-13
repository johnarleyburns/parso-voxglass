import Foundation

@MainActor
final class VoxglassCloudSync: ObservableObject {
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncDate: Date?
    @Published var syncError: String?

    private let store = NSUbiquitousKeyValueStore.default
    private let database: AppDatabase
    private var bookmarkStore: (any BookmarkStore)?
    private var observer: NSObjectProtocol?

    private enum Key {
        static let lastSync = "voxglass.cloudsync.lastSync"
        static let positionsPrefix = "voxglass.cloudsync.pos."
        static let bookmarksPrefix = "voxglass.cloudsync.bm."
        static let favoritesPrefix = "voxglass.cloudsync.fav."
        static let versionSuffix = ".v"
    }

    init(database: AppDatabase, bookmarkStore: (any BookmarkStore)? = nil) {
        self.database = database
        self.bookmarkStore = bookmarkStore
        self.lastSyncDate = store.object(forKey: Key.lastSync) as? Date
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                await self?.handleExternalChange(notification)
            }
        }
        store.synchronize()
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var isAvailable: Bool {
        #if DEBUG
        if let testForceAvailable { return testForceAvailable }
        #endif
        return FileManager.default.ubiquityIdentityToken != nil
    }

    #if DEBUG
    /// Test seam: forces iCloud availability without a signed-in account so the
    /// push/pull round-trip can be exercised against the local KVS backing store.
    var testForceAvailable: Bool?
    #endif

    // MARK: - Push (device → iCloud)

    func pushPlaybackPositions() async {
        guard isAvailable, ProFeature.isEnabled(.icloudSync) else { return }
        do {
            try await database.prepare()
            let rows = try await database.query("""
            SELECT id, book_id, chapter_id, position_seconds, duration_seconds, updated_at, is_finished
            FROM playback_positions ORDER BY updated_at DESC LIMIT 100
            """)
            var count = 0
            for row in rows {
                guard let id = row.string("id") else { continue }
                let key = Key.positionsPrefix + id
                let version = Int64(row.double("updated_at") ?? 0)
                let storedVersion = store.longLong(forKey: key + Key.versionSuffix)

                if version > storedVersion {
                    let dict: [String: Any] = [
                        "book_id": row.string("book_id") ?? "",
                        "chapter_id": row.string("chapter_id") ?? "",
                        "position_seconds": row.double("position_seconds") ?? 0,
                        "duration_seconds": row.double("duration_seconds") as Any,
                        "updated_at": row.double("updated_at") ?? 0,
                        "is_finished": row.bool("is_finished") ?? false
                    ]
                    if let data = try? JSONSerialization.data(withJSONObject: dict) {
                        store.set(data, forKey: key)
                        store.set(version, forKey: key + Key.versionSuffix)
                        count += 1
                    }
                }
            }
            if count > 0 {
                store.set(Date(), forKey: Key.lastSync)
                lastSyncDate = Date()
                store.synchronize()
            }
        } catch {
            syncError = error.localizedDescription
        }
    }

    func pushFavorites() async {
        guard isAvailable, ProFeature.isEnabled(.icloudSync) else { return }
        do {
            try await database.prepare()
            let rows = try await database.query("""
            SELECT id, is_favorite, updated_at FROM books WHERE is_favorite = 1
            """)
            for row in rows {
                guard let id = row.string("id") else { continue }
                let key = Key.favoritesPrefix + id
                let version = Int64(row.double("updated_at") ?? 0)
                let storedVersion = store.longLong(forKey: key + Key.versionSuffix)

                if version > storedVersion {
                    store.set(true, forKey: key)
                    store.set(version, forKey: key + Key.versionSuffix)
                    store.synchronize()
                }
            }
        } catch {
            syncError = error.localizedDescription
        }
    }

    // MARK: - Bookmarks (P0-3, PRO iCloudSync gate)

    /// Pushes bookmarks, packed per book (`voxglass.cloudsync.bm.<bookID>`) and
    /// versioned on `MAX(updated_at)` so a single timestamp guards N bookmarks.
    /// Includes tombstones (`is_deleted = 1`) so pulls on other devices apply
    /// the soft-delete rather than resurrecting it.
    func pushBookmarks() async {
        guard isAvailable, ProFeature.isEnabled(.icloudSync), let bmStore = bookmarkStore else { return }
        do {
            try await database.prepare()
            let books = try await database.query("SELECT id FROM books")
            let kvs = self.store
            for bookRow in books {
                guard let bookID = bookRow.string("id") else { continue }
                let all = try await (bmStore as! SQLiteBookmarkStore).bookmarksForSync(bookID: UUID(uuidString: bookID)!)
                guard !all.isEmpty else { continue }
                let maxUpdated = all.map(\.updatedAt.timeIntervalSince1970).max() ?? 0
                let key = Key.bookmarksPrefix + bookID
                let storedVersion = kvs.longLong(forKey: key + Key.versionSuffix)
                if Int64(maxUpdated) <= storedVersion { continue }

                let payload = all.map { b -> [String: Any] in
                    [
                        "id": b.id?.uuidString ?? "",
                        "chapter_id": b.chapterID.uuidString,
                        "position": b.position,
                        "note": b.note ?? "",
                        "created_at": b.createdAt.timeIntervalSince1970,
                        "updated_at": b.updatedAt.timeIntervalSince1970,
                        "is_deleted": b.isDeleted
                    ]
                }
                if let data = try? JSONSerialization.data(withJSONObject: payload) {
                    kvs.set(data, forKey: key)
                    kvs.set(Int64(maxUpdated), forKey: key + Key.versionSuffix)
                    kvs.set(Date(), forKey: Key.lastSync)
                    lastSyncDate = Date()
                    kvs.synchronize()
                }
            }
        } catch {
            syncError = error.localizedDescription
        }
    }

    /// Pulls bookmark updates from iCloud, applying tombstones from the remote
    /// payload so deletions aren't resurrected by another device's push.
    func pullBookmarks() async {
        guard isAvailable, ProFeature.isEnabled(.icloudSync) else { return }
        guard let bmStore = bookmarkStore as? SQLiteBookmarkStore else { return }
        do {
            try await database.prepare()
            let kvs = self.store
            let allKeys = kvs.dictionaryRepresentation.keys.filter {
                $0.hasPrefix(Key.bookmarksPrefix) && !$0.hasSuffix(Key.versionSuffix)
            }
            for key in allKeys {
                let bookIDStr = String(key.dropFirst(Key.bookmarksPrefix.count))
                guard let bookID = UUID(uuidString: bookIDStr) else { continue }
                guard let data = kvs.data(forKey: key),
                      let payload = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
                let maxCloudUpdated = Int64(payload.compactMap { $0["updated_at"] as? Double }.max() ?? 0)
                let localRows = try await database.query(
                    "SELECT MAX(updated_at) AS max_updated FROM bookmarks WHERE book_id = ?",
                    [.string(bookIDStr)]
                )
                let localMax = Int64(localRows.first?.double("max_updated") ?? 0)
                if maxCloudUpdated <= localMax { continue }

                let bookmarks: [Bookmark] = payload.compactMap { dict in
                    guard let id = UUID(uuidString: dict["id"] as? String ?? ""),
                          let chapterID = UUID(uuidString: dict["chapter_id"] as? String ?? "") else { return nil }
                    return Bookmark(
                        id: id, bookID: bookID, chapterID: chapterID,
                        position: dict["position"] as? Double ?? 0,
                        note: dict["note"] as? String,
                        createdAt: Date(timeIntervalSince1970: dict["created_at"] as? Double ?? 0),
                        updatedAt: Date(timeIntervalSince1970: dict["updated_at"] as? Double ?? 0),
                        isDeleted: dict["is_deleted"] as? Bool ?? false
                    )
                }
                try await bmStore.upsertFromSync(bookmarks, forBookID: bookID)
                // Avoid dirty reads on the next push.
                kvs.set(maxCloudUpdated, forKey: key + Key.versionSuffix)
            }
            kvs.synchronize()
        } catch {
            syncError = error.localizedDescription
        }
    }

    // MARK: - Pull (iCloud → device)

    func pullPlaybackPositions() async {
        guard isAvailable, ProFeature.isEnabled(.icloudSync) else { return }
        do {
            try await database.prepare()
            let allKeys = store.dictionaryRepresentation.keys.filter {
                $0.hasPrefix(Key.positionsPrefix) && !$0.hasSuffix(Key.versionSuffix)
            }
            for key in allKeys {
                guard let data = store.data(forKey: key),
                      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                let id = String(key.dropFirst(Key.positionsPrefix.count))
                let cloudVersion = Int64(dict["updated_at"] as? Double ?? 0)

                // Check local version (last-writer-wins)
                let local = try await database.query(
                    "SELECT updated_at FROM playback_positions WHERE id = ? LIMIT 1",
                    [.string(id)]
                )
                let localVersion = Int64(local.first?.double("updated_at") ?? 0)

                if cloudVersion > localVersion {
                    let bookID = dict["book_id"] as? String ?? ""
                    let chapterID = dict["chapter_id"] as? String ?? ""
                    let position = dict["position_seconds"] as? Double ?? 0
                    let duration = dict["duration_seconds"] as? Double
                    let updatedAt = dict["updated_at"] as? Double ?? 0
                    let finished = dict["is_finished"] as? Bool ?? false

                    try await database.execute("""
                    INSERT INTO playback_positions
                        (id, book_id, chapter_id, position_seconds, duration_seconds, updated_at, is_finished)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(book_id, chapter_id) DO UPDATE SET
                        position_seconds = excluded.position_seconds,
                        duration_seconds = excluded.duration_seconds,
                        updated_at = excluded.updated_at,
                        is_finished = excluded.is_finished
                    """, [
                        .string(id),
                        .string(bookID),
                        .string(chapterID),
                        .double(position),
                        duration.map { .double($0) } ?? .null,
                        .double(updatedAt),
                        .bool(finished)
                    ])
                }

                // Update local version tracker
                store.set(max(cloudVersion, localVersion), forKey: key + Key.versionSuffix)
            }
            store.synchronize()
        } catch {
            syncError = error.localizedDescription
        }
    }

    func pullFavorites() async -> Set<String> {
        guard isAvailable, ProFeature.isEnabled(.icloudSync) else { return [] }
        let allKeys = store.dictionaryRepresentation.keys.filter {
            $0.hasPrefix(Key.favoritesPrefix) && !$0.hasSuffix(Key.versionSuffix)
        }
        return Set(allKeys.compactMap { key -> String? in
            guard store.bool(forKey: key) else { return nil }
            return String(key.dropFirst(Key.favoritesPrefix.count))
        })
    }

    // MARK: - Sync orchestration

    func sync() async {
        guard isAvailable, ProFeature.isEnabled(.icloudSync) else { return }
        isSyncing = true
        defer { isSyncing = false }

        await pullPlaybackPositions()
        await pushPlaybackPositions()
        await pullBookmarks()
        await pushBookmarks()
        await pushFavorites()
    }

    private func handleExternalChange(_ notification: Notification) async {
        guard let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int else {
            return
        }
        if reason == NSUbiquitousKeyValueStoreServerChange ||
           reason == NSUbiquitousKeyValueStoreInitialSyncChange {
            await pullPlaybackPositions()
            let favs = await pullFavorites()
            if !favs.isEmpty {
                await applyCloudFavorites(favs)
            }
            await pullBookmarks()
        }
    }

    private func applyCloudFavorites(_ cloudFavoriteIDs: Set<String>) async {
        do {
            try await database.prepare()
            for favID in cloudFavoriteIDs {
                try? await database.execute(
                    "UPDATE books SET is_favorite = 1 WHERE id = ? AND is_favorite = 0",
                    [.string(favID)]
                )
            }
        } catch {
            syncError = error.localizedDescription
        }
    }
}
