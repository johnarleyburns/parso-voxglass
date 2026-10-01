import Foundation

/// Watch redesign A2 — the "Continue listening" Smart Stack card: the book you're in, where you
/// are, and time left. The watch app writes it to the shared App Group; the widget only reads it.
public struct WatchContinueListeningState: Codable, Equatable, Sendable {
    public var bookTitle: String
    public var chapterIndex: Int
    public var chapterTitle: String
    /// Whole-book progress, 0...1.
    public var progress: Double
    /// Seconds left in the book at the current speed, as of `anchorDate`.
    public var remainingInBook: TimeInterval
    public var isPlaying: Bool
    public var anchorDate: Date

    public init(bookTitle: String, chapterIndex: Int, chapterTitle: String, progress: Double,
                remainingInBook: TimeInterval, isPlaying: Bool, anchorDate: Date) {
        self.bookTitle = bookTitle
        self.chapterIndex = chapterIndex
        self.chapterTitle = chapterTitle
        self.progress = min(1, max(0, progress))
        self.remainingInBook = max(0, remainingInBook)
        self.isPlaying = isPlaying
        self.anchorDate = anchorDate
    }

    /// Reload the widget only when what the card shows changes — not on clock ticks.
    public func differsStructurally(from other: WatchContinueListeningState?) -> Bool {
        guard let other else { return true }
        return bookTitle != other.bookTitle || chapterIndex != other.chapterIndex || isPlaying != other.isPlaying
            || abs(remainingInBook - other.remainingInBook) >= 60
    }

    /// Smart Stack relevance: highest while playing, then in the evening (when people listen in bed).
    public func relevance(at date: Date, calendar: Calendar = .current) -> Float {
        if isPlaying { return 1 }
        let hour = calendar.component(.hour, from: date)
        return (19...23).contains(hour) ? 0.6 : 0.2
    }
}

public enum WatchContinueListeningStore {
    public static let appGroup = "group.guru.parso.voxglass"
    static let key = "watch.continueListening.v1"

    public static func save(_ state: WatchContinueListeningState?, defaults: UserDefaults? = nil) {
        let store = defaults ?? UserDefaults(suiteName: appGroup)
        guard let state else { store?.removeObject(forKey: key); return }
        if let data = try? JSONEncoder().encode(state) { store?.set(data, forKey: key) }
    }

    public static func load(defaults: UserDefaults? = nil) -> WatchContinueListeningState? {
        let store = defaults ?? UserDefaults(suiteName: appGroup)
        guard let data = store?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WatchContinueListeningState.self, from: data)
    }
}
