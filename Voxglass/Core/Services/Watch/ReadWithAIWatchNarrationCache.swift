import Foundation
import VoxglassWatchCore

/// UserDefaults-backed cache of finished Watch narration output (survives relaunch).
/// Only validated, canonical `.m4a` files inside the managed narration directory are
/// ever stored, returned, or deleted.
public struct ReadWithAIWatchNarrationUserDefaultsCache: ReadWithAIWatchNarrationCaching {
    public static let legacyPrefix = "readWithAI.watchNarration."
    public static let prefix = "readWithAI.watchNarration.aaclc48.v1."

    /// nil selects `UserDefaults.standard`. Stored as a name because `UserDefaults` is not `Sendable`.
    private let suiteName: String?
    private let managedRoot: URL

    public init(suiteName: String? = nil, managedRoot: URL) {
        self.suiteName = suiteName
        self.managedRoot = managedRoot
    }

    private var defaults: UserDefaults {
        suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    private static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }

    private func isInsideRoot(_ url: URL) -> Bool {
        let root = Self.canonical(managedRoot).path
        let path = Self.canonical(url).path
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    public func validCachedOutput(for key: String) -> URL? {
        guard let path = defaults.string(forKey: Self.prefix + key) else { return nil }
        let url = URL(fileURLWithPath: path)
        guard isInsideRoot(url), url.pathExtension.lowercased() == "m4a",
              (try? WatchAACAssetValidator.validate(url)) != nil else {
            removeOutput(for: key)
            return nil
        }
        return Self.canonical(url)
    }

    public func storeValidated(_ output: URL, for key: String) {
        let url = Self.canonical(output)
        guard isInsideRoot(url), url.pathExtension.lowercased() == "m4a",
              (try? WatchAACAssetValidator.validate(url)) != nil else { return }
        defaults.set(url.path, forKey: Self.prefix + key)
    }

    public func removeOutput(for key: String) {
        let name = Self.prefix + key
        if let path = defaults.string(forKey: name) {
            let url = URL(fileURLWithPath: path)
            if isInsideRoot(url) { try? FileManager.default.removeItem(at: url) }
        }
        defaults.removeObject(forKey: name)
    }

    public func purgeLegacyEntries() throws {
        for (name, value) in defaults.dictionaryRepresentation()
        where name.hasPrefix(Self.legacyPrefix) && !name.hasPrefix(Self.prefix) {
            if let path = value as? String {
                let url = URL(fileURLWithPath: path)
                if isInsideRoot(url) { try? FileManager.default.removeItem(at: url) }
            }
            defaults.removeObject(forKey: name)
        }
    }
}
