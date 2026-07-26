import Foundation

public struct NavigationHistoryStore {
    private static let key = "guru.parso.voxglass.navigationHistory"
    public static let maxEntries = 20

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func push(_ record: NavigationRecord) {
        var stack = load()
        if let recent = stack.first, recent.bookID == record.bookID, recent.chapterID == record.chapterID {
            stack.removeFirst()
        }
        stack.insert(record, at: 0)
        if stack.count > Self.maxEntries {
            stack = Array(stack.prefix(Self.maxEntries))
        }
        persist(stack)
    }

    public func pop() -> NavigationRecord? {
        var stack = load()
        guard !stack.isEmpty else { return nil }
        let record = stack.removeFirst()
        persist(stack)
        return record
    }

    public func peek() -> NavigationRecord? {
        load().first
    }

    public var count: Int {
        load().count
    }

    public func clear() {
        defaults.removeObject(forKey: Self.key)
    }

    private func load() -> [NavigationRecord] {
        guard let data = defaults.data(forKey: Self.key),
              let records = try? JSONDecoder().decode([NavigationRecord].self, from: data) else {
            return []
        }
        return records
    }

    private func persist(_ records: [NavigationRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
