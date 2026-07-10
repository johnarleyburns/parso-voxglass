import SwiftUI

struct AppPreferencesStore: DynamicProperty {
    enum Keys {
        static let hasCompletedSplash = "voxglass.hasCompletedSplash"
        static let hasCompletedOnboarding = "voxglass.hasCompletedOnboarding"
        static let selectedTasteIDs = "voxglass.selectedTasteIDs"
        static let appearanceMode = "voxglass.appearanceMode"
    }

    @AppStorage(Keys.hasCompletedSplash) var hasCompletedSplash = false
    @AppStorage(Keys.hasCompletedOnboarding) var hasCompletedOnboarding = false
    @AppStorage(Keys.selectedTasteIDs) private var selectedTasteIDsRaw = ""
    @AppStorage(Keys.appearanceMode) private var appearanceModeRaw = AppAppearanceMode.system.rawValue

    var selectedTasteIDs: Set<String> {
        get { Self.decodeTasteIDs(selectedTasteIDsRaw) }
        nonmutating set { selectedTasteIDsRaw = Self.encodeTasteIDs(newValue) }
    }

    var appearanceMode: AppAppearanceMode {
        get { AppAppearanceMode(rawValue: appearanceModeRaw) ?? .system }
        nonmutating set { appearanceModeRaw = newValue.rawValue }
    }

    static func encodeTasteIDs(_ ids: Set<String>) -> String {
        ids.sorted().joined(separator: ",")
    }

    static func decodeTasteIDs(_ rawValue: String) -> Set<String> {
        Set(
            rawValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }
}

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case dark
    case light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "System"
        case .dark:
            return "Dark"
        case .light:
            return "Light"
        }
    }

    var systemImage: String {
        switch self {
        case .system:
            return "circle.lefthalf.filled"
        case .dark:
            return "moon.fill"
        case .light:
            return "sun.max.fill"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .dark:
            return .dark
        case .light:
            return .light
        }
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

    static func books(from library: [BookWithChapters], rawValue: String) -> [BookWithChapters] {
        let orderedIDs = ids(from: rawValue)
        guard !orderedIDs.isEmpty else { return [] }

        let booksByID = Dictionary(uniqueKeysWithValues: library.map { ($0.book.id, $0) })
        return orderedIDs.compactMap { booksByID[$0] }
    }
}
