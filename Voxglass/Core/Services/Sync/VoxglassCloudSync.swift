import Foundation

@MainActor
public final class VoxglassCloudSync: ObservableObject {
    @Published public private(set) var isSyncing = false
    @Published public private(set) var lastSyncDate: Date?
    @Published public var syncError: String?

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

    public init(database: AppDatabase, bookmarkStore: (any BookmarkStore)? = nil) {
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

    public var isAvailable: Bool {
        #if DEBUG
        if let testForceAvailable { return testForceAvailable }
        #endif
        return FileManager.default.ubiquityIdentityToken != nil
    }

    #if DEBUG
    /// Test seam: forces iCloud availability without a signed-in account so the
    /// push/pull round-trip can be exercised against the local KVS backing store.
    public var testForceAvailable: Bool?
    #endif

    // MARK: - Push (device → iCloud)

    /// Playback-position sync is FREE (Phase 3): "never lose your place" is a
    /// trust promise, not an upsell. Only `isAvailable` gates it, never
    /// iCloud sync is always enabled.
    public func pushPlaybackPositions() async {
        guard isAvailable else { return }
        do {
            try await database.prepare()
            let rows = try await database.query("""
            SELECT p.id, p.book_id, p.chapter_id, p.position_seconds, p.duration_seconds,
                   p.updated_at, p.is_finished,
                   b.content_key AS book_content_key, c.content_key AS chapter_content_key
            FROM playback_positions p
            JOIN books b ON b.id = p.book_id
            JOIN chapters c ON c.id = p.chapter_id
            ORDER BY p.updated_at DESC LIMIT 100
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
                        "book_content_key": row.string("book_content_key") ?? "",
                        "chapter_content_key": row.string("chapter_content_key") ?? "",
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
            prunePositionKeys()
            if count > 0 {
                store.set(Date(), forKey: Key.lastSync)
                lastSyncDate = Date()
                store.synchronize()
            }
        } catch {
            syncError = error.localizedDescription
        }
    }

    public func pushFavorites() async {
        guard isAvailable else { return }
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
    public func pushBookmarks() async {
        guard isAvailable, let bmStore = bookmarkStore else { return }
        do {
            try await database.prepare()
            let books = try await database.query("SELECT id FROM books")
            let kvs = self.store
            for bookRow in books {
                guard let bookIDStr = bookRow.string("id"),
                      let bookID = UUID(uuidString: bookIDStr) else { continue }
                let all = try await bmStore.bookmarksForSync(bookID: bookID)
                guard !all.isEmpty else { continue }
                let maxUpdated = all.map(\.updatedAt.timeIntervalSince1970).max() ?? 0
                let key = Key.bookmarksPrefix + bookIDStr
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
    public func pullBookmarks() async {
        guard isAvailable else { return }
        guard let bmStore = bookmarkStore else { return }
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

    /// FREE (Phase 3). Resolves each cloud payload to *local* book/chapter ids by
    /// content key — raw UUIDs from another install fail the foreign key — and
    /// upserts last-writer-wins. Payloads whose book isn't in the library yet are
    /// left in KVS so `adoptCloudPositions(forBookID:)` can apply them after a
    /// re-import (this is what makes delete-and-reinstall work).
    public func pullPlaybackPositions() async {
        guard isAvailable else { return }
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
                if await applyCloudPosition(dict) {
                    let cloudVersion = Int64(dict["updated_at"] as? Double ?? 0)
                    let storedVersion = store.longLong(forKey: key + Key.versionSuffix)
                    store.set(max(cloudVersion, storedVersion), forKey: key + Key.versionSuffix)
                }
            }
            store.synchronize()
        } catch {
            syncError = error.localizedDescription
        }
    }

    /// Applies every stored cloud position whose content key matches the given
    /// (newly imported) book. Called after an import so a reinstalled device gets
    /// its place back the moment the book is in the library again.
    public func adoptCloudPositions(forBookID bookID: UUID) async {
        guard isAvailable else { return }
        do {
            try await database.prepare()
            let bookRows = try await database.query(
                "SELECT content_key FROM books WHERE id = ? LIMIT 1",
                [.string(bookID.uuidString)]
            )
            let bookContentKey = bookRows.first?.string("content_key") ?? ""

            let allKeys = store.dictionaryRepresentation.keys.filter {
                $0.hasPrefix(Key.positionsPrefix) && !$0.hasSuffix(Key.versionSuffix)
            }
            for key in allKeys {
                guard let data = store.data(forKey: key),
                      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                let payloadBookKey = dict["book_content_key"] as? String ?? ""
                let payloadBookID = dict["book_id"] as? String ?? ""
                let matchesContentKey = !bookContentKey.isEmpty && payloadBookKey == bookContentKey
                let matchesRawID = payloadBookID.caseInsensitiveCompare(bookID.uuidString) == .orderedSame
                guard matchesContentKey || matchesRawID else { continue }
                _ = await applyCloudPosition(dict)
            }
        } catch {
            syncError = error.localizedDescription
        }
    }

    /// Resolves a cloud position payload to local ids (content key first, raw
    /// UUID as fallback) and upserts it, LWW on `updated_at`. Every
    /// `UUID(uuidString:)` is guarded. Returns whether the row was applied.
    private func applyCloudPosition(_ dict: [String: Any]) async -> Bool {
        let cloudUpdated = dict["updated_at"] as? Double ?? 0
        let positionSeconds = dict["position_seconds"] as? Double ?? 0
        let duration = dict["duration_seconds"] as? Double
        let finished = dict["is_finished"] as? Bool ?? false
        let bookContentKey = dict["book_content_key"] as? String ?? ""
        let chapterContentKey = dict["chapter_content_key"] as? String ?? ""
        let rawBookID = dict["book_id"] as? String ?? ""
        let rawChapterID = dict["chapter_id"] as? String ?? ""

        var localBookID: String?
        if !bookContentKey.isEmpty {
            let rows = try? await database.query(
                "SELECT id FROM books WHERE content_key = ? LIMIT 1",
                [.string(bookContentKey)]
            )
            localBookID = rows?.first?.string("id")
        }
        if localBookID == nil, UUID(uuidString: rawBookID) != nil {
            let rows = try? await database.query(
                "SELECT id FROM books WHERE id = ? LIMIT 1",
                [.string(rawBookID)]
            )
            localBookID = rows?.first?.string("id")
        }
        guard let bookID = localBookID else { return false }

        var localChapterID: String?
        if !chapterContentKey.isEmpty {
            let rows = try? await database.query(
                "SELECT id FROM chapters WHERE book_id = ? AND content_key = ? LIMIT 1",
                [.string(bookID), .string(chapterContentKey)]
            )
            localChapterID = rows?.first?.string("id")
        }
        if localChapterID == nil, UUID(uuidString: rawChapterID) != nil {
            let rows = try? await database.query(
                "SELECT id FROM chapters WHERE book_id = ? AND id = ? LIMIT 1",
                [.string(bookID), .string(rawChapterID)]
            )
            localChapterID = rows?.first?.string("id")
        }
        guard let chapterID = localChapterID else { return false }

        let localRows = (try? await database.query(
            "SELECT id, updated_at FROM playback_positions WHERE book_id = ? AND chapter_id = ? LIMIT 1",
            [.string(bookID), .string(chapterID)]
        )) ?? []
        let localVersion = localRows.first?.double("updated_at") ?? 0
        guard cloudUpdated > localVersion else { return false }
        let rowID = localRows.first?.string("id") ?? UUID().uuidString

        do {
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
                .string(rowID),
                .string(bookID),
                .string(chapterID),
                .double(positionSeconds),
                duration.map { .double($0) } ?? .null,
                .double(cloudUpdated),
                .bool(finished)
            ])
            return true
        } catch {
            return false
        }
    }

    /// KVS has a 1024-key / 1 MB ceiling and nothing pruned before Phase 3. Keeps
    /// the newest `maxPositionKeys` position payloads (by version stamp) and
    /// removes the rest along with their version trackers.
    public static let maxPositionKeys = 200

    private func prunePositionKeys() {
        let dataKeys = store.dictionaryRepresentation.keys.filter {
            $0.hasPrefix(Key.positionsPrefix) && !$0.hasSuffix(Key.versionSuffix)
        }
        guard dataKeys.count > Self.maxPositionKeys else { return }
        let sorted = dataKeys.sorted {
            store.longLong(forKey: $0 + Key.versionSuffix) > store.longLong(forKey: $1 + Key.versionSuffix)
        }
        for key in sorted.dropFirst(Self.maxPositionKeys) {
            store.removeObject(forKey: key)
            store.removeObject(forKey: key + Key.versionSuffix)
        }
    }

    public func pullFavorites() async -> Set<String> {
        guard isAvailable else { return [] }
        let allKeys = store.dictionaryRepresentation.keys.filter {
            $0.hasPrefix(Key.favoritesPrefix) && !$0.hasSuffix(Key.versionSuffix)
        }
        return Set(allKeys.compactMap { key -> String? in
            guard store.bool(forKey: key) else { return nil }
            return String(key.dropFirst(Key.favoritesPrefix.count))
        })
    }

    // MARK: - Sync orchestration

    public func sync() async {
        guard isAvailable else { return }
        isSyncing = true
        defer { isSyncing = false }

        // Positions are free and always run.
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
