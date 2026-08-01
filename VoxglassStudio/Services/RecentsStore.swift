import Foundation
import Observation

@MainActor
@Observable
public final class RecentsStore {
    public private(set) var recentURLs: [URL] = []

    private let storageURL: URL

    public init(storageDirectory: URL? = nil) {
        let dir: URL
        if let explicitDir = storageDirectory {
            dir = explicitDir
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            dir = appSupport.appendingPathComponent("guru.parso.voxglass.studio")
        }
        self.storageURL = dir.appendingPathComponent("recents.json")

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = load()
    }

    public func add(url: URL) {
        var urls = recentURLs
        urls.removeAll { $0.absoluteString == url.absoluteString }
        urls.insert(url, at: 0)

        if urls.count > 30 {
            urls = Array(urls.prefix(30))
        }

        recentURLs = urls
        save()
    }

    public func remove(url: URL) {
        recentURLs.removeAll { $0.absoluteString == url.absoluteString }
        save()
    }

    public func clear() {
        recentURLs.removeAll()
        save()
    }

    @discardableResult
    public func load() -> Bool {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return false }
        guard let data = try? Data(contentsOf: storageURL) else { return false }
        guard let entries = try? JSONDecoder().decode(RecentsData.self, from: data) else { return false }
        var resolved: [URL] = []
        var changed = false

        for entry in entries.entries {
            if let bookmarkData = entry.bookmark {
                var isStale = false
                if let url = try? URL(resolvingBookmarkData: bookmarkData,
                                      options: .withSecurityScope,
                                      relativeTo: nil,
                                      bookmarkDataIsStale: &isStale) {
                    if isStale { changed = true }
                    resolved.append(url)
                } else {
                    changed = true
                }
            } else if let url = URL(string: entry.path) {
                resolved.append(url)
            }
        }

        recentURLs = resolved
        if changed { save() }
        return true
    }

    public func save() {
        var bookmarkEntries: [BookmarkEntry] = []

        for url in recentURLs {
            if url.startAccessingSecurityScopedResource() {
                defer { url.stopAccessingSecurityScopedResource() }

                if let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                         includingResourceValuesForKeys: nil,
                                                         relativeTo: nil) {
                    bookmarkEntries.append(BookmarkEntry(bookmark: bookmark, path: url.absoluteString))
                }
            } else {
                bookmarkEntries.append(BookmarkEntry(bookmark: nil, path: url.absoluteString))
            }
        }

        let recentsData = RecentsData(entries: bookmarkEntries)
        if let data = try? JSONEncoder().encode(recentsData) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }

    private struct RecentsData: Codable {
        var entries: [BookmarkEntry]
    }

    private struct BookmarkEntry: Codable {
        var bookmark: Data?
        var path: String
    }
}
