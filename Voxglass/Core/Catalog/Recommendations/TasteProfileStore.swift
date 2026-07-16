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

    public var topCreators: [String] { creatorTerms.prefix(5).map(\.term) }
    public var topSubjects: [String] { subjectTerms.prefix(8).map(\.term) }

    public var isEmpty: Bool { creatorTerms.isEmpty && subjectTerms.isEmpty }

    public func allTerms() -> [TasteTerm] { creatorTerms + subjectTerms }
}

public actor TasteProfileStore {
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
                weight = weight * exp(-(\(now) - last_ts) / ?) + excluded.weight,
                last_ts = \(now)
            """, [
                .string(axis),
                .string(term.lowercased()),
                .double(increment),
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

    /// One-time backfill of the taste profile from pre-existing listening history.
    /// The forward signal (`upsertTerm` on position save) is forward-only, so any
    /// listening that happened before that wiring — or before this profile was
    /// rebuilt — never shaped the shelf. This rebuilds it from the authoritative
    /// `listening_events ⋈ book_taste` join, weighting each (author/subject) term
    /// by how long the user actually listened. Callers gate this behind a run-once
    /// flag so it never double-counts.
    public func seedFromHistory() async {
        do {
            try await database.prepare()
            let rows = try await database.query("""
            SELECT bt.axis AS axis, bt.term AS term, SUM(le.seconds) AS total
            FROM listening_events le
            JOIN book_taste bt ON bt.book_id = le.book_id
            WHERE le.book_id IS NOT NULL AND bt.axis IN ('author', 'subject')
            GROUP BY bt.axis, bt.term
            """)
            for row in rows {
                guard let axis = row.string("axis"),
                      let term = row.string("term"),
                      let seconds = row.double("total"), seconds > 0 else { continue }
                await upsertTerm(axis: axis, term: term, increment: Self.historyIncrement(forSeconds: seconds))
            }
        } catch {}
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
            default: break
            }
        }

        authors.sort { $0.weight > $1.weight }
        subjects.sort { $0.weight > $1.weight }

        return ProfileBucket(bucket: "audiobooks", creatorTerms: authors, subjectTerms: subjects)
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
            WHERE axis IN ('author', 'subject')
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
}
