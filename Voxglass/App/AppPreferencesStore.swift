import SwiftUI

struct AppPreferencesStore: DynamicProperty {
    enum Keys {
        static let hasCompletedSplash = "voxglass.hasCompletedSplash"
        static let hasCompletedOnboarding = "voxglass.hasCompletedOnboarding"
        static let selectedCollectionIDs = "voxglass.selectedCollectionIDs"
        static let selectedLanguages = "voxglass.selectedLanguages"
        static let cacheFullBooksOnCellular = "voxglass.cacheFullBooksOnCellular"
        static let prefetchDepth = "voxglass.prefetchDepth"
        static let prefetchWifiOnly = "voxglass.prefetchWifiOnly"
        static let sleepTimerDefaultMinutes = "voxglass.sleepTimerDefaultMinutes"
        static let skipForwardInterval = "voxglass.skipForwardInterval"
        static let skipBackInterval = "voxglass.skipBackInterval"
    }

    @AppStorage(Keys.hasCompletedSplash) var hasCompletedSplash = false
    @AppStorage(Keys.hasCompletedOnboarding) var hasCompletedOnboarding = false
    @AppStorage(Keys.selectedCollectionIDs) private var selectedCollectionIDsRaw = ""
    @AppStorage(Keys.selectedLanguages) private var selectedLanguagesRaw = "eng"

    var selectedCollectionIDs: Set<String> {
        get { Self.decodeCollectionIDs(selectedCollectionIDsRaw) }
        nonmutating set { selectedCollectionIDsRaw = Self.encodeCollectionIDs(newValue) }
    }

    var selectedLanguages: Set<String> {
        get { Self.decodeLanguages(selectedLanguagesRaw) }
        nonmutating set { selectedLanguagesRaw = Self.encodeLanguages(newValue) }
    }

    static func encodeCollectionIDs(_ ids: Set<String>) -> String {
        ids.sorted().joined(separator: ",")
    }

    static func decodeCollectionIDs(_ rawValue: String) -> Set<String> {
        Set(
            rawValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    static func encodeLanguages(_ codes: Set<String>) -> String {
        codes.sorted().joined(separator: ",")
    }

    static func decodeLanguages(_ rawValue: String) -> Set<String> {
        Set(
            rawValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }
}

enum RecentlyViewedBooksStore {
    static let key = "voxglass.recentlyViewedBookIDs"
    static let defaultLimit = 12

    static func encode(_ ids: [UUID]) -> String {
        ids.map(\.uuidString).joined(separator: ",")
    }

    static func ids(from rawValue: String) -> [UUID] {
        rawValue
            .split(separator: ",")
            .compactMap { UUID(uuidString: String($0)) }
    }

    static func recording(bookID: UUID, in rawValue: String, limit: Int = defaultLimit) -> String {
        var ids = ids(from: rawValue).filter { $0 != bookID }
        ids.insert(bookID, at: 0)
        return encode(Array(ids.prefix(limit)))
    }

    static func removing(bookID: UUID, in rawValue: String) -> String {
        encode(ids(from: rawValue).filter { $0 != bookID })
    }

    static func books(from library: [BookWithChapters], rawValue: String) -> [BookWithChapters] {
        let orderedIDs = ids(from: rawValue)
        guard !orderedIDs.isEmpty else { return [] }

        let booksByID = Dictionary(uniqueKeysWithValues: library.map { ($0.book.id, $0) })
        return orderedIDs.compactMap { booksByID[$0] }
    }
}
