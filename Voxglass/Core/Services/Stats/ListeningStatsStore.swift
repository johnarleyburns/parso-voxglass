import Foundation

/// Records and aggregates on-device listening events (§5). Events are logged for
/// **all** users (privacy-safe, local only, no telemetry); only the *viewing* of
/// stats is Pro-gated. `book_id` uses `ON DELETE SET NULL` so lifetime totals stay
/// correct after a book is removed.
@MainActor
final class ListeningStatsStore: ObservableObject {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - Recording

    func record(bookID: UUID?, seconds: Double, at date: Date = Date()) async {
        guard seconds > 0 else { return }
        do {
            try await database.prepare()
            try await database.execute("""
            INSERT INTO listening_events (id, book_id, seconds, occurred_at)
            VALUES (?, ?, ?, ?)
            """, [
                .string(UUID().uuidString),
                bookID.map { ModelMapping.databaseValue($0) } ?? .null,
                .double(seconds),
                .double(date.timeIntervalSince1970)
            ])
        } catch {
            // Stats are best-effort; never surface a logging failure to playback.
        }
    }

    // MARK: - Aggregates

    func totalTime() async -> TimeInterval {
        (try? await scalar("SELECT COALESCE(SUM(seconds), 0) AS total FROM listening_events", column: "total")) ?? 0
    }

    /// Per-day totals for the last `days` days, keyed by the start of each day.
    func dailyTotals(days: Int, calendar: Calendar = .current, now: Date = Date()) async -> [Date: TimeInterval] {
        let cutoff = calendar.startOfDay(for: now).addingTimeInterval(-Double(max(0, days - 1)) * 86_400)
        guard let rows = try? await query("""
        SELECT occurred_at, seconds FROM listening_events
        WHERE occurred_at >= ?
        """, [.double(cutoff.timeIntervalSince1970)]) else {
            return [:]
        }
        var totals: [Date: TimeInterval] = [:]
        for row in rows {
            guard let ts = row.double("occurred_at"), let secs = row.double("seconds") else { continue }
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: ts))
            totals[day, default: 0] += secs
        }
        return totals
    }

    func currentStreak(calendar: Calendar = .current, now: Date = Date()) async -> Int {
        let totals = await dailyTotals(days: 400, calendar: calendar, now: now)
        return Self.currentStreak(dayTotals: totals, calendar: calendar, now: now)
    }

    func topAuthors(limit: Int = 5) async -> [(term: String, seconds: TimeInterval)] {
        await topTerms(axis: "author", limit: limit)
    }

    func topSubjects(limit: Int = 5) async -> [(term: String, seconds: TimeInterval)] {
        await topTerms(axis: "subject", limit: limit)
    }

    private func topTerms(axis: String, limit: Int) async -> [(term: String, seconds: TimeInterval)] {
        guard let rows = try? await query("""
        SELECT bt.term AS term, SUM(le.seconds) AS total
        FROM listening_events le
        JOIN book_taste bt ON bt.book_id = le.book_id
        WHERE bt.axis = ? AND le.book_id IS NOT NULL
        GROUP BY bt.term
        ORDER BY total DESC
        LIMIT ?
        """, [.string(axis), .int(Int64(max(0, limit)))]) else {
            return []
        }
        return rows.compactMap { row in
            guard let term = row.string("term"), let total = row.double("total") else { return nil }
            return (term, total)
        }
    }

    // MARK: - Pure streak helper (testable)

    static func currentStreak(dayTotals: [Date: TimeInterval], calendar: Calendar = .current, now: Date = Date()) -> Int {
        let activeDays = Set(
            dayTotals
                .filter { $0.value > 0 }
                .keys
                .map { calendar.startOfDay(for: $0) }
        )
        guard !activeDays.isEmpty else { return 0 }

        var cursor = calendar.startOfDay(for: now)
        // Allow the streak to count from yesterday if there's no listening yet today.
        if !activeDays.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor),
                  activeDays.contains(yesterday) else {
                return 0
            }
            cursor = yesterday
        }

        var streak = 0
        while activeDays.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    // MARK: - Query helpers

    private func scalar(_ sql: String, _ bindings: [DatabaseValue] = [], column: String) async throws -> TimeInterval {
        try await database.prepare()
        let rows = try await database.query(sql, bindings)
        return rows.first?.double(column) ?? 0
    }

    private func query(_ sql: String, _ bindings: [DatabaseValue] = []) async throws -> [DatabaseRow] {
        try await database.prepare()
        return try await database.query(sql, bindings)
    }
}
