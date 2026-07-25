import Foundation
import CloudKit

@MainActor
public final class CloudKitSyncEngine: ObservableObject {
    @Published public private(set) var syncState: SyncState = .disconnected
    @Published public private(set) var lastSyncDate: Date?
    @Published public var syncError: String?

    public enum SyncState: Equatable {
        case disconnected
        case initializing
        case syncing
        case idle
        case error
    }

    private let database: AppDatabase
    private let stateStore: CloudSyncStateStore
    private let container: CKContainer
    private let zoneID: CKRecordZone.ID

    private var iCloudSyncEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: AppPreferencesStore.Keys.iCloudSyncEnabled) == nil {
            return true
        }
        return defaults.bool(forKey: AppPreferencesStore.Keys.iCloudSyncEnabled)
    }

    public init(database: AppDatabase, containerID: String = "iCloud.guru.parso.voxglass") {
        self.database = database
        self.stateStore = CloudSyncStateStore(database: database)
        self.container = CKContainer(identifier: containerID)
        self.zoneID = CloudKitRecordMapper.libraryZoneID
    }

    public func start() async {
        await refreshAccountStatus()
        guard shouldSync else {
            syncState = .disconnected
            return
        }
        syncState = .initializing
        do {
            try await database.prepare()
            try await ensureZoneExists()
            try await fetchRecordZoneChanges()
            syncState = .idle
            await sendChanges()
            syncState = .idle
        } catch {
            syncState = .error
            syncError = error.localizedDescription
        }
    }

    public func sendChanges() async {
        guard shouldSync, syncState != .initializing else { return }
        syncState = .syncing
        do {
            try await sendPendingChanges(modify: modifyRecords)
            syncState = .idle
            lastSyncDate = Date()
        } catch {
            syncError = error.localizedDescription
        }
    }

    func sendPendingChanges(
        modify: ([CKRecord], [CKRecord.ID]) async throws -> Void
    ) async throws {
        let pending = try await stateStore.dequeuePending(limit: 50)
        guard !pending.isEmpty else {
            syncState = .idle
            return
        }

        var recordsToSave: [CKRecord] = []
        var recordIDsToDelete: [CKRecord.ID] = []
        var succeeded: [(localID: String, recordType: String)] = []

        for item in pending {
            var built = false
            switch item.recordType {
            case CloudKitRecordMapper.RecordType.playbackPosition.rawValue:
                if let record = try? await positionRecord(localID: item.localID) {
                    recordsToSave.append(record)
                    built = true
                }
            case CloudKitRecordMapper.RecordType.bookmark.rawValue:
                if let record = try? await bookmarkRecord(localID: item.localID) {
                    recordsToSave.append(record)
                    built = true
                }
            case CloudKitRecordMapper.RecordType.book.rawValue where item.changeType == "delete":
                if let recordID = try? await bookDeleteRecordID(localID: item.localID) {
                    recordIDsToDelete.append(recordID)
                    built = true
                }
            default:
                if let record = try? await bookRecord(localID: item.localID) {
                    recordsToSave.append(record)
                    built = true
                }
            }
            if built {
                succeeded.append((item.localID, item.recordType))
            }
        }

        if !recordsToSave.isEmpty || !recordIDsToDelete.isEmpty {
            try await modify(recordsToSave, recordIDsToDelete)
        }

        for item in succeeded {
            try? await stateStore.removePending(localID: item.localID, recordType: item.recordType)
        }
    }

    public func pushAfterMutation() {
        guard shouldSync else { return }
        Task {
            await sendChanges()
        }
    }

    public var shouldSync: Bool {
        SyncGate.shouldSync(
            iCloudSyncEnabled: iCloudSyncEnabled,
            accountStatus: accountStatus
        )
    }

    @Published public private(set) var accountStatus: CKAccountStatus = .couldNotDetermine

    public func refreshAccountStatus() async {
        #if DEBUG
        if let forced = testForceAccountAvailable {
            accountStatus = forced ? .available : .noAccount
            return
        }
        #endif
        accountStatus = await withCheckedContinuation { continuation in
            container.accountStatus { status, _ in
                continuation.resume(returning: status)
            }
        }
    }

    #if DEBUG
    public var testForceAccountAvailable: Bool?
    #endif

    // MARK: - CloudKit operations

    public func fetchChanges() async {
        guard shouldSync else { return }
        do {
            try await ensureZoneExists()
            try await fetchRecordZoneChanges()
        } catch {
            syncError = error.localizedDescription
        }
    }

    private func ensureZoneExists() async throws {
        let db = container.privateCloudDatabase
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKModifyRecordZonesOperation(
                recordZonesToSave: [CKRecordZone(zoneID: zoneID)],
                recordZoneIDsToDelete: nil
            )
            operation.modifyRecordZonesResultBlock = { result in
                switch result {
                case .success: continuation.resume()
                case .failure(let error):
                    if let ckError = error as? CKError, ckError.code == .userDeletedZone {
                        let recreate = CKModifyRecordZonesOperation(
                            recordZonesToSave: [CKRecordZone(zoneID: self.zoneID)],
                            recordZoneIDsToDelete: nil
                        )
                        recreate.modifyRecordZonesResultBlock = { _ in continuation.resume() }
                        db.add(recreate)
                    } else {
                        continuation.resume()
                    }
                }
            }
            db.add(operation)
        }
    }

    private func fetchRecordZoneChanges() async throws {
        guard shouldSync else { return }
        let db = container.privateCloudDatabase

        let serverChangeToken: CKServerChangeToken?
        if let tokenData = try? await stateStore.loadEngineState() {
            serverChangeToken = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: tokenData)
        } else {
            serverChangeToken = nil
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
                previousServerChangeToken: serverChangeToken,
                resultsLimit: 200,
                desiredKeys: nil
            )
            let operation = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [zoneID],
                configurationsByRecordZoneID: [zoneID: config]
            )
            var newToken: CKServerChangeToken?
            let callbackLock = NSLock()
            var changedRecords: [CKRecord] = []
            var deletedRecordIDs: [CKRecord.ID] = []

            operation.recordWasChangedBlock = { _, result in
                if case .success(let record) = result {
                    callbackLock.lock()
                    changedRecords.append(record)
                    callbackLock.unlock()
                }
            }

            operation.recordWithIDWasDeletedBlock = { recordID, _ in
                callbackLock.lock()
                deletedRecordIDs.append(recordID)
                callbackLock.unlock()
            }

            operation.recordZoneChangeTokensUpdatedBlock = { _, token, _ in
                callbackLock.lock()
                newToken = token
                callbackLock.unlock()
            }

            operation.recordZoneFetchResultBlock = { [weak self] zoneID, result in
                if case .failure(let error) = result {
                    Task { @MainActor [weak self] in
                        self?.syncError = error.localizedDescription
                    }
                }
            }

            operation.fetchRecordZoneChangesResultBlock = { [weak self] result in
                callbackLock.lock()
                let recordsToImport = changedRecords
                let deletionsToApply = deletedRecordIDs
                let token = newToken
                callbackLock.unlock()

                Task { @MainActor [weak self] in
                    guard let self else {
                        continuation.resume()
                        return
                    }

                    switch result {
                    case .success:
                        for record in recordsToImport {
                            try? await self.importRecord(record)
                        }
                        for recordID in deletionsToApply {
                            try? await self.handleDeletion(recordID: recordID)
                        }
                        if let token,
                           let tokenData = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
                            try? await self.stateStore.saveEngineState(tokenData)
                        }
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }

            db.add(operation)
        }
    }

    private func modifyRecords(save: [CKRecord], delete: [CKRecord.ID]) async throws {
        let db = container.privateCloudDatabase
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKModifyRecordsOperation(
                recordsToSave: save.isEmpty ? nil : save,
                recordIDsToDelete: delete.isEmpty ? nil : delete
            )
            operation.savePolicy = .changedKeys
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            db.add(operation)
        }
    }

    // MARK: - Record builders

    private func bookRecord(localID: String) async throws -> CKRecord? {
        guard let bookWithChapters = try? await fetchBookWithChapters(localID: localID),
              let contentKey = await contentKeyForBook(localID: localID),
              let sourceKey = await sourceKeyForBook(localID: localID) else { return nil }
        return CloudKitRecordMapper.bookRecord(
            from: bookWithChapters.book,
            chapters: bookWithChapters.chapters,
            contentKey: contentKey,
            sourceKey: sourceKey
        )
    }

    private func bookDeleteRecordID(localID: String) async throws -> CKRecord.ID? {
        guard let contentKey = await contentKeyForBook(localID: localID) else { return nil }
        return CKRecord.ID(
            recordName: CloudKitRecordMapper.bookRecordName(contentKey: contentKey),
            zoneID: zoneID
        )
    }

    private func positionRecord(localID: String) async throws -> CKRecord? {
        let rows = try await database.query(
            "SELECT id, book_id, chapter_id, position_seconds, duration_seconds, updated_at, is_finished FROM playback_positions WHERE id = ? LIMIT 1",
            [.string(localID)]
        )
        guard let row = rows.first else { return nil }
        let position = PlaybackPosition(
            id: try ModelMapping.uuid(row, "id"),
            bookID: try ModelMapping.uuid(row, "book_id"),
            chapterID: try ModelMapping.uuid(row, "chapter_id"),
            position: row.double("position_seconds") ?? 0,
            duration: row.double("duration_seconds"),
            updatedAt: ModelMapping.date(row, "updated_at"),
            isFinished: row.bool("is_finished") ?? false
        )
        guard let bookContentKey = await contentKeyForBookID(position.bookID) else { return nil }
        return CloudKitRecordMapper.positionRecord(from: position, bookContentKey: bookContentKey)
    }

    private func bookmarkRecord(localID: String) async throws -> CKRecord? {
        let rows = try await database.query(
            "SELECT id, book_id, chapter_id, position_seconds, note, created_at, updated_at, is_deleted FROM bookmarks WHERE id = ? LIMIT 1",
            [.string(localID)]
        )
        guard let row = rows.first else { return nil }
        let bookmark = Bookmark(
            id: try ModelMapping.uuid(row, "id"),
            bookID: try ModelMapping.uuid(row, "book_id"),
            chapterID: try ModelMapping.uuid(row, "chapter_id"),
            position: row.double("position_seconds") ?? 0,
            note: row.string("note"),
            createdAt: ModelMapping.date(row, "created_at"),
            updatedAt: ModelMapping.date(row, "updated_at"),
            isDeleted: row.bool("is_deleted") ?? false
        )
        guard let bookContentKey = await contentKeyForBookID(bookmark.bookID) else { return nil }
        return CloudKitRecordMapper.bookmarkRecord(from: bookmark, bookContentKey: bookContentKey)
    }

    private func importRecord(_ record: CKRecord) async throws {
        switch record.recordType {
        case CloudKitRecordMapper.RecordType.source.rawValue:
            guard let source = CloudKitRecordMapper.source(from: record) else { return }
            try await upsertSource(source)

        case CloudKitRecordMapper.RecordType.book.rawValue:
            guard let book = CloudKitRecordMapper.book(from: record),
                  let contentKey = CloudKitRecordMapper.contentKey(from: record) else { return }
            let chapters = try CloudKitRecordMapper.chaptersData(from: record)
            try await upsertBook(book, chapters: chapters, contentKey: contentKey)

        case CloudKitRecordMapper.RecordType.playbackPosition.rawValue:
            guard let position = CloudKitRecordMapper.position(from: record) else { return }
            try await upsertPosition(position, bookRef: record)

        case CloudKitRecordMapper.RecordType.bookmark.rawValue:
            guard let bookmark = CloudKitRecordMapper.bookmark(from: record) else { return }
            try await upsertBookmark(bookmark, bookRef: record)

        default:
            break
        }
    }

    private func handleDeletion(recordID: CKRecord.ID) async throws {
        let recordName = recordID.recordName
        if let localID = try? await stateStore.localID(for: recordName) {
            try? await database.execute("DELETE FROM books WHERE id = ?", [.string(localID)])
        }
    }

    // MARK: - Local DB helpers

    private func upsertSource(_ source: Source) async throws {
        let identity = sourceKindIdentity(for: source)
        let sourceID = CloudKitRecordMapper.stableUUID(from: identity)
        try await database.execute("""
        INSERT OR REPLACE INTO sources (id, kind, title, url, created_at)
        VALUES (?, ?, ?, ?, ?)
        """, [
            .string(sourceID.uuidString),
            .string(source.kind.rawValue),
            .string(source.title),
            ModelMapping.databaseValue(source.url),
            ModelMapping.databaseValue(source.createdAt)
        ])
    }

    private func sourceKindIdentity(for source: Source) -> String {
        switch source.kind {
        case .librivox, .internetArchive, .internetArchiveURL:
            if let url = source.url,
               let i = url.pathComponents.firstIndex(of: "details"),
               url.pathComponents.indices.contains(i + 1) {
                return url.pathComponents[i + 1]
            }
            return source.title
        case .localFiles:
            return CloudKitRecordMapper.sha256First12(source.url?.absoluteString ?? source.title)
        }
    }

    private func upsertBook(_ book: Book, chapters: [Chapter], contentKey: String) async throws {
        let existing = try await database.query(
            "SELECT id FROM books WHERE content_key = ? LIMIT 1",
            [.string(contentKey)]
        )
        if let existingRow = existing.first, let bookIDStr = existingRow.string("id") {
            try await database.execute("""
            UPDATE books SET title = ?, authors_json = ?, narrators_json = ?, summary = ?, cover_url = ?,
            updated_at = ?, is_favorite = ? WHERE id = ?
            """, [
                .string(book.title),
                .string(ModelMapping.authorsJSON(book.authors)),
                .string(ModelMapping.narratorsJSON(book.narrators)),
                ModelMapping.databaseValue(book.summary),
                ModelMapping.databaseValue(book.coverURL),
                ModelMapping.databaseValue(book.updatedAt),
                .bool(book.isFavorite),
                .string(bookIDStr)
            ])
        } else {
            try await importNewBook(book, chapters: chapters, contentKey: contentKey)
        }
    }

    private func importNewBook(_ book: Book, chapters: [Chapter], contentKey: String) async throws {
        let sourceID = book.sourceID.uuidString
        try await database.execute("""
        INSERT OR IGNORE INTO sources (id, kind, title, url, created_at)
        VALUES (?, ?, ?, ?, ?)
        """, [
            .string(sourceID),
            .string("librivox"),
            .string("Synced Source"),
            .null,
            .double(book.createdAt.timeIntervalSince1970)
        ])
        try await database.execute("""
        INSERT INTO books (id, title, authors_json, narrators_json, summary, source_id, cover_url, created_at, updated_at, is_favorite, content_key)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            ModelMapping.databaseValue(book.id),
            .string(book.title),
            .string(ModelMapping.authorsJSON(book.authors)),
            .string(ModelMapping.narratorsJSON(book.narrators)),
            ModelMapping.databaseValue(book.summary),
            ModelMapping.databaseValue(sourceID),
            ModelMapping.databaseValue(book.coverURL),
            ModelMapping.databaseValue(book.createdAt),
            ModelMapping.databaseValue(book.updatedAt),
            .bool(book.isFavorite),
            .string(contentKey)
        ])
        for chapter in chapters {
            var c = chapter
            c.bookID = book.id
            c.localURL = nil
            let chapterKey = ContentKey.chapter(
                remoteURL: c.remoteURL,
                localURL: c.localURL,
                index: c.index,
                title: c.title
            )
            try await database.execute("""
            INSERT INTO chapters (id, book_id, title, sort_key, chapter_index, duration_seconds, remote_url, opus_url, local_url, narrators_json, content_key)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [
                ModelMapping.databaseValue(c.id),
                ModelMapping.databaseValue(c.bookID),
                .string(c.title),
                .string(c.sortKey),
                .int(Int64(c.index)),
                ModelMapping.databaseValue(c.duration),
                ModelMapping.databaseValue(c.remoteURL),
                ModelMapping.databaseValue(c.opusURL),
                .null,
                .string(ModelMapping.narratorsJSON(c.narrators)),
                .string(chapterKey)
            ])
        }
    }

    private func upsertPosition(_ position: PlaybackPosition, bookRef record: CKRecord) async throws {
        guard let bookRef = record[CloudKitRecordMapper.Field.bookRef] as? CKRecord.Reference else { return }
        let recordName = bookRef.recordID.recordName.replacingOccurrences(of: "book-", with: "")
        let bookRows = try await database.query(
            "SELECT id FROM books WHERE content_key LIKE ? LIMIT 1",
            [.string("%\(recordName)%")]
        )
        guard let localBookID = bookRows.first?.string("id") else { return }
        let localUpdate = position.updatedAt.timeIntervalSince1970
        let existingRows = try await database.query(
            "SELECT id, updated_at FROM playback_positions WHERE book_id = ? AND chapter_id = ? LIMIT 1",
            [.string(localBookID), .string(position.chapterID.uuidString)]
        )
        if let existingRow = existingRows.first,
           (existingRow.double("updated_at") ?? 0) >= localUpdate {
            return
        }
        try await database.execute("""
        INSERT INTO playback_positions (id, book_id, chapter_id, position_seconds, duration_seconds, updated_at, is_finished)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(book_id, chapter_id) DO UPDATE SET
            position_seconds = excluded.position_seconds,
            duration_seconds = excluded.duration_seconds,
            updated_at = excluded.updated_at,
            is_finished = excluded.is_finished
        """, [
            .string(existingRows.first?.string("id") ?? UUID().uuidString),
            .string(localBookID),
            .string(position.chapterID.uuidString),
            .double(position.position),
            ModelMapping.databaseValue(position.duration),
            .double(localUpdate),
            .bool(position.isFinished)
        ])
    }

    private func upsertBookmark(_ bookmark: Bookmark, bookRef record: CKRecord) async throws {
        guard let bookRef = record[CloudKitRecordMapper.Field.bookRef] as? CKRecord.Reference,
              let bookmarkID = bookmark.id else { return }
        let recordName = bookRef.recordID.recordName.replacingOccurrences(of: "book-", with: "")
        let bookRows = try await database.query(
            "SELECT id FROM books WHERE content_key LIKE ? LIMIT 1",
            [.string("%\(recordName)%")]
        )
        guard let localBookID = bookRows.first?.string("id") else { return }

        try await database.execute("""
        INSERT INTO bookmarks (id, book_id, chapter_id, position_seconds, note, created_at, updated_at, is_deleted)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            position_seconds = excluded.position_seconds,
            note = excluded.note,
            updated_at = excluded.updated_at,
            is_deleted = excluded.is_deleted
        """, [
            .string(bookmarkID.uuidString),
            .string(localBookID),
            .string(bookmark.chapterID.uuidString),
            .double(bookmark.position),
            .string(bookmark.note ?? ""),
            .double(bookmark.createdAt.timeIntervalSince1970),
            .double(bookmark.updatedAt.timeIntervalSince1970),
            .bool(bookmark.isDeleted)
        ])
    }

    private func fetchBookWithChapters(localID: String) async throws -> BookWithChapters? {
        let bookRows = try await database.query(
            "SELECT id, title, authors_json, narrators_json, summary, source_id, cover_url, created_at, updated_at, is_favorite FROM books WHERE id = ? LIMIT 1",
            [.string(localID)]
        )
        guard let bookRow = bookRows.first else { return nil }
        let book = Book(
            id: try ModelMapping.uuid(bookRow, "id"),
            title: try bookRow.requiredString("title"),
            authors: ModelMapping.authors(from: bookRow),
            narrators: ModelMapping.narrators(from: bookRow),
            summary: bookRow.string("summary"),
            sourceID: try ModelMapping.uuid(bookRow, "source_id"),
            coverURL: ModelMapping.url(bookRow, "cover_url"),
            createdAt: ModelMapping.date(bookRow, "created_at"),
            updatedAt: ModelMapping.date(bookRow, "updated_at"),
            isFavorite: bookRow.bool("is_favorite") ?? false
        )
        let chapterRows = try await database.query(
            "SELECT id, book_id, title, sort_key, chapter_index, duration_seconds, remote_url, opus_url, local_url, narrators_json FROM chapters WHERE book_id = ? ORDER BY chapter_index ASC",
            [ModelMapping.databaseValue(book.id)]
        )
        let chapters = try chapterRows.map { row -> Chapter in
            Chapter(
                id: try ModelMapping.uuid(row, "id"),
                bookID: try ModelMapping.uuid(row, "book_id"),
                title: try row.requiredString("title"),
                sortKey: try row.requiredString("sort_key"),
                index: Int(row.int("chapter_index") ?? 0),
                duration: row.double("duration_seconds"),
                remoteURL: ModelMapping.url(row, "remote_url"),
                opusURL: ModelMapping.url(row, "opus_url"),
                localURL: ModelMapping.url(row, "local_url"),
                narrators: ModelMapping.narrators(from: row)
            )
        }
        return BookWithChapters(book: book, chapters: chapters)
    }

    // MARK: - Key lookups

    private func contentKeyForBook(localID: String) async -> String? {
        let rows = try? await database.query(
            "SELECT content_key FROM books WHERE id = ? LIMIT 1",
            [.string(localID)]
        )
        return rows?.first?.string("content_key")
    }

    private func contentKeyForBookID(_ bookID: UUID) async -> String? {
        await contentKeyForBook(localID: bookID.uuidString)
    }

    private func sourceKeyForBook(localID: String) async -> String? {
        let rows = try? await database.query(
            "SELECT s.url, s.kind FROM sources s JOIN books b ON b.source_id = s.id WHERE b.id = ? LIMIT 1",
            [.string(localID)]
        )
        guard let row = rows?.first else { return nil }
        let url = ModelMapping.url(row, "url")
        let kind = SourceKind(rawValue: row.string("kind") ?? "") ?? .librivox
        guard let sourceKey = CloudKitRecordMapper.sourceRecordName(sourceURL: url, kind: kind) else { return nil }
        return sourceKey.replacingOccurrences(of: "source-", with: "")
    }
}
