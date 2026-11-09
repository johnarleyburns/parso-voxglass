import Foundation

public struct CachedLocalManifest: Equatable, Sendable {
    public let localBookID: UUID
    public let fingerprint: LocalMediaFingerprint

    public init(localBookID: UUID, fingerprint: LocalMediaFingerprint) {
        self.localBookID = localBookID
        self.fingerprint = fingerprint
    }
}

public enum PortableLocalMatch: Equatable, Sendable {
    case exact(localBookID: UUID)
    case none
    case ambiguous([UUID])
}

/// Exact `local-media:v1` identity only; never title, filename, folder or duration.
public enum PortableLocalMatcher {
    public static func match(remoteContentKey: String, localCandidates: [CachedLocalManifest]) -> PortableLocalMatch {
        guard CloudKitRecordMapper.isPortableLocalContentKey(remoteContentKey) else { return .none }
        let ids = localCandidates
            .filter { LocalMediaIdentity.contentKey($0.fingerprint) == remoteContentKey }
            .map(\.localBookID)
        var seen = Set<UUID>()
        let unique = ids.filter { seen.insert($0).inserted }
        switch unique.count {
        case 0: return .none
        case 1: return .exact(localBookID: unique[0])
        default: return .ambiguous(unique)
        }
    }
}

/// Path-free portable metadata retained until matching local media is indexed.
public struct UnresolvedPortableLocal: Codable, Equatable, Sendable {
    public var book: Book
    public var chapters: [Chapter]
    public var positions: [PlaybackPosition]
    public var bookmarks: [Bookmark]
}

public struct PortableLocalDiagnostic: Equatable, Sendable {
    public let contentKey: String
    public let message: String
    public let candidateBookIDs: [UUID]
}

/// Holds synced portable local metadata and applies it to an existing local book
/// once its cached fingerprint matches. Never creates a book or touches audio locations.
public actor PortableLocalMetadataService {
    private let database: AppDatabase
    private let stateStore: CloudSyncStateStore
    private let clock: any Clock

    public init(database: AppDatabase, clock: any Clock = SystemClock()) {
        self.database = database
        self.stateStore = CloudSyncStateStore(database: database)
        self.clock = clock
    }

    private func load(_ key: String) async throws -> UnresolvedPortableLocal? {
        let rows = try await database.query(
            "SELECT payload_json FROM unresolved_portable_local WHERE content_key = ?", [.string(key)])
        guard let json = rows.first?.string("payload_json") else { return nil }
        return try JSONDecoder().decode(UnresolvedPortableLocal.self, from: Data(json.utf8))
    }

    private func save(_ value: UnresolvedPortableLocal, key: String, recordName: String) async throws {
        var stripped = value
        stripped.chapters = value.chapters.map { var c = $0; c.localURL = nil; c.localBookmark = nil; return c }
        let json = String(decoding: try JSONEncoder().encode(stripped), as: UTF8.self)
        try await database.execute("""
        INSERT INTO unresolved_portable_local (content_key, book_record_name, payload_json, received_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(content_key) DO UPDATE SET payload_json = excluded.payload_json
        """, [.string(key), .string(recordName), .string(json), .double(clock.now.timeIntervalSince1970)])
    }

    /// Retains (or refreshes) the book metadata. Existing retained positions/bookmarks are kept.
    public func retainBook(_ placeholder: CloudKitRecordMapper.PortableLocalPlaceholder) async throws {
        try await database.prepare()
        var value = try await load(placeholder.contentKey)
            ?? UnresolvedPortableLocal(book: placeholder.book, chapters: [], positions: [], bookmarks: [])
        value.book = placeholder.book
        value.chapters = placeholder.chapters
        try await save(value, key: placeholder.contentKey,
                       recordName: CloudKitRecordMapper.bookRecordName(contentKey: placeholder.contentKey))
    }

    private func key(forBookRecordName name: String) async throws -> String? {
        try await database.query(
            "SELECT content_key FROM unresolved_portable_local WHERE book_record_name = ?", [.string(name)]
        ).first?.string("content_key")
    }

    /// Returns false when no retained book owns this record name.
    public func retainPosition(_ position: PlaybackPosition, bookRecordName: String) async throws -> Bool {
        try await database.prepare()
        guard let key = try await key(forBookRecordName: bookRecordName), var value = try await load(key) else { return false }
        value.positions.removeAll { $0.chapterID == position.chapterID }
        value.positions.append(position)
        try await save(value, key: key, recordName: bookRecordName)
        return true
    }

    public func retainBookmark(_ bookmark: Bookmark, bookRecordName: String) async throws -> Bool {
        try await database.prepare()
        guard let key = try await key(forBookRecordName: bookRecordName), var value = try await load(key) else { return false }
        value.bookmarks.removeAll { $0.id == bookmark.id }
        value.bookmarks.append(bookmark)
        try await save(value, key: key, recordName: bookRecordName)
        return true
    }

    public func unresolvedContentKeys() async throws -> [String] {
        try await database.prepare()
        return try await database.query("SELECT content_key FROM unresolved_portable_local ORDER BY received_at, content_key")
            .compactMap { $0.string("content_key") }
    }

    /// Diagnostics for unresolved entries (e.g. ambiguous matches) for future UI.
    public func diagnostics() async throws -> [PortableLocalDiagnostic] {
        try await database.prepare()
        return try await database.query(
            "SELECT content_key, diagnostic, ambiguous_json FROM unresolved_portable_local WHERE diagnostic IS NOT NULL"
        ).compactMap { row in
            guard let key = row.string("content_key"), let message = row.string("diagnostic") else { return nil }
            let ids = (row.string("ambiguous_json").flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? [])
                .compactMap(UUID.init(uuidString:))
            return PortableLocalDiagnostic(contentKey: key, message: message, candidateBookIDs: ids)
        }
    }

    /// Matches every retained entry against cached local manifests. Returns resolved local book IDs.
    @discardableResult
    public func resolvePending() async throws -> [UUID] {
        try await database.prepare()
        let fingerprints = LocalMediaFingerprintService(database: database)
        var candidates: [CachedLocalManifest] = []
        for id in try await fingerprints.candidateBookIDs() {
            if let uuid = UUID(uuidString: id), let fp = try await fingerprints.cachedFingerprint(bookID: id) {
                candidates.append(CachedLocalManifest(localBookID: uuid, fingerprint: fp))
            }
        }
        var resolved: [UUID] = []
        for key in try await unresolvedContentKeys() {
            switch PortableLocalMatcher.match(remoteContentKey: key, localCandidates: candidates) {
            case .none:
                try await setDiagnostic(key, message: nil, ids: [])
            case .ambiguous(let ids):
                try await setDiagnostic(key, message: "Multiple local books match this synced book; none was changed.", ids: ids)
            case .exact(let localID):
                guard let value = try await load(key) else { continue }
                try await apply(value, key: key, to: localID)
                try await database.execute("DELETE FROM unresolved_portable_local WHERE content_key = ?", [.string(key)])
                resolved.append(localID)
            }
        }
        return resolved
    }

    private func setDiagnostic(_ key: String, message: String?, ids: [UUID]) async throws {
        let json = String(decoding: try JSONEncoder().encode(ids.map(\.uuidString)), as: UTF8.self)
        try await database.execute(
            "UPDATE unresolved_portable_local SET diagnostic = ?, ambiguous_json = ? WHERE content_key = ?",
            [ModelMapping.databaseValue(message), message == nil ? .null : .string(json), .string(key)])
    }

    private func apply(_ value: UnresolvedPortableLocal, key: String, to localID: UUID) async throws {
        let bookID = localID.uuidString
        let book = value.book
        // Metadata only; chapter local_url / local_bookmark and sources stay untouched.
        try await database.execute("""
        UPDATE books SET title = ?, authors_json = ?, narrators_json = ?, summary = ?, cover_url = ?,
        is_favorite = ?, content_key = ?, updated_at = ? WHERE id = ?
        """, [
            .string(book.title),
            .string(ModelMapping.authorsJSON(book.authors)),
            .string(ModelMapping.narratorsJSON(book.narrators)),
            ModelMapping.databaseValue(book.summary),
            ModelMapping.databaseValue(book.coverURL),
            .bool(book.isFavorite),
            .string(key),
            ModelMapping.databaseValue(book.updatedAt),
            .string(bookID)
        ])

        // Chapter reconciliation: remote chapter IDs alias local chapters by logical index.
        let local = try await database.query("SELECT id, chapter_index FROM chapters WHERE book_id = ?", [.string(bookID)])
        var alias: [UUID: String] = [:]
        for chapter in value.chapters {
            guard let id = local.first(where: { $0.int("chapter_index") == Int64(chapter.index) })?.string("id") else { continue }
            alias[chapter.id] = id
            try await stateStore.saveSystemFields(Data(), recordName: "chapter-" + chapter.id.uuidString,
                                                  recordType: "Chapter", localID: id)
        }

        for position in value.positions {
            guard let chapterID = alias[position.chapterID] else { continue }
            let existing = try await database.query(
                "SELECT id, updated_at FROM playback_positions WHERE book_id = ? AND chapter_id = ?",
                [.string(bookID), .string(chapterID)])
            let incoming = position.updatedAt.timeIntervalSince1970
            if let row = existing.first, (row.double("updated_at") ?? 0) >= incoming { continue }
            try await database.execute("""
            INSERT INTO playback_positions (id, book_id, chapter_id, position_seconds, duration_seconds, updated_at, is_finished)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(book_id, chapter_id) DO UPDATE SET
                position_seconds = excluded.position_seconds, duration_seconds = excluded.duration_seconds,
                updated_at = excluded.updated_at, is_finished = excluded.is_finished
            """, [
                .string(existing.first?.string("id") ?? UUID().uuidString), .string(bookID), .string(chapterID),
                .double(position.position), ModelMapping.databaseValue(position.duration),
                .double(incoming), .bool(position.isFinished)
            ])
        }

        for bookmark in value.bookmarks {
            guard let chapterID = alias[bookmark.chapterID], let id = bookmark.id else { continue }
            let existing = try await database.query("SELECT updated_at FROM bookmarks WHERE id = ?", [.string(id.uuidString)])
            if let row = existing.first, (row.double("updated_at") ?? 0) >= bookmark.updatedAt.timeIntervalSince1970 { continue }
            try await database.execute("""
            INSERT INTO bookmarks (id, book_id, chapter_id, position_seconds, note, created_at, updated_at, is_deleted)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET position_seconds = excluded.position_seconds, note = excluded.note,
                updated_at = excluded.updated_at, is_deleted = excluded.is_deleted
            """, [
                .string(id.uuidString), .string(bookID), .string(chapterID), .double(bookmark.position),
                .string(bookmark.note ?? ""), .double(bookmark.createdAt.timeIntervalSince1970),
                .double(bookmark.updatedAt.timeIntervalSince1970), .bool(bookmark.isDeleted)
            ])
        }
    }
}
