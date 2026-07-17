import Foundation

public struct TasteTerm: Equatable {
    public let axis: String
    public let term: String
    public let weight: Double
}

public struct ProfileBucket: Equatable {
    public let bucket: String
    public let creatorTerms: [TasteTerm]
    public let subjectTerms: [TasteTerm]
    public let languageTerms: [TasteTerm]

    public init(
        bucket: String,
        creatorTerms: [TasteTerm],
        subjectTerms: [TasteTerm],
        languageTerms: [TasteTerm] = []
    ) {
        self.bucket = bucket
        self.creatorTerms = creatorTerms
        self.subjectTerms = subjectTerms
        self.languageTerms = languageTerms
    }

    public var topCreators: [String] { creatorTerms.prefix(5).map(\.term) }
    public var topSubjects: [String] { subjectTerms.prefix(8).map(\.term) }

    public var isEmpty: Bool { creatorTerms.isEmpty && subjectTerms.isEmpty && languageTerms.isEmpty }

    public func allTerms() -> [TasteTerm] { creatorTerms + subjectTerms + languageTerms }
}

public actor TasteProfileStore {
    public static let listeningHistoryRebuildVersion = 2

    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func hasProfile() async -> Bool {
        let terms = try? await fetchTerms()
        return !(terms ?? []).isEmpty
    }

    // MARK: - Upsert terms (decay update)

    public func upsertTerm(axis: String, term: String, increment: Double) async {
        let now = Date().timeIntervalSince1970
        do {
            try await database.execute("""
            INSERT INTO taste_profile_terms (axis, term, weight, last_ts)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(axis, term) DO UPDATE SET
                weight = weight * exp(-(excluded.last_ts - last_ts) / ?) + excluded.weight,
                last_ts = excluded.last_ts
            """, [
                .string(axis),
                .string(term.lowercased()),
                .double(increment),
                .double(now),
                .double(RecommendationConstants.tau)
            ])
        } catch {}
    }

    public func seedAuthor(_ author: String, increment: Double = 1.0) async {
        let trimmed = author.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "Unknown", trimmed != "Unknown author", trimmed != "Various" else {
            return
        }
        await upsertTerm(axis: "author", term: trimmed, increment: increment)
    }

    public func seedSubject(_ subject: String, increment: Double = 1.0) async {
        let trimmed = subject.lowercased().trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !RecommendationConstants.subjectStopList.contains(trimmed) else {
            return
        }
        await upsertTerm(axis: "subject", term: trimmed, increment: increment)
    }

    public func seedLanguage(_ language: String, increment: Double = 1.0) async {
        let trimmed = language.lowercased().trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        await upsertTerm(axis: "language", term: trimmed, increment: increment)
    }

    // MARK: - Live signal capture (thresholded, delta-based)

    @discardableResult
    public func applySignal(
        _ signal: PlaybackTasteSignal,
        terms: [(axis: String, term: String)]
    ) async -> Bool {
        let completion: Double
        if signal.isFinished {
            completion = 1.0
        } else {
            guard let duration = signal.duration, duration > 0 else { return false }
            completion = min(max(signal.position / duration, 0), 1)
        }
        guard signal.isFinished
                || completion >= RecommendationConstants.meaningfulListenCompletion else {
            return false
        }

        var targetIncrement = max(RecommendationConstants.minListenIncrement, completion)
        if signal.isFavorite {
            targetIncrement *= RecommendationConstants.favoriteBoost
        }

        do {
            try await database.prepare()
            let rows = try await database.query(
                "SELECT max_completion, applied_increment FROM taste_signal_state WHERE book_id = ?",
                [ModelMapping.databaseValue(signal.bookID)]
            )
            let priorCompletion = rows.first?.double("max_completion") ?? 0
            let appliedIncrement = rows.first?.double("applied_increment") ?? 0

            let delta = targetIncrement - appliedIncrement
            guard delta > 0.0001 else { return false }

            for (axis, term) in terms {
                await upsertTerm(axis: axis, term: term, increment: delta)
            }

            let now = Date().timeIntervalSince1970
            try await database.execute("""
            INSERT INTO taste_signal_state (book_id, max_completion, applied_increment, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(book_id) DO UPDATE SET
                max_completion = excluded.max_completion,
                applied_increment = excluded.applied_increment,
                updated_at = excluded.updated_at
            """, [
                ModelMapping.databaseValue(signal.bookID),
                .double(max(priorCompletion, completion)),
                .double(targetIncrement),
                .double(now)
            ])
            return true
        } catch {
            return false
        }
    }

    public func rebuildFromListeningHistory(
        version: Int = TasteProfileStore.listeningHistoryRebuildVersion,
        selectedCollectionIDs: Set<String> = []
    ) async {
        guard version > 0 else { return }
        do {
            try await database.prepare()

            let entries = try await buildListeningHistoryEntries()

            let weights = RecommendationPipeline.termWeights(
                history: entries,
                onboardingSelectionIDs: selectedCollectionIDs
            )

            let now = Date().timeIntervalSince1970
            try await database.executeRaw("BEGIN IMMEDIATE TRANSACTION")
            do {
                try await database.execute("DELETE FROM taste_profile_terms")
                let sorted = weights.sorted {
                    if $0.axis != $1.axis { return $0.axis < $1.axis }
                    return $0.term < $1.term
                }
                for entry in sorted {
                    try await database.execute("""
                    INSERT INTO taste_profile_terms (axis, term, weight, last_ts)
                    VALUES (?, ?, ?, ?)
                    """, [
                        .string(entry.axis),
                        .string(entry.term),
                        .double(entry.weight),
                        .double(now)
                    ])
                }
                try await database.executeRaw("COMMIT")
            } catch {
                try? await database.executeRaw("ROLLBACK")
                throw error
            }
        } catch {}
    }

    public func seedFromHistory() async {
        await rebuildFromListeningHistory(version: Self.listeningHistoryRebuildVersion)
    }

    public func seedOnboardingPicks(from collectionIDs: Set<String>) async {
        for seed in OnboardingTasteSeeds.seeds(for: collectionIDs) {
            await upsertTerm(axis: seed.axis, term: seed.term, increment: seed.weight)
        }
    }

    // MARK: - Profile read (with subject dampening)

    public func fetchProfile() async -> ProfileBucket {
        let rawTerms = await fetchRawTerms()
        let termWeights = rawTerms.map { TermWeight(axis: $0.axis, term: $0.term, weight: $0.weight) }
        return RecommendationPipeline.profile(fromRawTerms: termWeights)
    }

    // MARK: - Surfaced ring

    public func pushSurfaced(_ identifiers: [String]) async {
        let now = Date().timeIntervalSince1970
        do {
            for id in identifiers.prefix(50) {
                try? await database.execute("""
                INSERT OR REPLACE INTO reco_surfaced (identifier, ts)
                VALUES (?, ?)
                """, [.string(id), .double(now)])
            }
            try? await database.execute("""
            DELETE FROM reco_surfaced WHERE rowid NOT IN (
                SELECT rowid FROM reco_surfaced ORDER BY ts DESC LIMIT ?
            )
            """, [.int(Int64(RecommendationConstants.recoSurfacedCap))])
        }
    }

    public func fetchSurfacedIdentifiers() async -> Set<String> {
        do {
            let rows = try await database.query(
                "SELECT identifier FROM reco_surfaced ORDER BY ts DESC LIMIT ?",
                [.int(Int64(RecommendationConstants.recoSurfacedCap))]
            )
            return Set(rows.compactMap { $0.string("identifier") })
        } catch {
            return []
        }
    }

    // MARK: - Private

    private struct RawTerm {
        let axis: String
        let term: String
        let weight: Double
    }

    private func fetchRawTerms() async -> [RawTerm] {
        do {
            try await database.prepare()
            let rows = try await database.query("""
            SELECT axis, term, weight FROM taste_profile_terms
            WHERE axis IN ('author', 'subject', 'language')
            ORDER BY weight DESC
            LIMIT 200
            """)
            return rows.compactMap { row in
                guard let axis = row.string("axis"),
                      let term = row.string("term"),
                      let weight = row.double("weight") else { return nil }
                return RawTerm(axis: axis, term: term, weight: weight)
            }
        } catch {
            return []
        }
    }

    private func fetchTerms() async throws -> [RawTerm] {
        try await database.prepare()
        let rows = try await database.query("""
        SELECT axis, term, weight FROM taste_profile_terms
        ORDER BY weight DESC
        LIMIT 200
        """)
        return rows.compactMap { row in
            guard let axis = row.string("axis"),
                  let term = row.string("term"),
                  let weight = row.double("weight") else { return nil }
            return RawTerm(axis: axis, term: term, weight: weight)
        }
    }

    private func buildListeningHistoryEntries() async throws -> [ListeningHistoryEntry] {
        let rows = try await database.query("""
        SELECT bt.book_id AS book_id,
               bt.axis AS axis,
               bt.term AS term,
               CASE
                   WHEN COALESCE(le.event_count, 0) > 0 THEN COALESCE(le.total_seconds, 0)
                   ELSE COALESCE(pp.total_seconds, 0)
               END AS listened_seconds,
               COALESCE(tss.applied_increment, 0) AS applied_increment,
               COALESCE(b.is_favorite, 0) AS is_favorite
        FROM book_taste bt
        JOIN books b ON b.id = bt.book_id
        LEFT JOIN (
            SELECT book_id, COUNT(*) AS event_count, SUM(seconds) AS total_seconds
            FROM listening_events
            WHERE book_id IS NOT NULL
            GROUP BY book_id
        ) le ON le.book_id = bt.book_id
        LEFT JOIN (
            SELECT book_id,
                   SUM(
                       CASE
                           WHEN is_finished = 1 AND duration_seconds IS NOT NULL AND duration_seconds > 0
                               THEN duration_seconds
                           WHEN duration_seconds IS NOT NULL AND duration_seconds > 0
                               THEN MIN(MAX(position_seconds, 0), duration_seconds)
                           ELSE MAX(position_seconds, 0)
                       END
                   ) AS total_seconds
            FROM playback_positions
            GROUP BY book_id
        ) pp ON pp.book_id = bt.book_id
        LEFT JOIN taste_signal_state tss ON tss.book_id = bt.book_id
        WHERE bt.axis IN ('author', 'subject', 'language')
          AND (
              COALESCE(le.event_count, 0) > 0
              OR COALESCE(pp.total_seconds, 0) > 0
              OR COALESCE(tss.applied_increment, 0) > 0
              OR COALESCE(b.is_favorite, 0) = 1
          )
        """)

        var groups: [String: (listened: Double, signal: Double, favorite: Bool, authors: Set<String>, subjects: Set<String>, langs: Set<String>)] = [:]

        for row in rows {
            guard let bookID = row.string("book_id"),
                  let axis = row.string("axis"),
                  let term = row.string("term") else { continue }
            var entry = groups[bookID] ?? (listened: 0, signal: 0, favorite: false, authors: [], subjects: [], langs: [])
            entry.listened = row.double("listened_seconds") ?? 0
            entry.signal = row.double("applied_increment") ?? 0
            entry.favorite = entry.favorite || (row.bool("is_favorite") ?? false)
            let lowerTerm = term.lowercased().trimmingCharacters(in: .whitespaces)
            switch axis.lowercased() {
            case "author": entry.authors.insert(lowerTerm)
            case "subject": entry.subjects.insert(lowerTerm)
            case "language": entry.langs.insert(lowerTerm)
            default: continue
            }
            groups[bookID] = entry
        }

        return groups.map { _, entry in
            ListeningHistoryEntry(
                authors: Array(entry.authors),
                subjects: Array(entry.subjects),
                languages: Array(entry.langs),
                listenedSeconds: entry.listened,
                capturedSignalIncrement: entry.signal,
                isFavorite: entry.favorite
            )
        }
    }
}
