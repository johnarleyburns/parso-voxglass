import Foundation

struct TasteTerm: Equatable {
    let axis: String
    let term: String
    let weight: Double
}

struct ProfileBucket: Equatable {
    let bucket: String
    let creatorTerms: [TasteTerm]
    let subjectTerms: [TasteTerm]

    var topCreators: [String] { creatorTerms.prefix(5).map(\.term) }
    var topSubjects: [String] { subjectTerms.prefix(8).map(\.term) }

    var isEmpty: Bool { creatorTerms.isEmpty && subjectTerms.isEmpty }

    func allTerms() -> [TasteTerm] { creatorTerms + subjectTerms }
}

actor TasteProfileStore {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func hasProfile() async -> Bool {
        let terms = try? await fetchTerms()
        return !(terms ?? []).isEmpty
    }

    // MARK: - Upsert terms (decay update)

    func upsertTerm(axis: String, term: String, increment: Double) async {
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

    func seedAuthor(_ author: String, increment: Double = 1.0) async {
        let trimmed = author.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "Unknown", trimmed != "Unknown author", trimmed != "Various" else {
            return
        }
        await upsertTerm(axis: "author", term: trimmed, increment: increment)
    }

    func seedSubject(_ subject: String, increment: Double = 1.0) async {
        let trimmed = subject.lowercased().trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !RecommendationConstants.subjectStopList.contains(trimmed) else {
            return
        }
        await upsertTerm(axis: "subject", term: trimmed, increment: increment)
    }

    func seedLanguage(_ language: String, increment: Double = 1.0) async {
        let trimmed = language.lowercased().trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        await upsertTerm(axis: "language", term: trimmed, increment: increment)
    }

    func seedOnboardingPicks(from collectionIDs: Set<String>) async {
        for id in collectionIDs {
            await upsertTerm(axis: "subject", term: id.lowercased(),
                             increment: RecommendationConstants.onboardingSeedWeight)
        }
    }

    // MARK: - Profile read (with subject dampening)

    func fetchProfile() async -> ProfileBucket {
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

    func pushSurfaced(_ identifiers: [String]) async {
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

    func fetchSurfacedIdentifiers() async -> Set<String> {
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
}
