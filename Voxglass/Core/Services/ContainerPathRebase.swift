import Foundation

/// Rebases stale absolute `file://` URLs onto the current sandbox container
/// (Phase D of docs/MINIPLAYER_RESTORE_PLAN.md). iOS moves the app's data
/// container on every app update, so any absolute path persisted before the
/// update goes stale. For a file URL whose file no longer exists, the path is
/// split on the *last* well-known sandbox root component and the suffix is
/// re-anchored on the current container's matching root. Pure and injectable,
/// so it is unit-testable with temp directories.
public enum ContainerPathRebase {
    public struct Root {
        /// The path component that identifies the sandbox root, with leading and
        /// trailing slashes (e.g. "/Documents/").
        public let marker: String
        /// The current container's directory for that root.
        public let base: URL

        public init(marker: String, base: URL) {
            self.marker = marker
            self.base = base
        }
    }

    /// The current container's well-known roots, in match-priority order.
    public static func defaultRoots(fileManager: FileManager = .default) -> [Root] {
        var roots: [Root] = []
        if let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            roots.append(Root(marker: "/Documents/", base: documents))
        }
        if let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            roots.append(Root(marker: "/Library/Application Support/", base: support))
        }
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            roots.append(Root(marker: "/Library/Caches/", base: caches))
        }
        return roots
    }

    /// Returns a URL whose file exists after re-anchoring, or the original URL
    /// when it exists, is not a file URL, no root marker matches, or the rebased
    /// candidate is missing too.
    public static func rebase(
        _ url: URL,
        roots: [Root]? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        guard url.isFileURL else { return url }
        let path = url.path
        guard !fileManager.fileExists(atPath: path) else { return url }

        for root in roots ?? defaultRoots(fileManager: fileManager) {
            guard let range = path.range(of: root.marker, options: .backwards),
                  range.upperBound < path.endIndex else { continue }
            let suffix = String(path[range.upperBound...])
            let candidate = root.base.appendingPathComponent(suffix)
            guard candidate.path != path else { continue }
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return url
    }
}
