import SwiftUI

public struct AppPreferencesStore: DynamicProperty {
    public enum Keys {
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
        /// Empty means automatically choose the best installed system voice.
        public static let readWithAIVoiceIdentifier = "voxglass.readWithAI.voiceIdentifier"
        /// A structured default survives a system voice package changing its
        /// identifier by retaining the voice's human name and language too.
        public static let readWithAIVoiceDefault = "voxglass.readWithAI.voice.default.v2"
        /// Book-specific Read with AI voice choices.  This is deliberately a
        /// local preference: it describes voices installed on this device.
        public static let readWithAIVoiceByBook = "voxglass.readWithAI.voice.byBook.v1"
        public static let iCloudSyncEnabled = "voxglass.iCloudSync.enabled"
        public static let authoringV2SyncEnabled = "voxglass.authoringV2Sync.enabled"
        public static let authoringV2LastSync = "voxglass.authoringV2Sync.lastSync"
        public static let cloudKitInitialLibraryEnqueued = "voxglass.cloudKit.initialLibraryEnqueued.v1"
        public static let cloudKitLibraryUploadConfirmed = "voxglass.cloudKit.libraryUploadConfirmed.v1"
        public static let narrationIntroSeen = "voxglass.narration.introSeen.v1"
        public static let narrationCollapsedChapters = "voxglass.narration.collapsedChapters.v1"
        /// Set once a "Contribute to Development" purchase succeeds. Never
        /// reset by a later purchase failing or being skipped — this is a
        /// one-way supporter badge, not a re-checked entitlement.
        public static let isSupporter = "voxglass.isSupporter"
        public static let widgetSnapshot = "settings.widgetSnapshot"
    }

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
        let decoded = Set(
            rawValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        return migrateCollectionIDs(decoded)
    }

    private static func migrateCollectionIDs(_ ids: Set<String>) -> Set<String> {
        var migrated = ids
        migrated.remove("lv-literary-fiction")
        if migrated.contains("ancient-greece") {
            migrated.remove("ancient-greece")
            migrated.insert("lv-ancient-world")
        }
        return migrated
    }

    /// Stored for an empty selection, which means "every language". An empty
    /// string is the never-set default and decodes to the device default instead.
    public static var allLanguagesValue: String { "all" }

    /// Narration project sync is on for new installs. A stored `false` remains
    /// an explicit user choice and is not overwritten by this default.
    public static func authoringV2SyncEnabled(in userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.object(forKey: Keys.authoringV2SyncEnabled) as? Bool ?? true
    }

    public static func encodeLanguages(_ codes: Set<String>) -> String {
        codes.isEmpty ? allLanguagesValue : codes.sorted().joined(separator: ",")
    }

    public static func decodeLanguages(_ rawValue: String) -> Set<String> {
        if rawValue == allLanguagesValue { return [] }
        let decoded = Set(
            rawValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        return decoded.isEmpty ? LibriVoxLanguage.defaultSelection : decoded
    }
}

/// A voice choice is stored separately from the audio book so it remains a
/// reader preference, while the book and its position can continue to sync.
/// `identifier` is Apple's primary key; `name` and `language` allow a safe
/// match when iOS replaces a downloaded voice package during an update.
public struct ReadWithAIVoicePreference: Codable, Equatable, Sendable {
    public var identifier: String
    public var name: String?
    public var language: String?

    public init(identifier: String, name: String? = nil, language: String? = nil) {
        self.identifier = identifier
        self.name = name
        self.language = language
    }

    public static let automatic = Self(identifier: "")
}

public enum ReadWithAIVoicePreferences {
    public static func defaultPreference(in defaults: UserDefaults = .standard) -> ReadWithAIVoicePreference {
        if let data = defaults.data(forKey: AppPreferencesStore.Keys.readWithAIVoiceDefault),
           let preference = try? JSONDecoder().decode(ReadWithAIVoicePreference.self, from: data) {
            return preference
        }
        // Preserve the original single-value setting for readers upgrading
        // from builds that shipped before per-book voice choices.
        return ReadWithAIVoicePreference(
            identifier: defaults.string(forKey: AppPreferencesStore.Keys.readWithAIVoiceIdentifier) ?? ""
        )
    }

    public static func preference(for bookID: UUID, in defaults: UserDefaults = .standard) -> ReadWithAIVoicePreference {
        preferencesByBook(in: defaults)[bookID.uuidString] ?? defaultPreference(in: defaults)
    }

    public static func setDefault(_ preference: ReadWithAIVoicePreference, in defaults: UserDefaults = .standard) {
        defaults.set(preference.identifier, forKey: AppPreferencesStore.Keys.readWithAIVoiceIdentifier)
        defaults.set(try? JSONEncoder().encode(preference), forKey: AppPreferencesStore.Keys.readWithAIVoiceDefault)
    }

    public static func set(_ preference: ReadWithAIVoicePreference, for bookID: UUID, alsoMakeDefault: Bool = true, in defaults: UserDefaults = .standard) {
        var preferences = preferencesByBook(in: defaults)
        preferences[bookID.uuidString] = preference
        defaults.set(try? JSONEncoder().encode(preferences), forKey: AppPreferencesStore.Keys.readWithAIVoiceByBook)
        if alsoMakeDefault { setDefault(preference, in: defaults) }
    }

    private static func preferencesByBook(in defaults: UserDefaults) -> [String: ReadWithAIVoicePreference] {
        guard let data = defaults.data(forKey: AppPreferencesStore.Keys.readWithAIVoiceByBook),
              let preferences = try? JSONDecoder().decode([String: ReadWithAIVoicePreference].self, from: data)
        else { return [:] }
        return preferences
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
