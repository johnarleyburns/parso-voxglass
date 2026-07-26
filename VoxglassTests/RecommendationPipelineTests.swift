import Testing
@testable import VoxglassCore

@Suite struct RecommendationPipelineTests {

    // MARK: - Empty everything

    @Test func emptyEverythingReturnsBundledPopularSeeds() {
        let recs = RecommendationPipeline.recommendations(
            history: [],
            onboardingSelectionIDs: [],
            candidates: []
        )
        let seedIDs = Set(HomeRecommendationStore.bundledPopularSeeds.map(\.identifier))
        #expect(!(recs.isEmpty))
        #expect(recs.allSatisfy { seedIDs.contains($0.identifier) })  // All recommendations should be from bundled popular seeds
    }

    @Test func emptyEverythingExcludesGivenKeys() {
        let excludeKeys: Set<String> = ["pride_and_prejudice_librivox", "ia:pride_and_prejudice_librivox"]
        let recs = RecommendationPipeline.recommendations(
            history: [],
            onboardingSelectionIDs: [],
            candidates: [],
            excludeKeys: excludeKeys
        )
        #expect(!(recs.contains { $0.identifier == "pride_and_prejudice_librivox" }))
        #expect(!(recs.isEmpty))
    }

    // MARK: - Early listener, one meaningful listen

    @Test func oneMeaningfulListenTopsProfile() {
        let entry = ListeningHistoryEntry(
            authors: ["Mary Shelley"],
            subjects: ["Gothic Fiction"],
            listenedSeconds: 7200
        )
        let profile = RecommendationPipeline.buildProfile(history: [entry])
        #expect(!(profile.isEmpty))
        #expect(profile.topCreators.first == "mary shelley")
    }

    @Test func oneMeaningfulListenGeneratesExploitQuery() {
        let entry = ListeningHistoryEntry(
            authors: ["Aristophanes"],
            subjects: ["Drama"],
            listenedSeconds: 7200
        )
        let profile = RecommendationPipeline.buildProfile(history: [entry])
        let queries = RecommendationQueryBuilder.generateQueries(
            profile: profile,
            dateSeed: "2026-01-01",
            languageClause: ""
        )
        #expect(queries.contains { $0.iaQuery.contains("creator:\"aristophanes\"") })
    }

    @Test func oneMeaningfulListenBeatsBundledFallback() {
        let entry = ListeningHistoryEntry(
            authors: ["Mary Shelley"],
            subjects: ["Gothic Fiction"],
            listenedSeconds: 7200
        )
        let matched = candidate("match", "Frankenstein", "Mary Shelley", subjects: ["Gothic Fiction"])
        let recs = RecommendationPipeline.recommendations(
            history: [entry],
            onboardingSelectionIDs: [],
            candidates: [matched, candidate("other", "Other Book", "Someone Else")]
        )
        #expect(!(recs.isEmpty))
        #expect(!(recs.map(\.identifier) == HomeRecommendationStore.bundledPopularSeeds.map(\.identifier)))
        #expect(recs.contains { $0.identifier == "match" })
    }

    // MARK: - One listen + onboarding

    @Test func listenedAuthorOutranksOnboardingAuthors() {
        let entry = ListeningHistoryEntry(
            authors: ["Jane Austen"],
            subjects: ["Romance"],
            listenedSeconds: 1800 // 30 min -> floors at minListenIncrement
        )
        let profile = RecommendationPipeline.buildProfile(
            history: [entry],
            onboardingSelectionIDs: ["great-books"]
        )
        let creators = profile.creatorTerms
        #expect(!(creators.isEmpty))
        let janeAusten = creators.first { $0.term == "jane austen" }
        let onboardingAuthors = creators.filter { $0.weight == RecommendationConstants.onboardingAuthorSeedWeight }
        if let ja = janeAusten {
            for oa in onboardingAuthors {
                #expect(ja.weight > oa.weight)
            }
        }
    }

    // MARK: - Onboarding-only

    @Test func onboardingOnlyBrowsePickProducesNonEmptyProfile() {
        let profile = RecommendationPipeline.buildProfile(
            history: [],
            onboardingSelectionIDs: ["lv-mystery-crime"]
        )
        #expect(!(profile.isEmpty))
        #expect(!(profile.subjectTerms.isEmpty))
    }

    @Test func onboardingOnlyCuratedPickProducesNonEmptyProfile() {
        let profile = RecommendationPipeline.buildProfile(
            history: [],
            onboardingSelectionIDs: ["great-books"]
        )
        #expect(!(profile.isEmpty))
        #expect(!(profile.creatorTerms.isEmpty))
    }

    @Test func popularLibrivoxOnlyOnboardingProducesEmptyProfile() {
        let profile = RecommendationPipeline.buildProfile(
            history: [],
            onboardingSelectionIDs: ["popular-librivox"]
        )
        #expect(profile.isEmpty)
    }

    // MARK: - Long-time listener shape

    @Test func longTimeListenerProfileOrdersCorrectly() {
        let finished1 = ListeningHistoryEntry(
            authors: ["Homer"],
            subjects: ["Epic Poetry"],
            languages: ["eng"],
            listenedSeconds: 28800 // 8h
        )
        let finished2 = ListeningHistoryEntry(
            authors: ["Plato"],
            subjects: ["Philosophy"],
            languages: ["eng"],
            listenedSeconds: 28800 // 8h
        )
        let mostlyFinished = ListeningHistoryEntry(
            authors: ["Sophocles"],
            subjects: ["Drama"],
            languages: ["eng"],
            listenedSeconds: 25200 // 70% of 10h
        )
        let barelyTouched = (0..<9).map { i in
            ListeningHistoryEntry(
                authors: ["Author\(i)"],
                subjects: ["Subject\(i)"],
                listenedSeconds: 300
            )
        }
        let allEntries = [finished1, finished2, mostlyFinished] + barelyTouched

        let profile = RecommendationPipeline.buildProfile(
            history: allEntries,
            onboardingSelectionIDs: ["great-books"]
        )

        let top3 = profile.topCreators.prefix(3)
        #expect(top3.contains("homer"))
        #expect(top3.contains("plato"))
        #expect(top3.contains("sophocles"))
    }

    @Test func longTimeListenerRecommendationsExcludeListened() {
        let finished1 = ListeningHistoryEntry(
            authors: ["Homer"],
            subjects: ["Epic Poetry"],
            listenedSeconds: 28800
        )
        let matched = candidate("match", "The Odyssey", "Homer", subjects: ["Epic Poetry"])
        let recs = RecommendationPipeline.recommendations(
            history: [finished1],
            onboardingSelectionIDs: [],
            candidates: [matched, candidate("other", "Other", "Someone Else", subjects: ["Cooking"])]
        )
        #expect(!(recs.map(\.identifier) == HomeRecommendationStore.bundledPopularSeeds.map(\.identifier)))
    }

    // MARK: - Upgrade/backfill shape (author-only terms)

    @Test func backfillShapeAuthorOnlyProfileNonEmpty() {
        let entry = ListeningHistoryEntry(
            authors: ["Jane Austen"],
            subjects: [],
            languages: [],
            listenedSeconds: 3600
        )
        let profile = RecommendationPipeline.buildProfile(history: [entry])
        #expect(!(profile.isEmpty))
        #expect(!(profile.creatorTerms.isEmpty))
        #expect(profile.subjectTerms.isEmpty)
    }

    // MARK: - Favorites

    @Test func unlistenedFavoriteContributesBoost() {
        let entry = ListeningHistoryEntry(
            authors: ["Jane Austen"],
            subjects: ["Fiction"],
            listenedSeconds: 0,
            isFavorite: true
        )
        let profile = RecommendationPipeline.buildProfile(history: [entry])
        let authorTerm = profile.creatorTerms.first { $0.term == "jane austen" }
        #expect(authorTerm != nil)
        if let authorTerm {
            #expect(abs((authorTerm.weight) - (RecommendationConstants.favoriteBoost)) <= 0.001)
        }
    }

    // MARK: - Junk resistance

    @Test func stopListSubjectsAreDamped() {
        let entry = ListeningHistoryEntry(
            subjects: ["music", "thriller"],
            listenedSeconds: 3600
        )
        let profile = RecommendationPipeline.buildProfile(history: [entry])
        let music = profile.subjectTerms.first { $0.term == "music" }
        let thriller = profile.subjectTerms.first { $0.term == "thriller" }
        if let music, let thriller {
            #expect(music.weight < thriller.weight * 0.1)
        }
    }

    @Test func unknownAndVariousAuthorsAreDropped() {
        let entry = ListeningHistoryEntry(
            authors: ["Unknown", "Various", "Jane Austen"],
            listenedSeconds: 3600
        )
        let profile = RecommendationPipeline.buildProfile(history: [entry])
        #expect(!(profile.creatorTerms.contains { $0.term == "unknown" }))
        #expect(!(profile.creatorTerms.contains { $0.term == "various" }))
        #expect(profile.creatorTerms.contains { $0.term == "jane austen" })
    }

    @Test func collectionLikeSubjectsAreDropped() {
        let entry = ListeningHistoryEntry(
            subjects: ["lv-mystery-crime", "great-books", "Detective Fiction"],
            listenedSeconds: 3600
        )
        let profile = RecommendationPipeline.buildProfile(history: [entry])
        #expect(!(profile.subjectTerms.contains { $0.term == "lv-mystery-crime" }))
        #expect(!(profile.subjectTerms.contains { $0.term == "great-books" }))
        #expect(profile.subjectTerms.contains { $0.term == "detective fiction" })
    }

    // MARK: - Determinism

    @Test func pipelineIsDeterministic() {
        let entry = ListeningHistoryEntry(
            authors: ["Jane Austen"],
            subjects: ["Romance", "Fiction"],
            listenedSeconds: 7200
        )
        let first = RecommendationPipeline.recommendations(
            history: [entry],
            onboardingSelectionIDs: ["great-books"],
            candidates: [candidate("a", "A", "Jane Austen", subjects: ["Romance"]),
                         candidate("b", "B", "Someone", subjects: ["Fiction"])]
        )
        let second = RecommendationPipeline.recommendations(
            history: [entry],
            onboardingSelectionIDs: ["great-books"],
            candidates: [candidate("a", "A", "Jane Austen", subjects: ["Romance"]),
                         candidate("b", "B", "Someone", subjects: ["Fiction"])]
        )
        #expect(first.map(\.identifier) == second.map(\.identifier))
    }

    // MARK: - Subject semicolon splitting

    @Test func termWeightsSplitsSemicolonSubjects() {
        let entry = ListeningHistoryEntry(
            authors: [],
            subjects: ["librivox; audiobooks;greek drama; aristophanes; greek comedy"],
            listenedSeconds: 7200
        )
        let weights = RecommendationPipeline.termWeights(history: [entry])
        let subjectWeights = weights.filter { $0.axis == "subject" }
        let subjectTerms = Set(subjectWeights.map(\.term))
        #expect(subjectTerms.contains("greek drama"))
        #expect(subjectTerms.contains("aristophanes"))
        #expect(subjectTerms.contains("greek comedy"))
        #expect(!(subjectTerms.contains { $0.contains(";") }))
        #expect(!(subjectTerms.contains("librivox")))
        #expect(!(subjectTerms.contains("audiobooks")))
    }

    @Test func extractTokensSplitsSemicolonSubjects() {
        let result = candidate(
            "test",
            "Test",
            "Author One",
            subjects: ["librivox; audiobooks;greek drama; aristophanes; greek comedy"]
        )
        let tokens = Set(RecommendationPipeline.extractTokens(result))
        #expect(tokens.contains("greek drama"))
        #expect(tokens.contains("aristophanes"))
        #expect(tokens.contains("greek comedy"))
        #expect(!(tokens.contains("librivox")))  // stop-listed generic terms are dropped
        #expect(!(tokens.contains("audiobooks")))  // stop-listed generic terms are dropped
        #expect(!(tokens.contains(";")))
    }

    @Test func scoreCandidatesMatchesSplitSubjects() {
        let entry = ListeningHistoryEntry(
            authors: [],
            subjects: ["librivox; audiobooks;greek drama; aristophanes; greek comedy"],
            listenedSeconds: 7200
        )
        let profile = RecommendationPipeline.buildProfile(history: [entry])

        let cand = candidate(
            "match",
            "The Frogs",
            "Aristophanes",
            subjects: ["greek drama", "comedy"]
        )
        let scored = RecommendationPipeline.scoreCandidates([cand], profile: profile)
        #expect(scored.count == 1)
        #expect(scored[0].score > 0)
    }

    // MARK: - Query builder

    @Test func generatedSubjectQueriesUseSingleTerms() {
        let entry = ListeningHistoryEntry(
            authors: [],
            subjects: ["librivox; audiobooks;greek drama; aristophanes; greek comedy"],
            listenedSeconds: 7200
        )
        let profile = RecommendationPipeline.buildProfile(history: [entry])
        let queries = RecommendationQueryBuilder.generateQueries(
            profile: profile,
            dateSeed: "2026-01-01",
            languageClause: ""
        )
        for query in queries {
            if query.iaQuery.contains("subject:") {
                let subjectClauses = query.iaQuery.components(separatedBy: "subject:\"")
                for clause in subjectClauses.dropFirst() {
                    let endQuote = clause.components(separatedBy: "\"")
                    if let term = endQuote.first {
                        #expect(!(term.contains(";")))  // generated query must not contain semicolon inside subject clause: '\(term)' in \(query.iaQuery)
                    }
                }
            }
        }
    }

    @Test func exploitRowsFloor() {
        let entries: [ListeningHistoryEntry] = (0..<10).map { i in
            ListeningHistoryEntry(
                authors: ["Author\(i)"],
                subjects: [],
                listenedSeconds: 7200
            )
        }
        let profile = RecommendationPipeline.buildProfile(history: entries)
        let queries = RecommendationQueryBuilder.generateQueries(
            profile: profile,
            dateSeed: "2026-01-01",
            languageClause: ""
        )
        for query in queries where query.noveltyClass == .exploit {
            #expect(query.requestedCount >= 4)
        }
    }

    // MARK: - Narrator axis

    @Test func narratorsAppearInProfileBucket() {
        let entry = ListeningHistoryEntry(
            authors: ["Jane Austen"],
            subjects: [],
            narrators: ["Karen Savage"],
            listenedSeconds: 7200
        )
        let profile = RecommendationPipeline.buildProfile(history: [entry])
        #expect(!(profile.isEmpty))
        #expect(!(profile.narratorTerms.isEmpty))  // narrator should appear in profile
        #expect(profile.narratorTerms.first?.term == "karen savage")
    }

    @Test func narratorTermsFlowIntoAllTerms() {
        let entry = ListeningHistoryEntry(
            authors: ["Jane Austen"],
            subjects: [],
            narrators: ["Karen Savage"],
            listenedSeconds: 7200
        )
        let profile = RecommendationPipeline.buildProfile(history: [entry])
        let allTerms = profile.allTerms()
        let narratorInAll = allTerms.filter { $0.axis == "narrator" }
        #expect(!(narratorInAll.isEmpty))  // narrator terms should appear in allTerms()
        #expect(narratorInAll.contains { $0.term == "karen savage" })
    }

    @Test func topNarratorsReturnsWeightedNarrators() {
        let entries: [ListeningHistoryEntry] = [
            ListeningHistoryEntry(narrators: ["Karen Savage"], listenedSeconds: 7200),
            ListeningHistoryEntry(narrators: ["Elizabeth Klett"], listenedSeconds: 3600),
            ListeningHistoryEntry(narrators: ["Karen Savage"], listenedSeconds: 7200)
        ]
        let profile = RecommendationPipeline.buildProfile(history: entries)
        #expect(!(profile.narratorTerms.isEmpty))
        let savage = profile.narratorTerms.first { $0.term == "karen savage" }
        let klett = profile.narratorTerms.first { $0.term == "elizabeth klett" }
        if let savage, let klett {
            #expect(savage.weight > klett.weight)
        }
    }

    @Test func unknownNarratorDroppedFromProfile() {
        let entry = ListeningHistoryEntry(
            authors: [],
            subjects: [],
            narrators: ["Unknown", "Various", "Karen Savage"],
            listenedSeconds: 7200
        )
        let profile = RecommendationPipeline.buildProfile(history: [entry])
        let narrators = profile.narratorTerms.map(\.term)
        #expect(!(narrators.contains("unknown")))
        #expect(!(narrators.contains("various")))
        #expect(narrators.contains("karen savage"))
    }

    @Test func extractTokensIncludesNarrators() {
        let result = candidate(
            "test",
            "Test Title",
            "Author One",
            description: "Read by Karen Savage",
            subjects: ["Fiction"]
        )
        let tokens = Set(RecommendationPipeline.extractTokens(result))
        #expect(tokens.contains("karen savage"))  // narrator should be extracted from description
    }

    @Test func narratorExploitQueryGenerated() {
        let entry = ListeningHistoryEntry(
            authors: [],
            subjects: [],
            narrators: ["Karen Savage"],
            listenedSeconds: 7200
        )
        let profile = RecommendationPipeline.buildProfile(history: [entry])
        let queries = RecommendationQueryBuilder.generateQueries(
            profile: profile,
            dateSeed: "2026-01-01",
            languageClause: ""
        )
        let hasNarratorQuery = queries.contains { $0.iaQuery.contains("description:\"karen savage\"") }
        #expect(hasNarratorQuery)  // exploit query should include narrator-based description search
    }

    // MARK: - Solo narration boost

    @Test func soloNarrationGetsDoubleScore() {
        let entry = ListeningHistoryEntry(
            authors: ["Jane Austen"],
            subjects: ["Fiction"],
            listenedSeconds: 7200
        )
        let profile = RecommendationPipeline.buildProfile(history: [entry])

        let soloResult = candidate(
            "solo1",
            "Pride and Prejudice",
            "Jane Austen",
            description: "Read by Karen Savage",
            subjects: ["Fiction"]
        )
        let collabResult = candidate(
            "collab1",
            "Pride and Prejudice (Dramatic)",
            "Jane Austen",
            description: "Read by Various Readers",
            subjects: ["Fiction"]
        )

        let scored = RecommendationPipeline.scoreCandidates(
            [soloResult, collabResult],
            profile: profile
        )

        #expect(scored.count == 2)

        let soloScore = scored.first { $0.result.identifier == "solo1" }?.score ?? 0
        let collabScore = scored.first { $0.result.identifier == "collab1" }?.score ?? 0

        #expect(soloScore > collabScore)
    }

    @Test func soloBoostConstantIsDefined() {
        #expect(abs((RecommendationConstants.soloNarrationBoost) - (2.0)) <= 0.001)  // solo narration boost must be 2.0
        #expect(RecommendationConstants.soloNarrationBoost > 1.0)
    }

    // MARK: - Helpers

    private func candidate(
        _ identifier: String,
        _ title: String,
        _ creator: String,
        description: String? = nil,
        downloads: Int? = nil,
        subjects: [String] = [],
        collections: [String] = ["librivoxaudio"]
    ) -> InternetArchiveSearchResult {
        InternetArchiveSearchResult(
            identifier: identifier,
            title: title,
            creators: [creator],
            description: description,
            collections: collections,
            downloads: downloads,
            date: nil,
            languages: ["english"],
            subjects: subjects
        )
    }
}
