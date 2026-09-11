import Foundation

/// Store/resolve seam for app-owned cover art (local-folder imports and
/// completed narrations). These covers are copied into
/// `Application Support/Voxglass/…`; persisting their *absolute* container path
/// into `books.cover_url` breaks on any container move (reinstall, device
/// restore, Xcode redeploy — iOS re-homes the data container). This mirrors what
/// `chapters.local_bookmark` / `ContainerPathRebase` do for audio files: persist
/// a container-independent value and re-resolve it against the *current*
/// Application Support directory at read time.
///
/// Contract for `books.cover_url`:
///  - remote covers (Internet Archive, `http`/`https`) are stored and returned
///    verbatim;
///  - app-owned covers are stored as a path *relative to Application Support*
///    (e.g. `Voxglass/LocalArtwork/<uuid>.jpg`) and resolved back to an absolute
///    file URL on read.
public enum LocalArtworkStore {
    /// The current container's Application Support directory.
    public static func applicationSupportDirectory(fileManager: FileManager = .default) -> URL {
        (try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? fileManager.temporaryDirectory
    }

    /// The relative-to-Application-Support path for `absoluteURL`, or nil when
    /// the URL is not a file URL under Application Support (the caller then
    /// keeps the value as-is — a remote URL passes straight through).
    public static func relativePath(
        for absoluteURL: URL,
        applicationSupport: URL? = nil,
        fileManager: FileManager = .default
    ) -> String? {
        guard absoluteURL.isFileURL else { return nil }
        let base = (applicationSupport ?? applicationSupportDirectory(fileManager: fileManager))
            .resolvingSymlinksInPath().path
        let path = absoluteURL.resolvingSymlinksInPath().path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// The value to persist in `books.cover_url` for `url`: a relative path when
    /// `url` lives under Application Support, otherwise the URL's own string
    /// (covers the remote-cover case unchanged).
    public static func storedValue(
        for url: URL,
        applicationSupport: URL? = nil,
        fileManager: FileManager = .default
    ) -> String {
        relativePath(for: url, applicationSupport: applicationSupport, fileManager: fileManager)
            ?? url.absoluteString
    }

    /// Re-resolves a persisted `books.cover_url` value to a usable URL:
    ///  - `http`/`https` values pass through unchanged;
    ///  - a relative value is re-anchored on the current Application Support
    ///    directory;
    ///  - a legacy absolute `file://` value under Application Support is
    ///    converted to its relative tail and re-anchored (handles the pre-fix
    ///    rows and a changed container UUID); other absolute `file://` values
    ///    are rebased via `ContainerPathRebase`.
    /// When the resolved path is missing but a file with the same name exists in
    /// the expected directory, that file is used (changed-container repair).
    public static func resolve(
        _ stored: String,
        applicationSupport: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return url
        }

        let base = applicationSupport ?? applicationSupportDirectory(fileManager: fileManager)

        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
            if fileManager.fileExists(atPath: url.path) { return url }
            if let tail = applicationSupportTail(ofAbsolutePath: url.path) {
                return anchored(relativePath: tail, base: base, fileManager: fileManager)
            }
            let rebased = ContainerPathRebase.rebase(url, fileManager: fileManager)
            return fileManager.fileExists(atPath: rebased.path) ? rebased : url
        }

        return anchored(relativePath: trimmed, base: base, fileManager: fileManager)
    }

    /// The portion of an absolute path after `…/Application Support/`, percent
    /// tolerated either way. Nil when the marker is absent.
    private static func applicationSupportTail(ofAbsolutePath path: String) -> String? {
        for marker in ["/Application Support/", "/Application%20Support/"] {
            if let range = path.range(of: marker, options: .backwards), range.upperBound < path.endIndex {
                return String(path[range.upperBound...])
            }
        }
        return nil
    }

    private static func anchored(relativePath rel: String, base: URL, fileManager: FileManager) -> URL {
        let decoded = rel.removingPercentEncoding ?? rel
        let candidate = base.appendingPathComponent(decoded)
        if fileManager.fileExists(atPath: candidate.path) { return candidate }
        // Same-basename repair inside the expected directory.
        let directory = candidate.deletingLastPathComponent()
        let name = candidate.lastPathComponent
        if let entries = try? fileManager.contentsOfDirectory(atPath: directory.path),
           entries.contains(name) {
            return candidate
        }
        // Return the best-effort candidate anyway; the artwork layer falls back
        // to the generated placeholder when the file genuinely isn't there.
        return candidate
    }
}
