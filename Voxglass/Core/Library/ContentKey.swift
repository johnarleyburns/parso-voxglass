import Foundation

/// Deterministic, reimport-stable identity for books and chapters (Phase 3).
/// `Book.id` / `Chapter.id` are random UUIDs minted at import: they survive an
/// in-place upgrade but not a delete-and-reinstall or a second device. Content
/// keys are derived purely from what the content *is* — the Internet Archive
/// identifier or the local folder name, and the audio filename stem — so the
/// same book imported on any device produces the same keys. Pure, no I/O.
public enum ContentKey {
    /// `ia:<identifier>` for Internet Archive imports (parsed from the
    /// `sources.url` details URL, the same identifier
    /// `ensureInternetArchiveSource` dedupes on), or `local:<normalized folder>`
    /// for local-file imports. `nil` when no stable identity can be derived.
    public static func book(forSourceURL url: URL?, kind: SourceKind) -> String? {
        switch kind {
        case .librivox, .internetArchive, .internetArchiveURL:
            guard let url else { return nil }
            let components = url.pathComponents
            guard let detailsIndex = components.firstIndex(of: "details"),
                  components.indices.contains(detailsIndex + 1) else { return nil }
            let identifier = components[detailsIndex + 1]
            guard !identifier.isEmpty else { return nil }
            return "ia:\(identifier)"
        case .localFiles:
            guard let url else { return nil }
            let normalized = normalize(url.lastPathComponent)
            guard !normalized.isEmpty else { return nil }
            return "local:\(normalized)"
        }
    }

    /// Convenience for Internet Archive imports where the identifier is already
    /// in hand.
    public static func book(forInternetArchiveIdentifier identifier: String) -> String? {
        identifier.isEmpty ? nil : "ia:\(identifier)"
    }

    /// Convenience for local-folder imports.
    public static func book(forLocalFolderName folderName: String) -> String? {
        let normalized = normalize(folderName)
        return normalized.isEmpty ? nil : "local:\(normalized)"
    }

    /// Normalized filename stem — stable for both IA and local files, and stable
    /// across a folder move — falling back to the normalized title, then to
    /// `idx:<index>`.
    public static func chapter(remoteURL: URL?, localURL: URL?, index: Int, title: String) -> String {
        for url in [remoteURL, localURL] {
            guard let url else { continue }
            let stem = normalize(url.deletingPathExtension().lastPathComponent)
            if !stem.isEmpty {
                return stem
            }
        }
        let normalizedTitle = normalize(title)
        if !normalizedTitle.isEmpty {
            return normalizedTitle
        }
        return "idx:\(index)"
    }

    /// Lowercases, strips diacritics, and collapses every non-alphanumeric run to
    /// a single `-`, so "Chapter 01 — L'Étranger.mp3" and
    /// "chapter_01__l_etranger.MP3" produce the same key.
    public static func normalize(_ raw: String) -> String {
        let folded = raw
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        let collapsed = folded
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
