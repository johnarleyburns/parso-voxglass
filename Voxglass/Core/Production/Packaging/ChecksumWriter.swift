import Foundation

/// Writes `shasum -a 256 -c`-compatible checksum manifests (§16.10). The
/// format is deliberately the coreutils one (`<sha256>␣␣<filename>\n`) so the
/// user can verify a transfer with the standard tool on any platform.
public struct ChecksumWriter: Sendable {

    public init() {}

    /// The manifest bytes for `files`, one `<sha256>  <name>` line per file.
    /// The hash is read from the file on disk; a mismatch with `file.sha256`
    /// (or a missing hash) is resolved by re-reading the file, so the manifest
    /// is always truthful even if the caller's metadata was stale.
    public func sha256Manifest(_ files: [ExportedFile]) throws -> Data {
        var lines: [String] = []
        for file in files {
            let digest = try SHA256Hex.hex(contentsOf: file.url)
            lines.append("\(digest)  \(file.url.lastPathComponent)")
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}
