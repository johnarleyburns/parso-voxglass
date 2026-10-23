import Foundation

public enum LibraryBookFilter: Equatable, Hashable, Sendable {
    case all
    case favorites
    case source(UUID)
    case downloaded
    case finished
    case inProgress
}

/// The primary My Books scope. Refinements such as Favorites and Downloaded
/// are intentionally independent of this radio-style selection.
public enum LibraryProgressFilter: Equatable, Hashable, Sendable {
    case all
    case inProgress
    case finished
}

public enum LibrarySort: Equatable, Sendable {
    case recent
    case title
    case author
    case narrator
    case duration
    case progress

    public func comparator() -> (BookWithChapters, BookWithChapters) -> Bool {
        switch self {
        case .recent:
            return { $0.book.updatedAt > $1.book.updatedAt }
        case .title:
            return { $0.book.title.localizedCaseInsensitiveCompare($1.book.title) == .orderedAscending }
        case .author:
            return {
                let a = $0.book.authors.first ?? ""
                let b = $1.book.authors.first ?? ""
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
        case .narrator:
            return {
                let a = $0.book.narrators.first ?? ""
                let b = $1.book.narrators.first ?? ""
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
        case .duration:
            return {
                ($0.totalDuration ?? .greatestFiniteMagnitude) < ($1.totalDuration ?? .greatestFiniteMagnitude)
            }
        case .progress:
            return { ($0.book.updatedAt) > ($1.book.updatedAt) }
        }
    }
}

/// Aggregated playback progress for a single book (P1-2).
public struct BookProgress: Equatable, Sendable {
    public let lastPosition: TimeInterval
    public let isFinished: Bool
}

/// A playable audio file discovered inside a watched folder (§4).
public struct LocalAudioImport: Equatable, Sendable {
    public let url: URL
    public let title: String
    public let sortKey: String
    public let duration: TimeInterval?
    public let startTime: TimeInterval
    /// A security-scoped bookmark for `url`, when the audio is left in place
    /// on disk rather than copied into the app's own storage.
    public let bookmark: Data?

    public init(
        url: URL, title: String, sortKey: String, duration: TimeInterval?,
        startTime: TimeInterval = 0, bookmark: Data? = nil
    ) {
        self.url = url
        self.title = title
        self.sortKey = sortKey
        self.duration = duration
        self.startTime = startTime
        self.bookmark = bookmark
    }
}

public final class LibraryRepository: @unchecked Sendable {
    /// Books skipped by the last `backfillContentKeysIfNeeded()` because another
    /// book already owned the derived key. Diagnostic only; no data is changed.
    public private(set) var contentKeyCollisionCount = 0

    /// Aliases skipped by the last `backfillRecordingIdentitiesIfNeeded()` because
    /// another book already owned them. Diagnostic only; no data is changed.
    public private(set) var recordingIdentityCollisionCount = 0

    public enum RecordingIdentityError: Error, LocalizedError, Equatable {
        case ambiguous(scheme: String, value: String)

        public var errorDescription: String? {
            switch self {
            case .ambiguous(let scheme, let value):
                return "More than one book claims \(scheme) recording \(value); not choosing between them."
            }
        }
    }

    public enum RecordingIdentity {
        public static let internetArchive = "internet-archive"
        public static let libriVox = "librivox"

        public static func normalizedLibriVoxID(_ raw: String?) -> String? {
            guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  value.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(value) else { return nil }
            return String(number) // canonical: `01735` and `1735` are one ID
        }
    }

    let database: AppDatabase
    private let librivoxClient: LibriVoxCatalogClient?
    public var mutationLog: SyncMutationLog?
    /// Seams for `repairLocalAudio`; tests inject fakes, the app uses the system.
    public var localRepairEnvironment = LocalAudioRepairEnvironment.system

    public init(database: AppDatabase, librivoxClient: LibriVoxCatalogClient? = nil) {
        self.database = database
        self.librivoxClient = librivoxClient
    }

    public func fetchLibrary() async throws -> [BookWithChapters] {
        try await database.prepare()

        let bookRows = try await database.query("""
        SELECT id, title, authors_json, narrators_json, summary, source_id, cover_url, created_at, updated_at, is_favorite, is_pending
        FROM books
        ORDER BY updated_at DESC, title COLLATE NOCASE ASC
        """)
        let chapterRows = try await database.query("""
        SELECT id, book_id, title, sort_key, chapter_index, start_time_seconds, duration_seconds, remote_url, opus_url, local_url, local_bookmark, narrators_json
        FROM chapters
        ORDER BY chapter_index ASC, sort_key COLLATE NOCASE ASC
        """)

        let chaptersByBook = try Dictionary(grouping: chapterRows.map(Self.chapter(from:)), by: \.bookID)
        return try bookRows.map { row in
            let book = try Self.book(from: row)
            return BookWithChapters(book: book, chapters: (chaptersByBook[book.id] ?? []).naturallySorted())
        }
    }

    public func fetchBooks(filteredBy filter: LibraryBookFilter) async throws -> [BookWithChapters] {
        let library = try await fetchLibrary()

        switch filter {
        case .all:
            return library
        case .favorites:
            return library.filter(\.book.isFavorite)
        case .source(let sourceID):
            return library.filter { $0.book.sourceID == sourceID }
        case .downloaded:
            let downloadedIDs = try await downloadedBookIDs()
            return library.filter { downloadedIDs.contains($0.book.id) }
        case .finished:
            let progress = try await fetchBookProgress()
            return library.filter { progress[$0.book.id]?.isFinished == true }
        case .inProgress:
            let progress = try await fetchBookProgress()
            return library.filter { book in
                // An added book is In Progress by default, even if unplayed.
                guard let p = progress[book.book.id] else { return true }
                return !p.isFinished
            }
        }
    }

    public func fetchSources() async throws -> [Source] {
        try await database.prepare()

        let rows = try await database.query("""
        SELECT id, kind, title, url, created_at
        FROM sources
        ORDER BY created_at DESC, title COLLATE NOCASE ASC
        """)
        return try rows.map(Self.source(from:))
    }

    public func fetchRecentlyPlayed(limit: Int = 50) async throws -> [BookWithChapters] {
        let library = try await fetchLibrary()
        return try await fetchRecentlyPlayed(from: library, limit: limit)
    }

    /// Resolves listening order against an already-fetched library snapshot.
    /// This avoids the old double library/chapter query during every My Books
    /// refresh.
    public func fetchRecentlyPlayed(
        from library: [BookWithChapters],
        limit: Int = 50
    ) async throws -> [BookWithChapters] {
        try await database.prepare()

        let rows = try await database.query("""
        SELECT book_id, MAX(updated_at) AS latest_position_at
        FROM playback_positions
        GROUP BY book_id
        ORDER BY latest_position_at DESC
        LIMIT ?
        """, [
            .int(Int64(max(0, limit)))
        ])
        let orderedIDs = try rows.map { try ModelMapping.uuid($0, "book_id") }
        let libraryByID = Dictionary(uniqueKeysWithValues: library.map { ($0.book.id, $0) })
        // "Jump Back In" is a My Books surface — a book only previewed from
        // a catalog result (not yet explicitly added) stays out of it, same
        // as it stays out of the My Books list itself, until confirmed.
        return orderedIDs.compactMap { libraryByID[$0] }.filter { !$0.book.isPending }
    }

    /// Every book that has ever been played, most-recently-listened first —
    /// unlike `fetchRecentlyPlayed`, this deliberately INCLUDES pending
    /// (not-yet-added) books, since "what have I listened to" should answer
    /// that regardless of whether the book was ever explicitly added to My
    /// Books.
    public func fetchListeningHistory() async throws -> [(book: BookWithChapters, lastPlayedAt: Date)] {
        try await database.prepare()

        let rows = try await database.query("""
        SELECT book_id, MAX(updated_at) AS latest_position_at
        FROM playback_positions
        GROUP BY book_id
        ORDER BY latest_position_at DESC
        """)
        let library = try await fetchLibrary()
        let libraryByID = Dictionary(uniqueKeysWithValues: library.map { ($0.book.id, $0) })
        return try rows.compactMap { row -> (book: BookWithChapters, lastPlayedAt: Date)? in
            let bookID = try ModelMapping.uuid(row, "book_id")
            guard let book = libraryByID[bookID] else { return nil }
            let lastPlayedAt = ModelMapping.date(row, "latest_position_at")
            return (book, lastPlayedAt)
        }
    }

    /// Removes one book's listening history — this also clears its saved
    /// resume position (`playback_positions` backs both), so it starts over
    /// if played again. That coupling is deliberate: "remove from history"
    /// reads as "forget this," not "keep my place but hide it from a list."
    public func removeListeningHistory(bookID: UUID) async throws {
        try await database.prepare()
        try await database.execute(
            "DELETE FROM playback_positions WHERE book_id = ?",
            [ModelMapping.databaseValue(bookID)]
        )
    }

    public func clearAllListeningHistory() async throws {
        try await database.prepare()
        try await database.execute("DELETE FROM playback_positions", [])
    }

    /// Flips a book's pending flag. `pending: true` is set right after a
    /// catalog-result preview import (see `importInternetArchiveItem`'s
    /// caller in `CatalogResultImporter`); `pending: false` is set when the
    /// user confirms "Add to My Books?" on the book page.
    public func setBookPending(_ pending: Bool, for bookID: UUID) async throws {
        try await database.prepare()
        if pending {
            // Never demote a book the user already has listening state for
            // (positions or bookmarks): previewing it again must only open it.
            try await database.execute("""
            UPDATE books SET is_pending = 1 WHERE id = ?
            AND NOT EXISTS (SELECT 1 FROM playback_positions WHERE book_id = books.id)
            AND NOT EXISTS (SELECT 1 FROM bookmarks WHERE book_id = books.id)
            """, [ModelMapping.databaseValue(bookID)])
            return
        }
        try await database.execute(
            "UPDATE books SET is_pending = ? WHERE id = ?",
            [.bool(pending), ModelMapping.databaseValue(bookID)]
        )
    }

    /// Sets a book's persisted cover reference. `relativePath` is the value
    /// produced by `LocalArtworkStore.storedValue(for:)` — a path relative to
    /// Application Support for an app-owned cover, or a remote URL string.
    public func setBookCover(bookID: UUID, relativePath: String) async throws {
        try await database.prepare()
        try await database.execute(
            "UPDATE books SET cover_url = ? WHERE id = ?",
            [.string(relativePath), ModelMapping.databaseValue(bookID)]
        )
    }

    /// `DatabaseValue` for `books.cover_url`: app-owned covers under Application
    /// Support are stored relative so they survive a container move.
    static func coverURLValue(_ url: URL?) -> DatabaseValue {
        guard let url else { return .null }
        return .string(LocalArtworkStore.storedValue(for: url))
    }

    /// Stable identities for every work that has any saved playback position.
    /// These are used to keep listened items out of recommendation shelves even
    /// when the local UUID differs from the archive.org result identifier.
    public func fetchListenedWorkExclusionKeys() async throws -> Set<String> {
        try await database.prepare()

        let rows = try await database.query("""
        SELECT DISTINCT b.id AS book_id,
               b.title AS title,
               b.authors_json AS authors_json,
               b.content_key AS content_key,
               s.kind AS source_kind,
               s.url AS source_url
        FROM playback_positions p
        JOIN books b ON b.id = p.book_id
        JOIN sources s ON s.id = b.source_id
        """)

        var keys: Set<String> = []
        for row in rows {
            if let bookID = row.string("book_id") {
                keys.insert(bookID)
            }

            let kind = SourceKind(rawValue: row.string("source_kind") ?? "") ?? .localFiles
            let sourceURL = row.string("source_url").flatMap(URL.init(string:))
            let contentKey = row.string("content_key") ?? ContentKey.book(forSourceURL: sourceURL, kind: kind)
            if let contentKey {
                keys.formUnion(Self.exclusionKeys(forContentKey: contentKey))
            }

            let title = row.string("title") ?? ""
            let authors = ModelMapping.authors(from: row)
            keys.insert(WorkKey.normalized(author: authors.isEmpty ? "Unknown author" : authors.joined(separator: ", "), title: title))
        }
        return keys
    }

    /// Deletes a book and everything that cascades from it (chapters, playback
    /// positions, bookmarks, playlist links, taste terms, download records).
    /// Also removes the book's now-orphaned `Source`, since each Internet Archive
    /// import creates its own source row.
    public func deleteBook(_ bookID: UUID) async throws {
        try await database.prepare()

        let rows = try await database.query(
            "SELECT source_id FROM books WHERE id = ? LIMIT 1",
            [ModelMapping.databaseValue(bookID)]
        )
        var sourceID: UUID?
        if let row = rows.first {
            sourceID = try ModelMapping.uuid(row, "source_id")
        }

        // download_records cascade via FK ON DELETE CASCADE, along with chapters,
        // playback_positions, bookmarks, playlist_books, and book_taste.
        try await database.execute(
            "DELETE FROM books WHERE id = ?",
            [ModelMapping.databaseValue(bookID)]
        )
        try? await mutationLog?.enqueue(localID: bookID.uuidString, recordType: "Book", changeType: "delete")

        if let sourceID {
            let remaining = try await database.query(
                "SELECT COUNT(*) AS count FROM books WHERE source_id = ?",
                [ModelMapping.databaseValue(sourceID)]
            )
            let count = remaining.first?.int("count") ?? 0
            if count == 0 {
                try await database.execute(
                    "DELETE FROM sources WHERE id = ?",
                    [ModelMapping.databaseValue(sourceID)]
                )
            }
        }
    }

    public func setFavorite(_ isFavorite: Bool, for bookID: UUID) async throws -> BookWithChapters? {
        try await database.prepare()

        try await database.execute("""
        UPDATE books
        SET is_favorite = ?
        WHERE id = ?
        """, [
            .bool(isFavorite),
            ModelMapping.databaseValue(bookID)
        ])
        try? await mutationLog?.enqueue(localID: bookID.uuidString, recordType: "Book", changeType: "update")
        return try await bookWithChapters(forBookID: bookID)
    }

    public func updateNarrators(_ narrators: [String], for bookID: UUID) async throws {
        try await database.prepare()
        try await database.execute("""
        UPDATE books
        SET narrators_json = ?
        WHERE id = ?
        """, [
            .string(ModelMapping.narratorsJSON(narrators)),
            ModelMapping.databaseValue(bookID)
        ])
    }

    public func updateBookMetadata(authors: [String], narrators: [String], for bookID: UUID) async throws {
        try await database.prepare()
        try await database.execute("""
        UPDATE books SET authors_json = ?, narrators_json = ? WHERE id = ?
        """, [
            .string(ModelMapping.authorsJSON(authors)),
            .string(ModelMapping.narratorsJSON(narrators)),
            ModelMapping.databaseValue(bookID)
        ])
        try? await mutationLog?.enqueue(localID: bookID.uuidString, recordType: "Book", changeType: "update")
    }

    /// One-time best-effort pass over already-imported books whose narrators are
    /// empty: extract names from the stored summary and persist them. Returns the
    /// number of books that were updated.
    @discardableResult
    public func backfillMissingNarrators() async throws -> Int {
        try await database.prepare()
        let rows = try await database.query(
            "SELECT id, summary FROM books WHERE narrators_json = '[]' OR narrators_json IS NULL",
            []
        )
        var updated = 0
        for row in rows {
            guard let summary = row.string("summary") else { continue }
            let narrators = NarratorExtractor.extract(from: summary)
            guard !narrators.isEmpty else { continue }
            let bookID = try ModelMapping.uuid(row, "id")
            try await updateNarrators(narrators, for: bookID)
            updated += 1
        }
        return updated
    }

    /// Returns the book that owns an exact recording identity alias.
    public func bookWithChapters(identityScheme scheme: String, value: String) async throws -> BookWithChapters? {
        try await database.prepare()
        let rows = try await database.query("""
            SELECT book_id FROM book_recording_identities
            WHERE scheme = ? AND value = ? LIMIT 2
        """, [.string(scheme), .string(value)])
        // The table is UNIQUE(scheme, value); more than one owner means the
        // store is corrupt, and guessing could attach the wrong book.
        if rows.count > 1 { throw RecordingIdentityError.ambiguous(scheme: scheme, value: value) }
        guard let id = rows.first?.string("book_id"), let bookID = UUID(uuidString: id) else { return nil }
        return try await bookWithChapters(forBookID: bookID)
    }

    /// All LibriVox recording aliases as (value, bookID) pairs, for the
    /// synchronous result-row ownership index. Duplicates are returned as-is.
    public func fetchLibriVoxIdentities() async throws -> [(value: String, bookID: UUID)] {
        try await database.prepare()
        let rows = try await database.query("""
            SELECT book_id, value FROM book_recording_identities WHERE scheme = ?
        """, [.string(RecordingIdentity.libriVox)])
        return rows.compactMap { row in
            guard let v = row.string("value"), let id = row.string("book_id"),
                  let uuid = UUID(uuidString: id) else { return nil }
            return (v, uuid)
        }
    }

    private func insertIdentity(bookID: UUID, scheme: String, value: String) async throws {
        try await database.execute("""
            INSERT OR IGNORE INTO book_recording_identities (book_id, scheme, value, created_at)
            VALUES (?, ?, ?, ?)
        """, [.string(bookID.uuidString), .string(scheme), .string(value), .double(Date().timeIntervalSince1970)])
    }

    /// Backfills the Internet Archive alias from exact local signals only: a
    /// valid `ia:<identifier>` content key, or a single unambiguous Archive
    /// chapter-download identifier. No LibriVox alias is inferred (no persisted
    /// legacy format carries an exact numeric recording ID). Never overwrites or
    /// merges: on an alias owned by another book, both rows stay untouched and
    /// `recordingIdentityCollisionCount` is incremented. Idempotent.
    @discardableResult
    public func backfillRecordingIdentitiesIfNeeded() async -> Int {
        recordingIdentityCollisionCount = 0
        do {
            try await database.prepare()
            var inserted = 0
            let rows = try await database.query("""
            SELECT b.id AS book_id, b.content_key AS content_key
            FROM books b
            WHERE NOT EXISTS (
                SELECT 1 FROM book_recording_identities i
                WHERE i.book_id = b.id AND i.scheme = ?
            )
            """, [.string(RecordingIdentity.internetArchive)])
            for row in rows {
                guard let bookIDString = row.string("book_id"),
                      let bookID = UUID(uuidString: bookIDString) else { continue }
                var identifier: String?
                if let key = row.string("content_key"), key.hasPrefix("ia:") {
                    let candidate = String(key.dropFirst(3))
                    if !candidate.isEmpty { identifier = candidate }
                }
                if identifier == nil {
                    let ids = try await chapterDownloadIdentifiers(forBookID: bookIDString)
                    if ids.count == 1 { identifier = ids.first }
                }
                guard let identifier else { continue }
                let owner = try await database.query("""
                    SELECT book_id FROM book_recording_identities
                    WHERE scheme = ? AND value = ? LIMIT 1
                """, [.string(RecordingIdentity.internetArchive), .string(identifier)])
                if let ownerID = owner.first?.string("book_id") {
                    if ownerID != bookIDString { recordingIdentityCollisionCount += 1 }
                    continue
                }
                try await insertIdentity(bookID: bookID, scheme: RecordingIdentity.internetArchive, value: identifier)
                inserted += 1
            }
            return inserted
        } catch {
            return 0
        }
    }

    /// Backfills `content_key` for books and chapters imported before migration 7,
    /// deriving each key from data already in the database (source URL/kind for
    /// books; audio filename stem for chapters). Idempotent — only NULL keys are
    /// touched, so this is cheap on every launch after the first.
    @discardableResult
    public func backfillContentKeysIfNeeded() async -> Int {
        contentKeyCollisionCount = 0
        do {
            try await database.prepare()
            var updated = 0

            let bookRows = try await database.query("""
            SELECT b.id AS book_id, s.url AS source_url, s.kind AS source_kind
            FROM books b JOIN sources s ON s.id = b.source_id
            WHERE b.content_key IS NULL
            """)
            for row in bookRows {
                guard let bookID = row.string("book_id") else { continue }
                let kind = SourceKind(rawValue: row.string("source_kind") ?? "") ?? .localFiles
                let url = row.string("source_url").flatMap(URL.init(string:))
                var derivedKey = ContentKey.book(forSourceURL: url, kind: kind)
                if derivedKey == nil, kind != .localFiles {
                    // Source URL can't supply an identity (null/non-details URL,
                    // e.g. CloudKit-restored): use consistent chapter download URLs.
                    let identifiers = try await chapterDownloadIdentifiers(forBookID: bookID)
                    if identifiers.count == 1, let only = identifiers.first {
                        derivedKey = ContentKey.book(forInternetArchiveIdentifier: only)
                    }
                }
                guard let key = derivedKey else { continue }
                let clash = try await database.query(
                    "SELECT id FROM books WHERE content_key = ? AND id != ? LIMIT 1",
                    [.string(key), .string(bookID)]
                )
                if !clash.isEmpty {
                    // Never overwrite or merge: preserve both rows, report the collision.
                    contentKeyCollisionCount += 1
                    continue
                }
                try await database.execute(
                    "UPDATE books SET content_key = ? WHERE id = ?",
                    [.string(key), .string(bookID)]
                )
                updated += 1
            }

            let chapterRows = try await database.query("""
            SELECT id, title, chapter_index, remote_url, local_url
            FROM chapters
            WHERE content_key IS NULL
            """)
            for row in chapterRows {
                guard let chapterID = row.string("id") else { continue }
                let key = ContentKey.chapter(
                    remoteURL: row.string("remote_url").flatMap(URL.init(string:)),
                    localURL: row.string("local_url").flatMap(URL.init(string:)),
                    index: Int(row.int("chapter_index") ?? 0),
                    title: row.string("title") ?? ""
                )
                try await database.execute(
                    "UPDATE chapters SET content_key = ? WHERE id = ?",
                    [.string(key), .string(chapterID)]
                )
                updated += 1
            }
            return updated
        } catch {
            return 0
        }
    }

    /// Queues the current syncable library for CloudKit. This is the launch-time
    /// bridge for books that predate the CloudKit mutation log.
    @discardableResult
    public func enqueueExistingLibraryForSync() async -> Int {
        guard let mutationLog else { return 0 }

        do {
            try await database.prepare()
            let rows = try await database.query("""
            SELECT b.id
            FROM books b
            JOIN sources s ON s.id = b.source_id
            WHERE b.content_key IS NOT NULL
              AND (
                (s.kind IN (?, ?, ?) AND s.url LIKE ?)
                OR (s.kind = ? AND s.url IS NOT NULL)
              )
            ORDER BY b.updated_at ASC
            """, [
                .string(SourceKind.librivox.rawValue),
                .string(SourceKind.internetArchive.rawValue),
                .string(SourceKind.internetArchiveURL.rawValue),
                .string("%/details/%"),
                .string(SourceKind.localFiles.rawValue)
            ])

            var count = 0
            for row in rows {
                guard let bookID = row.string("id") else { continue }
                try await mutationLog.enqueue(
                    localID: bookID,
                    recordType: CloudKitRecordMapper.RecordType.book.rawValue,
                    changeType: "update"
                )
                count += 1
            }
            return count
        } catch {
            return 0
        }
    }

    /// Books imported before taste capture existed (2026-07-11) have no
    /// book_taste rows, so their listening history is invisible to the
    /// recommendation profile. Seed author terms from the locally stored
    /// authors for any book with zero book_taste rows; when no usable author
    /// exists, seed a subject term from the title so played books still
    /// contribute taste (`tasteSeedTerms`). Idempotent.
    @discardableResult
    public func backfillBookTasteIfNeeded() async -> Int {
        do {
            try await database.prepare()
            let rows = try await database.query("""
            SELECT b.id, b.title, b.authors_json FROM books b LEFT JOIN book_taste bt ON
            bt.book_id = b.id WHERE bt.book_id IS NULL
            """)
            var count = 0
            for row in rows {
                guard let bookID = row.string("id") else { continue }
                let authors = (row.string("authors_json")?.data(using: .utf8))
                    .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
                let terms = Self.tasteSeedTerms(authors: authors, title: row.string("title") ?? "")
                guard !terms.isEmpty else { continue }
                for term in terms {
                    try? await database.execute(
                        "INSERT OR IGNORE INTO book_taste (book_id, axis, term) VALUES (?, ?, ?)",
                        [.string(bookID), .string(term.axis), .string(term.term)]
                    )
                }
                count += 1
            }
            return count
        } catch {
            return 0
        }
    }

    public func resplitBookTasteSubjectsIfNeeded(defaults: UserDefaults = .standard) async -> Int {
        let flagKey = "voxglass.bookTasteSubjectResplitV1"
        guard !defaults.bool(forKey: flagKey) else { return 0 }
        do {
            try await database.prepare()
            let rows = try await database.query(
                "SELECT book_id, term FROM book_taste WHERE axis = 'subject' AND term LIKE '%;%'"
            )
            guard !rows.isEmpty else {
                defaults.set(true, forKey: flagKey)
                return 0
            }
            var insertStatements: [(sql: String, bindings: [DatabaseValue])] = []
            for row in rows {
                guard let bookID = row.string("book_id"),
                      let term = row.string("term") else { continue }
                insertStatements.append((
                    "DELETE FROM book_taste WHERE book_id = ? AND axis = 'subject' AND term = ?",
                    [.string(bookID), .string(term)]
                ))
                let tokens = RecommendationPipeline.splitSubjectTokens(term)
                for token in tokens {
                    guard !token.isEmpty else { continue }
                    insertStatements.append((
                        "INSERT OR IGNORE INTO book_taste (book_id, axis, term) VALUES (?, 'subject', ?)",
                        [.string(bookID), .string(token)]
                    ))
                }
            }
            try await database.executeBatch(insertStatements)
            try? await database.execute("DELETE FROM reco_surfaced")
            defaults.set(true, forKey: flagKey)
            return rows.count
        } catch {
            return 0
        }
    }

    /// Rewrites stale absolute `file://` local URLs (chapters and download
    /// records) whose file is missing but rebases onto the current sandbox
    /// container — iOS moves the app data container on every update, which
    /// breaks stored absolute paths (docs/MINIPLAYER_RESTORE_PLAN.md, Phase D).
    /// Idempotent, and runs once per container move: the marker records the
    /// container identity the last pass ran against. `roots` and the marker
    /// are injectable for tests.
    @discardableResult
    public func rebaseStaleLocalURLsIfNeeded(
        defaults: UserDefaults = .standard,
        roots: [ContainerPathRebase.Root]? = nil,
        containerMarker: String? = nil
    ) async -> Int {
        let markerKey = "voxglass.localURLContainerRebaseV1"
        let marker = containerMarker
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path
            ?? ""
        guard defaults.string(forKey: markerKey) != marker else { return 0 }
        do {
            try await database.prepare()
            var updated = 0
            for table in ["chapters", "download_records"] {
                let rows = try await database.query(
                    "SELECT id, local_url FROM \(table) WHERE local_url IS NOT NULL"
                )
                for row in rows {
                    guard let id = row.string("id"),
                          let raw = row.string("local_url"),
                          let url = URL(string: raw), url.isFileURL else { continue }
                    let rebased = ContainerPathRebase.rebase(url, roots: roots)
                    guard rebased.path != url.path else { continue }
                    try await database.execute(
                        "UPDATE \(table) SET local_url = ? WHERE id = ?",
                        [.string(rebased.absoluteString), .string(id)]
                    )
                    updated += 1
                }
            }

            // Legacy `books.cover_url` rows hold a container-absolute `file://`
            // URL for an app-owned cover (local import / completed narration).
            // Rewrite them to the container-independent relative form, rebasing
            // onto the current container where the old path went stale.
            let coverRows = try await database.query(
                "SELECT id, cover_url FROM books WHERE cover_url LIKE 'file://%'"
            )
            for row in coverRows {
                guard let id = row.string("id"),
                      let raw = row.string("cover_url"),
                      let resolved = LocalArtworkStore.resolve(raw) else { continue }
                let stored = LocalArtworkStore.storedValue(for: resolved)
                guard stored != raw else { continue }
                try await database.execute(
                    "UPDATE books SET cover_url = ? WHERE id = ?",
                    [.string(stored), .string(id)]
                )
                updated += 1
            }

            defaults.set(marker, forKey: markerKey)
            return updated
        } catch {
            return 0
        }
    }

    /// Pure decision: which taste terms a book contributes when it has no
    /// book_taste rows. Usable authors win; otherwise the title seeds a subject
    /// term so played books with placeholder authors stay visible to taste.
    public static func tasteSeedTerms(authors: [String], title: String) -> [(axis: String, term: String)] {
        let placeholders: Set<String> = ["unknown", "unknown author", "various", "internet archive", "local files"]
        let authorTerms = authors
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !placeholders.contains($0.lowercased()) }
            .map { (axis: "author", term: $0.lowercased()) }
        if !authorTerms.isEmpty {
            return authorTerms
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedTitle.isEmpty else { return [] }
        return [(axis: "subject", term: trimmedTitle)]
    }

    /// Returns all taste terms (axis, term) for a given book, for seeding
    /// the taste profile when the book is listened to.
    public func fetchBookTasteTerms(for bookID: UUID) async throws -> [(axis: String, term: String)] {
        try await database.prepare()
        let rows = try await database.query(
            "SELECT axis, term FROM book_taste WHERE book_id = ?",
            [ModelMapping.databaseValue(bookID)]
        )
        return rows.compactMap { row in
            guard let axis = row.string("axis"), let term = row.string("term") else { return nil }
            return (axis, term)
        }
    }

    /// Returns the durable local record for an Internet Archive item. `Book.id`
    /// is the foreign key used by playback positions and bookmarks, so callers
    /// must use this record rather than re-importing an owned item as a preview.
    public func bookWithChapters(forInternetArchiveIdentifier identifier: String) async throws -> BookWithChapters? {
        try await database.prepare()
        guard let contentKey = ContentKey.book(forInternetArchiveIdentifier: identifier) else {
            return nil
        }

        let rows = try await database.query("""
        SELECT b.id
        FROM books b
        JOIN sources s ON s.id = b.source_id
        WHERE b.content_key = ?
           OR s.url = ?
        ORDER BY b.is_pending ASC, b.updated_at DESC
        LIMIT 1
        """, [
            .string(contentKey),
            ModelMapping.databaseValue(InternetArchiveMetadata.detailsURL(for: identifier))
        ])
        if let rawID = rows.first?.string("id"), let bookID = UUID(uuidString: rawID) {
            return try await bookWithChapters(forBookID: bookID)
        }

        switch try await resolveBookByChapterDownloadURLs(identifier: identifier) {
        case .resolved(let bookID):
            return try await bookWithChapters(forBookID: bookID)
        case .ambiguous, .notFound:
            return nil
        }
    }

    public enum ChapterIdentityResolution: Equatable, Sendable {
        case resolved(UUID)
        case notFound
        /// More than one candidate book, or a candidate whose chapter URLs name
        /// several identifiers. Never guessed; surfaced for diagnostics.
        case ambiguous([UUID])
    }

    /// Third-tier strong identity: a single IA identifier parsed from stored
    /// chapter `remote_url` / `opus_url` download paths.
    public func resolveBookByChapterDownloadURLs(identifier: String) async throws -> ChapterIdentityResolution {
        try await database.prepare()
        guard !identifier.isEmpty else { return .notFound }
        let escaped = identifier
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%/download/\(escaped)/%"
        let rows = try await database.query("""
        SELECT DISTINCT book_id FROM chapters
        WHERE remote_url LIKE ? ESCAPE '\\' OR opus_url LIKE ? ESCAPE '\\'
        """, [.string(pattern), .string(pattern)])

        var matching: [UUID] = []
        var conflicting: [UUID] = []
        for row in rows {
            guard let raw = row.string("book_id"), let bookID = UUID(uuidString: raw) else { continue }
            let identifiers = try await chapterDownloadIdentifiers(forBookID: raw)
            if identifiers == [identifier] {
                matching.append(bookID)
            } else if identifiers.contains(identifier) {
                conflicting.append(bookID)
            }
        }
        if matching.count == 1, conflicting.isEmpty, let only = matching.first {
            return .resolved(only)
        }
        let all = matching + conflicting
        return all.isEmpty ? .notFound : .ambiguous(all)
    }

    private func chapterDownloadIdentifiers(forBookID bookID: String) async throws -> Set<String> {
        let rows = try await database.query(
            "SELECT remote_url, opus_url FROM chapters WHERE book_id = ?",
            [.string(bookID)]
        )
        var identifiers = Set<String>()
        for row in rows {
            for column in ["remote_url", "opus_url"] {
                if let url = row.string(column).flatMap(URL.init(string:)),
                   let id = ContentKey.internetArchiveIdentifier(fromDownloadURL: url) {
                    identifiers.insert(id)
                }
            }
        }
        return identifiers
    }

    public func importInternetArchiveItem(
        _ metadata: InternetArchiveMetadata,
        sourceKind: SourceKind
    ) async throws -> BookWithChapters {
        let identifier = metadata.identifier
        guard !identifier.isEmpty else {
            throw InternetArchiveError.missingIdentifier
        }

        // Check durable IA identity before creating a source or a new random
        // Book.id so saved positions/bookmarks stay attached.
        if let existing = try await bookWithChapters(forInternetArchiveIdentifier: identifier) {
            return existing
        }

        let selectedFiles = metadata.selectedAudioFiles
        guard !selectedFiles.isEmpty else {
            throw InternetArchiveError.noPlayableAudio(identifier)
        }

        let source = try await ensureInternetArchiveSource(
            identifier: identifier,
            title: metadata.title,
            sourceKind: sourceKind
        )
        if let existing = try await bookWithChapters(forSourceID: source.id) {
            return existing
        }

        let now = Date()
        var book = Book(
            title: metadata.title,
            authors: metadata.creators.isEmpty ? ["Internet Archive"] : metadata.creators,
            summary: metadata.summary,
            sourceID: source.id,
            coverURL: Self.bestCoverURL(identifier: identifier, metadata: metadata),
            createdAt: now,
            updatedAt: now
        )
        // Build lookup of Opus files by chapter key so we can attach opusURL to each chapter
        let opusFilesByChapter: [String: InternetArchiveFile] = {
            let opusFiles = metadata.files.filter {
                AudioFormatSelection.codec(for: $0.format, filename: $0.name) == .opus
            }
            var dict: [String: InternetArchiveFile] = [:]
            for file in opusFiles {
                let key = InternetArchiveAudioSelector.chapterTitle(for: file)
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
                if dict[key] == nil {
                    dict[key] = file
                }
            }
            return dict
        }()

        var chapters = selectedFiles.enumerated().compactMap { index, file -> Chapter? in
            guard let remoteURL = metadata.fileURL(for: file) else { return nil }
            let chapterTitle = InternetArchiveAudioSelector.chapterTitle(for: file)
            let key = chapterTitle
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
            let opusFile = opusFilesByChapter[key]
            let opusURL = opusFile.flatMap { metadata.fileURL(for: $0) }
            return Chapter(
                bookID: book.id,
                title: chapterTitle,
                sortKey: file.track ?? file.name,
                index: index,
                duration: file.duration,
                remoteURL: remoteURL,
                opusURL: opusURL
            )
        }

        guard !chapters.isEmpty else {
            throw InternetArchiveError.noPlayableAudio(identifier)
        }

        try await enrichNarrators(
            book: &book,
            chapters: &chapters,
            metadata: metadata,
            sourceKind: sourceKind
        )

        try await insert(
            book: book,
            chapters: chapters,
            bookContentKey: ContentKey.book(forInternetArchiveIdentifier: identifier)
        )
        try await insertIdentity(bookID: book.id, scheme: RecordingIdentity.internetArchive, value: identifier)
        if let id = RecordingIdentity.normalizedLibriVoxID(metadata.metadata.callNumber) {
            try await insertIdentity(bookID: book.id, scheme: RecordingIdentity.libriVox, value: id)
        }

        try? await mutationLog?.enqueue(localID: book.id.uuidString, recordType: "Book", changeType: "update")

        // Capture taste metadata for the recommendation engine
        let bookIDString = book.id.uuidString
        for author in metadata.creators {
            let trimmed = author.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed != "Unknown", trimmed != "Various" else { continue }
            try? await database.execute(
                "INSERT OR IGNORE INTO book_taste (book_id, axis, term) VALUES (?, 'author', ?)",
                [.string(bookIDString), .string(trimmed.lowercased())]
            )
        }
        for subject in metadata.metadata.subjects {
            let trimmed = subject.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let tokens = trimmed.contains(";")
                ? RecommendationPipeline.splitSubjectTokens(trimmed)
                : [trimmed.lowercased()]
            for token in tokens {
                guard !token.isEmpty else { continue }
                try? await database.execute(
                    "INSERT OR IGNORE INTO book_taste (book_id, axis, term) VALUES (?, 'subject', ?)",
                    [.string(bookIDString), .string(token)]
                )
            }
        }
        if let language = metadata.metadata.language?.trimmingCharacters(in: .whitespaces), !language.isEmpty {
            try? await database.execute(
                "INSERT OR IGNORE INTO book_taste (book_id, axis, term) VALUES (?, 'language', ?)",
                [.string(bookIDString), .string(language.lowercased())]
            )
        }
        for narrator in book.narrators {
            let trimmed = narrator.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  trimmed.lowercased() != "unknown",
                  trimmed.lowercased() != "various",
                  trimmed.lowercased() != "anonymous",
                  trimmed.lowercased() != "unknown reader" else { continue }
            try? await database.execute(
                "INSERT OR IGNORE INTO book_taste (book_id, axis, term) VALUES (?, 'narrator', ?)",
                [.string(bookIDString), .string(trimmed.lowercased())]
            )
        }

        return BookWithChapters(book: book, chapters: chapters)
    }

    // MARK: - Local folder import (Folder Watch, §4)

    /// Repairs missing, stale, or unresolvable chapter bookmarks while the
    /// caller holds access to `selectedURL` (a watched/picked folder, or a
    /// single audio file). Chapter, book, source, and position identities are
    /// untouched, so no duplicates are created. Paths are canonicalized so
    /// `/var` vs `/private/var` and symlinks still match.
    @discardableResult
    public func repairLocalFileBookmarks(forFolder selectedURL: URL) async throws -> Int {
        try await database.prepare()
        let rows = try await database.query(
            """
            SELECT c.id, c.local_url, c.local_bookmark, s.url AS folder_url
            FROM chapters c
            JOIN books b ON b.id = c.book_id
            JOIN sources s ON s.id = b.source_id
            WHERE s.kind = ? AND c.local_url IS NOT NULL
            """,
            [.string(SourceKind.localFiles.rawValue)]
        )
        let selected = Self.canonicalLocalURL(selectedURL)
        var bookmarkByFile: [URL: Data] = [:]
        var repaired = 0
        for row in rows {
            try Task.checkCancellation()
            guard let id = row.string("id"), let raw = row.string("local_url"),
                  let url = URL(string: raw) else { continue }
            let file = Self.canonicalLocalURL(url)
            let sourceMatches = row.string("folder_url").flatMap { URL(string: $0) }
                .map { Self.canonicalLocalURL($0) == selected } ?? false
            let selectedPath = selected.path.hasSuffix("/") ? selected.path : selected.path + "/"
            guard sourceMatches || file == selected || file.path.hasPrefix(selectedPath) else { continue }
            let existing = ModelMapping.data(row, "local_bookmark")
            if let existing, let resolved = PlaybackSourceResolver.resolveBookmarkData(existing), !resolved.isStale {
                continue
            }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let bookmark: Data
            if let cached = bookmarkByFile[file] {
                bookmark = cached
            } else {
                bookmark = try url.bookmarkData()
                bookmarkByFile[file] = bookmark
            }
            try await database.execute(
                "UPDATE chapters SET local_bookmark = ? WHERE id = ?",
                [ModelMapping.databaseValue(bookmark), .string(id)]
            )
            repaired += 1
        }
        return repaired
    }

    /// Returns the local audio URLs already imported from a watched folder.
    /// Folder Watch uses this before probing durations so a relaunch does not
    /// reopen every existing audio asset just to discard it during the idempotent
    /// import pass.
    public func knownLocalFileURLs(forFolder folderURL: URL) async -> Set<URL> {
        let canonicalFolder = folderURL.resolvingSymlinksInPath()
        do {
            try await database.prepare()
            let rows = try await database.query(
                """
                SELECT c.local_url, s.url AS folder_url
                FROM chapters c
                JOIN books b ON b.id = c.book_id
                JOIN sources s ON s.id = b.source_id
                WHERE s.kind = ? AND c.local_url IS NOT NULL
                """,
                [
                    .string(SourceKind.localFiles.rawValue)
                ]
            )
            return Set(rows.compactMap { row in
                guard let rawFolder = row.string("folder_url"), let storedFolder = URL(string: rawFolder),
                      Self.canonicalLocalURL(storedFolder) == Self.canonicalLocalURL(canonicalFolder),
                      let raw = row.string("local_url"), let url = URL(string: raw) else { return nil }
                return Self.canonicalLocalURL(url)
            })
        } catch {
            return []
        }
    }

    private static func canonicalLocalURL(_ url: URL) -> URL {
        URL(fileURLWithPath: url.path).standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Imports (or re-syncs) a watched folder: one `localFiles` source + one book
    /// per folder, one chapter per audio file. Idempotent — re-scanning only
    /// appends chapters for files not already present, so no duplicates.
    @discardableResult
    public func importLocalFolder(
        folderURL: URL,
        folderName: String,
        files: [LocalAudioImport],
        authors: [String]? = nil,
        narrators: [String]? = nil,
        coverURL: URL? = nil
    ) async throws -> BookWithChapters {
        try await database.prepare()
        let source = try await ensureLocalSource(folderURL: folderURL, title: folderName)

        let existing = try await bookWithChapters(forSourceID: source.id)
        var book: Book
        if let existing {
            book = existing.book
            if let authors, let narrators {
                try await updateBookMetadata(authors: authors, narrators: narrators, for: book.id)
                book.authors = authors
                book.narrators = narrators
            }
            // A re-export/re-import (narrations replace their folder every run)
            // must refresh the cover reference — the old row still pointed at a
            // file the export just removed, so it never picked up new artwork.
            if let coverURL {
                try await setBookCover(bookID: book.id, relativePath: LocalArtworkStore.storedValue(for: coverURL))
                book.coverURL = coverURL
            }
        } else {
            let now = Date()
            book = Book(
                title: folderName,
                authors: authors ?? ["Local Files"],
                narrators: narrators ?? [],
                summary: nil,
                sourceID: source.id,
                coverURL: coverURL,
                createdAt: now,
                updatedAt: now
            )
            try await insert(
                book: book,
                chapters: [],
                bookContentKey: ContentKey.book(forLocalFolderName: folderName)
            )
            try? await mutationLog?.enqueue(localID: book.id.uuidString, recordType: "Book", changeType: "update")
        }

        let knownURLs = Set((existing?.chapters ?? []).compactMap { $0.localURL?.absoluteString })
        let startIndex = existing?.chapters.count ?? 0
        let newFiles = files.filter { !knownURLs.contains($0.url.absoluteString) }

        for (offset, file) in newFiles.enumerated() {
            let chapter = Chapter(
                bookID: book.id,
                title: file.title,
                sortKey: file.sortKey,
                index: startIndex + offset,
                startTime: file.startTime,
                duration: file.duration,
                remoteURL: nil,
                opusURL: nil,
                localURL: file.url,
                localBookmark: file.bookmark
            )
            let chapterKey = ContentKey.chapter(
                remoteURL: nil,
                localURL: file.url,
                index: chapter.index,
                title: file.title
            )
            try await database.execute("""
            INSERT INTO chapters (id, book_id, title, sort_key, chapter_index, start_time_seconds, duration_seconds, remote_url, opus_url, local_url, local_bookmark, narrators_json, content_key)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [
                ModelMapping.databaseValue(chapter.id),
                ModelMapping.databaseValue(chapter.bookID),
                .string(chapter.title),
                .string(chapter.sortKey),
                .int(Int64(chapter.index)),
                .double(chapter.startTime),
                ModelMapping.databaseValue(chapter.duration),
                .null,
                .null,
                ModelMapping.databaseValue(chapter.localURL),
                ModelMapping.databaseValue(chapter.localBookmark),
                .string(ModelMapping.narratorsJSON(chapter.narrators)),
                .string(chapterKey)
            ])
        }

        if !newFiles.isEmpty {
            try? await mutationLog?.enqueue(localID: book.id.uuidString, recordType: "Book", changeType: "update")
        }

        return try await bookWithChapters(forSourceID: source.id)
            ?? BookWithChapters(book: book, chapters: [])
    }

    private func ensureLocalSource(folderURL: URL, title: String) async throws -> Source {
        // `FileManager`'s Application Support URL (what a narration export's
        // folder path is built from) can resolve through `/var/...` on one
        // app launch and `/private/var/...` on another — the same directory,
        // but a different `absoluteString` — so an exact-string dedup lookup
        // here silently missed and created a second `sources` row (and a
        // second book) every time a narration was re-exported in a later
        // session. Canonicalizing before both the lookup and the insert
        // keeps re-exports of the same narration matching the same source.
        let folderURL = folderURL.resolvingSymlinksInPath()
        let existing = try await database.query(
            "SELECT id, kind, title, url, created_at FROM sources WHERE kind = ?",
            [.string(SourceKind.localFiles.rawValue)]
        )
        if let row = existing.first(where: { row in
            guard let raw = row.string("url"), let stored = URL(string: raw) else { return false }
            return Self.canonicalLocalURL(stored) == Self.canonicalLocalURL(folderURL)
        }) {
            return try Self.source(from: row)
        }

        let source = Source(kind: .localFiles, title: title, url: folderURL)
        try await database.execute("""
        INSERT INTO sources (id, kind, title, url, created_at)
        VALUES (?, ?, ?, ?, ?)
        """, [
            ModelMapping.databaseValue(source.id),
            .string(source.kind.rawValue),
            .string(source.title),
            ModelMapping.databaseValue(source.url),
            ModelMapping.databaseValue(source.createdAt)
        ])
        return source
    }

    private func ensureInternetArchiveSource(
        identifier: String,
        title: String,
        sourceKind: SourceKind
    ) async throws -> Source {
        let detailsURL = InternetArchiveMetadata.detailsURL(for: identifier)
        let existing = try await database.query(
            "SELECT id, kind, title, url, created_at FROM sources WHERE url = ? LIMIT 1",
            [ModelMapping.databaseValue(detailsURL)]
        )
        if let row = existing.first {
            return try Self.source(from: row)
        }

        let source = Source(
            kind: sourceKind,
            title: title,
            url: detailsURL
        )
        try await database.execute("""
        INSERT INTO sources (id, kind, title, url, created_at)
        VALUES (?, ?, ?, ?, ?)
        """, [
            ModelMapping.databaseValue(source.id),
            .string(source.kind.rawValue),
            .string(source.title),
            ModelMapping.databaseValue(source.url),
            ModelMapping.databaseValue(source.createdAt)
        ])
        return source
    }

    private func bookWithChapters(forSourceID sourceID: UUID) async throws -> BookWithChapters? {
        let bookRows = try await database.query("""
        SELECT id, title, authors_json, narrators_json, summary, source_id, cover_url, created_at, updated_at, is_favorite, is_pending
        FROM books
        WHERE source_id = ?
        LIMIT 1
        """, [ModelMapping.databaseValue(sourceID)])
        guard let bookRow = bookRows.first else { return nil }

        let book = try Self.book(from: bookRow)
        let chapterRows = try await database.query("""
        SELECT id, book_id, title, sort_key, chapter_index, start_time_seconds, duration_seconds, remote_url, opus_url, local_url, local_bookmark, narrators_json
        FROM chapters
        WHERE book_id = ?
        ORDER BY chapter_index ASC, sort_key COLLATE NOCASE ASC
        """, [ModelMapping.databaseValue(book.id)])
        return BookWithChapters(book: book, chapters: try chapterRows.map(Self.chapter(from:)).naturallySorted())
    }

    func bookWithChapters(forBookID bookID: UUID) async throws -> BookWithChapters? {
        let bookRows = try await database.query("""
        SELECT id, title, authors_json, narrators_json, summary, source_id, cover_url, created_at, updated_at, is_favorite, is_pending
        FROM books
        WHERE id = ?
        LIMIT 1
        """, [ModelMapping.databaseValue(bookID)])
        guard let bookRow = bookRows.first else { return nil }

        let book = try Self.book(from: bookRow)
        let chapterRows = try await database.query("""
        SELECT id, book_id, title, sort_key, chapter_index, start_time_seconds, duration_seconds, remote_url, opus_url, local_url, local_bookmark, narrators_json
        FROM chapters
        WHERE book_id = ?
        ORDER BY chapter_index ASC, sort_key COLLATE NOCASE ASC
        """, [ModelMapping.databaseValue(bookID)])
        return BookWithChapters(book: book, chapters: try chapterRows.map(Self.chapter(from:)).naturallySorted())
    }

    private func downloadedBookIDs() async throws -> Set<UUID> {
        let rows = try await database.query("""
        SELECT DISTINCT book_id
        FROM download_records
        WHERE state IN ('downloaded', 'complete', 'completed') OR local_url IS NOT NULL
        """)
        return Set(try rows.map { try ModelMapping.uuid($0, "book_id") })
    }

    /// Aggregates playback-progress per book. A book is finished only when
    /// *every* chapter has a finished row (Phase 4 — the old `MIN(is_finished)`
    /// over only-positioned chapters marked a book finished off one finished
    /// chapter). Progress is Σ(finished chapter durations) + the current chapter's
    /// offset, not the largest within-chapter offset.
    public func fetchBookProgress() async throws -> [UUID: BookProgress] {
        try await database.prepare()
        let rows = try await database.query("""
        SELECT p.book_id AS book_id,
               SUM(CASE WHEN p.is_finished = 1 THEN 1 ELSE 0 END) AS finished_chapters,
               (SELECT COUNT(*) FROM chapters c WHERE c.book_id = p.book_id) AS total_chapters,
               SUM(CASE WHEN p.is_finished = 1 THEN COALESCE(p.duration_seconds, 0) ELSE 0 END) AS finished_duration,
               COALESCE((
                   SELECT p2.position_seconds FROM playback_positions p2
                   WHERE p2.book_id = p.book_id AND p2.is_finished = 0
                   ORDER BY p2.updated_at DESC LIMIT 1
               ), 0) AS current_offset
        FROM playback_positions p
        GROUP BY p.book_id
        """)
        var result: [UUID: BookProgress] = [:]
        for row in rows {
            let bookID = try ModelMapping.uuid(row, "book_id")
            let finishedChapters = row.int("finished_chapters") ?? 0
            let totalChapters = row.int("total_chapters") ?? 0
            let finishedDuration = row.double("finished_duration") ?? 0
            let currentOffset = row.double("current_offset") ?? 0
            result[bookID] = BookProgress(
                lastPosition: finishedDuration + currentOffset,
                isFinished: totalChapters > 0 && finishedChapters >= totalChapters
            )
        }
        return result
    }

    // MARK: - Download records (offline downloads, §7)

    /// Replaces all download records for a book with a fresh set (used when a
    /// new offline download is enqueued).
    public func replaceDownloadRecords(_ records: [DownloadRecord], forBookID bookID: UUID) async throws {
        try await database.prepare()
        try await database.execute(
            "DELETE FROM download_records WHERE book_id = ?",
            [ModelMapping.databaseValue(bookID)]
        )
        for record in records {
            try await database.execute("""
            INSERT INTO download_records
                (id, book_id, chapter_id, state, local_url, bytes_downloaded, bytes_expected, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, [
                ModelMapping.databaseValue(record.id),
                ModelMapping.databaseValue(record.bookID),
                record.chapterID.map { ModelMapping.databaseValue($0) } ?? .null,
                .string(record.state.rawValue),
                ModelMapping.databaseValue(record.localURL),
                .int(record.bytesDownloaded),
                ModelMapping.databaseValue(record.bytesExpected),
                ModelMapping.databaseValue(record.updatedAt)
            ])
        }
    }

    public func updateDownloadRecord(
        bookID: UUID,
        chapterID: UUID,
        state: DownloadState,
        localURL: URL? = nil,
        bytesDownloaded: Int64? = nil
    ) async throws {
        try await database.prepare()
        try await database.execute("""
        UPDATE download_records
        SET state = ?, local_url = COALESCE(?, local_url),
            bytes_downloaded = COALESCE(?, bytes_downloaded), updated_at = ?
        WHERE book_id = ? AND chapter_id = ?
        """, [
            .string(state.rawValue),
            ModelMapping.databaseValue(localURL),
            ModelMapping.databaseValue(bytesDownloaded),
            ModelMapping.databaseValue(Date()),
            ModelMapping.databaseValue(bookID),
            ModelMapping.databaseValue(chapterID)
        ])
    }

    public func deleteDownloadRecords(forBookID bookID: UUID) async throws {
        try await database.prepare()
        try await database.execute(
            "DELETE FROM download_records WHERE book_id = ?",
            [ModelMapping.databaseValue(bookID)]
        )
    }

    public func fetchDownloadRecords(forBookID bookID: UUID) async throws -> [DownloadRecord] {
        try await database.prepare()
        let rows = try await database.query("""
        SELECT id, book_id, chapter_id, state, local_url, bytes_downloaded, bytes_expected, updated_at
        FROM download_records
        WHERE book_id = ?
        """, [ModelMapping.databaseValue(bookID)])
        return try rows.map(Self.downloadRecord(from:))
    }

    public func fetchAllDownloadRecords() async throws -> [DownloadRecord] {
        try await database.prepare()
        let rows = try await database.query("""
        SELECT id, book_id, chapter_id, state, local_url, bytes_downloaded, bytes_expected, updated_at
        FROM download_records
        """)
        return try rows.map(Self.downloadRecord(from:))
    }

    // MARK: - Narrator enrichment (Phase 4C)

    private func enrichNarrators(
        book: inout Book,
        chapters: inout [Chapter],
        metadata: InternetArchiveMetadata,
        sourceKind: SourceKind
    ) async throws {
        defer {
            if book.narrators.isEmpty {
                book.narrators = NarratorExtractor.extract(from: book.summary ?? metadata.metadata.description)
            }
        }

        guard sourceKind == .librivox,
              let callNumberRaw = metadata.metadata.callNumber,
              let librivoxBookID = Int(callNumberRaw) else { return }

        let client = librivoxClient ?? LibriVoxClient()

        let sections: [LibriVoxSection]
        do {
            sections = try await client.fetchSections(bookID: librivoxBookID)
        } catch {
            return
        }
        guard !sections.isEmpty else { return }

        let chapterNarrators = NarratorMatcher.match(
            chapters: chapters,
            sections: sections,
            archiveIdentifier: metadata.identifier
        )

        if chapterNarrators.isEmpty {
            let bookNarrators = NarratorMatcher.bookLevelNarrators(from: sections)
            if !bookNarrators.isEmpty {
                book.narrators = bookNarrators
            }
        } else {
            for i in chapters.indices {
                chapters[i].narrators = chapterNarrators[chapters[i].id] ?? []
            }
            var seen: Set<String> = []
            var ordered: [String] = []
            for chapter in chapters {
                for name in chapter.narrators {
                    if seen.insert(name).inserted {
                        ordered.append(name)
                    }
                }
            }
            book.narrators = ordered
        }
    }

    public static func bestCoverURL(identifier: String, metadata: InternetArchiveMetadata) -> URL? {
        let primaryURL = InternetArchiveMetadata.coverURL(for: identifier)
        let coverFiles = metadata.coverImageFiles
        if let bestCover = coverFiles.first, let fileURL = metadata.fileURL(for: bestCover) {
            return fileURL
        }
        return primaryURL
    }

    func insert(book: Book, chapters: [Chapter], bookContentKey: String? = nil) async throws {
        try await database.execute("""
        INSERT INTO books (id, title, authors_json, narrators_json, summary, source_id, cover_url, created_at, updated_at, is_favorite, is_pending, content_key)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            ModelMapping.databaseValue(book.id),
            .string(book.title),
            .string(ModelMapping.authorsJSON(book.authors)),
            .string(ModelMapping.narratorsJSON(book.narrators)),
            ModelMapping.databaseValue(book.summary),
            ModelMapping.databaseValue(book.sourceID),
            Self.coverURLValue(book.coverURL),
            ModelMapping.databaseValue(book.createdAt),
            ModelMapping.databaseValue(book.updatedAt),
            .bool(book.isFavorite),
            .bool(book.isPending),
            bookContentKey.map { .string($0) } ?? .null
        ])

        for chapter in chapters {
            let chapterKey = ContentKey.chapter(
                remoteURL: chapter.remoteURL,
                localURL: chapter.localURL,
                index: chapter.index,
                title: chapter.title
            )
            try await database.execute("""
            INSERT INTO chapters (id, book_id, title, sort_key, chapter_index, start_time_seconds, duration_seconds, remote_url, opus_url, local_url, local_bookmark, narrators_json, content_key)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [
                ModelMapping.databaseValue(chapter.id),
                ModelMapping.databaseValue(chapter.bookID),
                .string(chapter.title),
                .string(chapter.sortKey),
                .int(Int64(chapter.index)),
                .double(chapter.startTime),
                ModelMapping.databaseValue(chapter.duration),
                ModelMapping.databaseValue(chapter.remoteURL),
                ModelMapping.databaseValue(chapter.opusURL),
                ModelMapping.databaseValue(chapter.localURL),
                ModelMapping.databaseValue(chapter.localBookmark),
                .string(ModelMapping.narratorsJSON(chapter.narrators)),
                .string(chapterKey)
            ])
        }
    }

    private static func source(from row: DatabaseRow) throws -> Source {
        Source(
            id: try ModelMapping.uuid(row, "id"),
            kind: SourceKind(rawValue: try row.requiredString("kind")) ?? .localFiles,
            title: try row.requiredString("title"),
            url: ModelMapping.url(row, "url"),
            createdAt: ModelMapping.date(row, "created_at")
        )
    }

    private static func book(from row: DatabaseRow) throws -> Book {
        Book(
            id: try ModelMapping.uuid(row, "id"),
            title: try row.requiredString("title"),
            authors: ModelMapping.authors(from: row),
            narrators: ModelMapping.narrators(from: row),
            summary: row.string("summary"),
            sourceID: try ModelMapping.uuid(row, "source_id"),
            coverURL: row.string("cover_url").flatMap { LocalArtworkStore.resolve($0) },
            createdAt: ModelMapping.date(row, "created_at"),
            updatedAt: ModelMapping.date(row, "updated_at"),
            isFavorite: row.bool("is_favorite") ?? false,
            isPending: row.bool("is_pending") ?? false
        )
    }

    private static func exclusionKeys(forContentKey contentKey: String) -> Set<String> {
        let trimmed = contentKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var keys: Set<String> = [trimmed]
        if trimmed.hasPrefix("ia:") {
            let identifier = String(trimmed.dropFirst(3))
            if !identifier.isEmpty {
                keys.insert(identifier)
            }
        }
        return keys
    }

    private static func chapter(from row: DatabaseRow) throws -> Chapter {
        Chapter(
            id: try ModelMapping.uuid(row, "id"),
            bookID: try ModelMapping.uuid(row, "book_id"),
            title: try row.requiredString("title"),
            sortKey: try row.requiredString("sort_key"),
            index: Int(row.int("chapter_index") ?? 0),
            startTime: row.double("start_time_seconds") ?? 0,
            duration: row.double("duration_seconds"),
            remoteURL: ModelMapping.url(row, "remote_url"),
            opusURL: ModelMapping.url(row, "opus_url"),
            localURL: ModelMapping.url(row, "local_url"),
            localBookmark: ModelMapping.data(row, "local_bookmark"),
            narrators: ModelMapping.narrators(from: row)
        )
    }

    private static func downloadRecord(from row: DatabaseRow) throws -> DownloadRecord {
        DownloadRecord(
            id: try ModelMapping.uuid(row, "id"),
            bookID: try ModelMapping.uuid(row, "book_id"),
            chapterID: row.string("chapter_id").flatMap(UUID.init(uuidString:)),
            state: DownloadState(rawValue: try row.requiredString("state")) ?? .queued,
            localURL: ModelMapping.url(row, "local_url"),
            bytesDownloaded: row.int("bytes_downloaded") ?? 0,
            bytesExpected: row.int("bytes_expected"),
            updatedAt: ModelMapping.date(row, "updated_at")
        )
    }
}
