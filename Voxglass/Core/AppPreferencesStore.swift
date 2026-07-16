import SwiftUI

public struct AppPreferencesStore: DynamicProperty {
    public enum Keys {
        public static let hasCompletedSplash = "voxglass.hasCompletedSplash"
        public static let hasCompletedOnboarding = "voxglass.hasCompletedOnboarding"
        public static let selectedCollectionIDs = "voxglass.selectedCollectionIDs"
        public static let selectedLanguages = "voxglass.selectedLanguages"
        public static let cacheFullBooksOnCellular = "voxglass.cacheFullBooksOnCellular"
        public static let prefetchDepth = "voxglass.prefetchDepth"
        public static let prefetchWifiOnly = "voxglass.prefetchWifiOnly"
        public static let sleepTimerDefaultMinutes = "voxglass.sleepTimerDefaultMinutes"
        public static let skipForwardInterval = "voxglass.skipForwardInterval"
        public static let skipBackInterval = "voxglass.skipBackInterval"
        public static let skipSilenceEnabled = "voxglass.skipSilence.enabled"
        public static let volumeNormalizationEnabled = "voxglass.volumeNormalization.enabled"
    }

    @AppStorage(Keys.hasCompletedSplash) public var hasCompletedSplash = false
    @AppStorage(Keys.hasCompletedOnboarding) public var hasCompletedOnboarding = false
    @AppStorage(Keys.selectedCollectionIDs) private var selectedCollectionIDsRaw = ""
    @AppStorage(Keys.selectedLanguages) private var selectedLanguagesRaw = "eng"

    public var selectedCollectionIDs: Set<String> {
        get { Self.decodeCollectionIDs(selectedCollectionIDsRaw) }
        nonmutating set { selectedCollectionIDsRaw = Self.encodeCollectionIDs(newValue) }
    }

    public var selectedLanguages: Set<String> {
        get { Self.decodeLanguages(selectedLanguagesRaw) }
        nonmutating set { selectedLanguagesRaw = Self.encodeLanguages(newValue) }
    }

    public static func encodeCollectionIDs(_ ids: Set<String>) -> String {
        ids.sorted().joined(separator: ",")
    }

    public static func decodeCollectionIDs(_ rawValue: String) -> Set<String> {
        Set(
            rawValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    public static func encodeLanguages(_ codes: Set<String>) -> String {
        codes.sorted().joined(separator: ",")
    }

    public static func decodeLanguages(_ rawValue: String) -> Set<String> {
        Set(
            rawValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }
}

public enum RecentlyViewedBooksStore {
    public static let key = "voxglass.recentlyViewedBookIDs"
    public static let defaultLimit = 12

    public static func encode(_ ids: [UUID]) -> String {
        ids.map(\.uuidString).joined(separator: ",")
    }

    public static func ids(from rawValue: String) -> [UUID] {
        rawValue
            .split(separator: ",")
            .compactMap { UUID(uuidString: String($0)) }
    }

    public static func recording(bookID: UUID, in rawValue: String, limit: Int = defaultLimit) -> String {
        var ids = ids(from: rawValue).filter { $0 != bookID }
        ids.insert(bookID, at: 0)
        return encode(Array(ids.prefix(limit)))
    }

    public static func removing(bookID: UUID, in rawValue: String) -> String {
        encode(ids(from: rawValue).filter { $0 != bookID })
    }

    public static func books(from library: [BookWithChapters], rawValue: String) -> [BookWithChapters] {
        let orderedIDs = ids(from: rawValue)
        guard !orderedIDs.isEmpty else { return [] }

        let booksByID = Dictionary(uniqueKeysWithValues: library.map { ($0.book.id, $0) })
        return orderedIDs.compactMap { booksByID[$0] }
    }
}
