import Testing
import Foundation
@testable import VoxglassCore

@MainActor
@Suite struct ListeningStatsStoreTests {

    @Test func migrationCreatesListeningEventsTable() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "listening-migration")
        try await database.prepare()
        let rows = try await database.query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='listening_events'"
        )
        #expect(rows.first?.string("name") == "listening_events")
    }

    @Test func recordInsertsRowsAndTotalTimeSums() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "listening-total")
        let store = ListeningStatsStore(database: database)

        await store.record(bookID: nil, seconds: 30)
        await store.record(bookID: nil, seconds: 45)
        await store.record(bookID: nil, seconds: 0) // ignored

        let total = await store.totalTime()
        #expect(abs((total) - (75)) <= 0.001)
    }

    @Test func dailyTotalsBucketByDay() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "listening-daily")
        let store = ListeningStatsStore(database: database)
        let calendar = Calendar.current
        let now = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!

        await store.record(bookID: nil, seconds: 60, at: now)
        await store.record(bookID: nil, seconds: 120, at: now)
        await store.record(bookID: nil, seconds: 30, at: yesterday)

        let totals = await store.dailyTotals(days: 7, calendar: calendar, now: now)
        #expect(abs((totals[calendar.startOfDay(for: now)] ?? 0) - (180)) <= 0.001)
        #expect(abs((totals[calendar.startOfDay(for: yesterday)] ?? 0) - (30)) <= 0.001)
    }

    @Test func topAuthorsJoinsTasteTerms() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "listening-authors")
        try await database.prepare()
        let (bookID, _) = try await seedBook(in: database, title: "Stats Book")
        try await database.execute(
            "INSERT OR IGNORE INTO book_taste (book_id, axis, term) VALUES (?, 'author', ?)",
            [.string(bookID.uuidString), .string("mark twain")]
        )
        let store = ListeningStatsStore(database: database)
        await store.record(bookID: bookID, seconds: 300)

        let authors = await store.topAuthors(limit: 5)
        #expect(authors.first?.term == "mark twain")
        #expect(abs((authors.first?.seconds ?? 0) - (300)) <= 0.001)
    }

    // MARK: - Pure streak helper

    @Test func streakEmptyIsZero() {
        #expect(ListeningStatsStore.currentStreak(dayTotals: [:]) == 0)
    }

    @Test func streakSingleDayToday() {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        #expect(ListeningStatsStore.currentStreak(dayTotals: [today: 100], calendar: calendar, now: now) == 1)
    }

    @Test func streakConsecutiveDays() {
        let calendar = Calendar.current
        let now = Date()
        var totals: [Date: TimeInterval] = [:]
        for offset in 0..<3 {
            let day = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -offset, to: now)!)
            totals[day] = 60
        }
        #expect(ListeningStatsStore.currentStreak(dayTotals: totals, calendar: calendar, now: now) == 3)
    }

    @Test func streakGapBreaksCount() {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let threeDaysAgo = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -3, to: now)!)
        let totals: [Date: TimeInterval] = [today: 60, threeDaysAgo: 60]
        #expect(ListeningStatsStore.currentStreak(dayTotals: totals, calendar: calendar, now: now) == 1)
    }

    @Test func streakCountsFromYesterdayWhenNothingToday() {
        let calendar = Calendar.current
        let now = Date()
        let yesterday = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -1, to: now)!)
        let twoDaysAgo = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -2, to: now)!)
        let totals: [Date: TimeInterval] = [yesterday: 60, twoDaysAgo: 60]
        #expect(ListeningStatsStore.currentStreak(dayTotals: totals, calendar: calendar, now: now) == 2)
    }

    @Test func streakZeroWhenSecondsAreZero() {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        #expect(ListeningStatsStore.currentStreak(dayTotals: [today: 0], calendar: calendar, now: now) == 0)
    }

    private func seedBook(
        in database: AppDatabase,
        title: String
    ) async throws -> (bookID: UUID, chapterID: UUID) {
        let sourceID = UUID(), bookID = UUID(), chapterID = UUID()
        let now = Date().timeIntervalSince1970
        try await database.execute(
            "INSERT INTO sources (id, kind, title, url, created_at) VALUES (?, ?, ?, ?, ?)",
            [.string(sourceID.uuidString), .string(SourceKind.localFiles.rawValue), .string("\(title) Source"), .null, .double(now)]
        )
        try await database.execute("""
        INSERT INTO books (id, title, authors_json, summary, source_id, cover_url, created_at, updated_at, is_favorite)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .string(bookID.uuidString), .string(title), .string(ModelMapping.authorsJSON(["Author"])), .null,
            .string(sourceID.uuidString), .null, .double(now), .double(now), .bool(false)
        ])
        try await database.execute("""
        INSERT INTO chapters (id, book_id, title, sort_key, chapter_index, duration_seconds, remote_url, local_url)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .string(chapterID.uuidString), .string(bookID.uuidString), .string("Chapter 1"), .string("Chapter 1"),
            .int(0), .double(120), .null, .null
        ])
        return (bookID, chapterID)
    }
}
