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

    public func hasMeaningfulProfile() async -> Bool {
        if await hasDurableTasteSignal() {
            return true
        }

        // Legacy upgrades may have useful profile rows without the newer
        // `taste_signal_state` table populated. Onboarding only seeds subjects,
        // so author/language terms are treated as meaningful legacy profile data.
        do {
            try await database.prepare()
            let rows = try await database.query("""
            SELECT 1 AS found FROM taste_profile_terms
            WHERE axis IN ('author', 'language') AND weight > 0
            LIMIT 1
            """)
            return !rows.isEmpty
        } catch {
            return false
        }
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

    /// Applies a live playback taste signal using per-book delta calibration so
    /// periodic saves never over-count. The target increment is derived from the
    /// listen completion (favorite-boosted); only the positive delta beyond what
    /// this book has already contributed is applied to its taste terms, with the
    /// running state persisted in `taste_signal_state`.
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

        var targetIncrement = max(0.5, completion)
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

    /// Rebuilds the profile from durable local taste sources. This is safe to run
    /// repeatedly: it clears the derived table, recomputes history from
    /// `listening_events JOIN book_taste`, folds in captured playback-signal
    /// state, and then reapplies onboarding seeds from the current preferences.
    public func rebuildFromListeningHistory(
        version: Int = TasteProfileStore.listeningHistoryRebuildVersion,
        selectedCollectionIDs: Set<String> = []
    ) async {
        guard version > 0 else { return }
        do {
            try await database.prepare()
            var weights: [TermKey: Double] = [:]

            let rows = try await database.query("""
            SELECT bt.book_id AS book_id,
                   bt.axis AS axis,
                   bt.term AS term,
                   COALESCE(le.total_seconds, 0) AS listened_seconds,
                   COALESCE(tss.applied_increment, 0) AS applied_increment,
                   COALESCE(b.is_favorite, 0) AS is_favorite
            FROM book_taste bt
            JOIN books b ON b.id = bt.book_id
            LEFT JOIN (
                SELECT book_id, SUM(seconds) AS total_seconds
                FROM listening_events
                WHERE book_id IS NOT NULL
                GROUP BY book_id
            ) le ON le.book_id = bt.book_id
            LEFT JOIN taste_signal_state tss ON tss.book_id = bt.book_id
            WHERE bt.axis IN ('author', 'subject', 'language')
              AND (
                  COALESCE(le.total_seconds, 0) > 0
                  OR COALESCE(tss.applied_increment, 0) > 0
                  OR COALESCE(b.is_favorite, 0) = 1
              )
            """)
            for row in rows {
                guard let axis = row.string("axis"),
                      let term = row.string("term"),
                      let normalized = Self.normalizedTerm(axis: axis, term: term) else { continue }
                let normalizedAxis = axis.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                let listenedSeconds = row.double("listened_seconds") ?? 0
                let historyWeight = listenedSeconds > 0
                    ? Self.historyIncrement(forSeconds: listenedSeconds)
                    : 0
                let signalWeight = row.double("applied_increment") ?? 0
                let favoriteWeight = (row.bool("is_favorite") ?? false)
                    ? RecommendationConstants.favoriteBoost
                    : 0
                let contribution = max(historyWeight, signalWeight, favoriteWeight)
                guard contribution > 0 else { continue }
                weights[TermKey(axis: normalizedAxis, term: normalized), default: 0] += contribution
            }

            for id in selectedCollectionIDs.sorted() {
                guard let category = LibriVoxBrowseCategory.category(withID: id) else { continue }
                for subject in category.representativeSubjects {
                    guard let normalized = Self.normalizedTerm(axis: "subject", term: subject) else { continue }
                    weights[TermKey(axis: "subject", term: normalized), default: 0] += RecommendationConstants.onboardingSeedWeight
                }
            }

            let now = Date().timeIntervalSince1970
            try await database.executeRaw("BEGIN IMMEDIATE TRANSACTION")
            do {
                try await database.execute("DELETE FROM taste_profile_terms")
                for entry in weights.sorted(by: { lhs, rhs in
                    lhs.key.axis == rhs.key.axis
                        ? lhs.key.term < rhs.key.term
                        : lhs.key.axis < rhs.key.axis
                }) {
                    try await database.execute("""
                    INSERT INTO taste_profile_terms (axis, term, weight, last_ts)
                    VALUES (?, ?, ?, ?)
                    """, [
                        .string(entry.key.axis),
                        .string(entry.key.term),
                        .double(entry.value),
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

    /// Compatibility wrapper for callers/tests still using the old name. The new
    /// implementation is idempotent and includes author, subject, and language.
    public func seedFromHistory() async {
        await rebuildFromListeningHistory(version: Self.listeningHistoryRebuildVersion)
    }

    /// Converts listened seconds into a profile increment: weighted by hours
    /// listened, floored so any genuine listen registers, and capped so a single
    /// very long book cannot swamp the profile.
    public static func historyIncrement(forSeconds seconds: Double) -> Double {
        let hours = seconds / 3600.0
        return min(12.0, max(0.5, hours))
    }

    public func seedOnboardingPicks(from collectionIDs: Set<String>) async {
        for id in collectionIDs {
            // Onboarding stores browse-collection IDs (e.g. "lv-drama-plays").
            // Seeding those raw IDs as subject terms builds `subject:"lv-drama-plays"`
            // queries that match zero archive.org items yet outweigh real listens.
            // Instead, map each ID to its category's real archive subjects and seed
            // those, so query generation produces matching subject queries.
            guard let category = LibriVoxBrowseCategory.category(withID: id) else { continue }
            for subject in category.representativeSubjects {
                await seedSubject(subject, increment: RecommendationConstants.onboardingSeedWeight)
            }
        }
    }

    // MARK: - Profile read (with subject dampening)

    public func fetchProfile() async -> ProfileBucket {
        let rawTerms = await fetchRawTerms()
        var authors: [TasteTerm] = []
        var subjects: [TasteTerm] = []
        var languages: [TasteTerm] = []

        let subjectWeights = rawTerms.filter { $0.axis == "subject" }
        let distinctSubjectCount = Set(subjectWeights.map(\.term)).count
        let subjectDampDivisor = distinctSubjectCount > 0
            ? 1.0 + log(Double(distinctSubjectCount) + 1.0)
            : 1.0

        for t in rawTerms {
            var weight = t.weight
            if t.axis == "subject" {
                // Belt-and-suspenders: drop legacy onboarding terms that stored a
                // collection ID (e.g. "lv-drama-plays", "great-books") as a subject.
                // These never match archive.org and would otherwise dominate.
                if Self.isCollectionLikeSubject(t.term) {
                    continue
                }
                if RecommendationConstants.subjectStopList.contains(t.term) {
                    weight *= 0.05
                } else {
                    weight /= subjectDampDivisor
                }
            }
            let term = TasteTerm(axis: t.axis, term: t.term, weight: weight)
            switch t.axis {
            case "author": authors.append(term)
            case "subject": subjects.append(term)
            case "language": languages.append(term)
            default: break
            }
        }

        authors.sort { $0.weight > $1.weight }
        subjects.sort { $0.weight > $1.weight }
        languages.sort { $0.weight > $1.weight }

        return ProfileBucket(
            bucket: "audiobooks",
            creatorTerms: authors,
            subjectTerms: subjects,
            languageTerms: languages
        )
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

    private struct TermKey: Hashable {
        let axis: String
        let term: String
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

    private func hasDurableTasteSignal() async -> Bool {
        do {
            try await database.prepare()
            let rows = try await database.query("""
            SELECT 1 AS found
            FROM listening_events
            WHERE book_id IS NOT NULL AND seconds > 0
            UNION ALL
            SELECT 1 AS found
            FROM taste_signal_state
            WHERE applied_increment > 0
            UNION ALL
            SELECT 1 AS found
            FROM books
            WHERE is_favorite = 1
            LIMIT 1
            """)
            return !rows.isEmpty
        } catch {
            return false
        }
    }

    // MARK: - Legacy collection-id guard

    /// Known onboarding collection IDs (including curated) — any subject term
    /// that exactly matches one of these (or begins with `lv-`) is a legacy
    /// onboarding artefact, not a real archive.org subject, and must be dropped.
    private static let knownCollectionIDs: Set<String> = {
        var ids = Set(LibriVoxBrowseGroup.categories.map(\.id))
        ids.insert("popular-librivox")
        ids.insert("great-books")
        ids.insert("greater-books")
        ids.insert("ancient-greece")
        ids.insert("librivoxaudio")
        return ids
    }()

    private static func isCollectionLikeSubject(_ term: String) -> Bool {
        knownCollectionIDs.contains(term) || term.hasPrefix("lv-")
    }

    private static func normalizedTerm(axis rawAxis: String, term rawTerm: String) -> String? {
        let axis = rawAxis.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let term = rawTerm.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !axis.isEmpty, !term.isEmpty else { return nil }

        switch axis {
        case "author":
            guard term != "unknown", term != "unknown author", term != "various" else { return nil }
            return term
        case "subject":
            guard !RecommendationConstants.subjectStopList.contains(term),
                  !isCollectionLikeSubject(term) else { return nil }
            return term
        case "language":
            return term
        default:
            return nil
        }
    }
}
