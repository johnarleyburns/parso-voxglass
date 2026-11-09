import Foundation
import CryptoKit

/// Portable, path-free identity of a local audiobook's audio bytes.
public struct LocalMediaFingerprint: Equatable, Sendable {
    public static let currentScheme = "local-media-v1"

    public let scheme: String
    public let bookDigest: String
    /// Ordered logical-chapter digests.
    public let chapterDigests: [String]

    public init(scheme: String = LocalMediaFingerprint.currentScheme, bookDigest: String, chapterDigests: [String]) {
        self.scheme = scheme
        self.bookDigest = bookDigest
        self.chapterDigests = chapterDigests
    }
}

public enum LocalMediaIdentity {
    public static func contentKey(_ value: LocalMediaFingerprint) -> String {
        "local-media:v1:\(value.bookDigest)"
    }
}

public enum LocalMediaFingerprintResult: Equatable, Sendable {
    case fingerprinted(LocalMediaFingerprint, fromCache: Bool)
    /// A file is missing/inaccessible, or the book has no local audio. No identity is invented.
    case pending(reason: String)
}

/// Streams a file's bytes into SHA-256. Injectable so tests can prove reuse.
public protocol LocalMediaFileHasher: Sendable {
    func sha256Hex(of url: URL) throws -> String
}

/// Maps stored chapter locations to a readable file, or nil when unavailable.
public protocol LocalMediaFileResolver: Sendable {
    func resolve(localURL: URL?, bookmark: Data?) -> URL?
}

public struct SystemLocalMediaFileHasher: LocalMediaFileHasher {
    public init() {}
    public func sha256Hex(of url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct SystemLocalMediaFileResolver: LocalMediaFileResolver {
    public init() {}
    public func resolve(localURL: URL?, bookmark: Data?) -> URL? {
        if let bookmark, let resolved = PlaybackSourceResolver.resolveBookmarkData(bookmark),
           FileManager.default.fileExists(atPath: resolved.url.path) {
            return resolved.url
        }
        guard let localURL else { return nil }
        let rebased = ContainerPathRebase.rebase(localURL)
        return FileManager.default.fileExists(atPath: rebased.path) ? rebased : nil
    }
}

/// Computes and caches `local-media-v1` fingerprints. Runs on its own actor
/// (never the main actor). Only writes to `local_media_fingerprints`.
public actor LocalMediaFingerprintService {
    private let database: AppDatabase
    private let hasher: any LocalMediaFileHasher
    private let resolver: any LocalMediaFileResolver
    private let clock: any Clock

    public init(
        database: AppDatabase,
        hasher: any LocalMediaFileHasher = SystemLocalMediaFileHasher(),
        resolver: any LocalMediaFileResolver = SystemLocalMediaFileResolver(),
        clock: any Clock = SystemClock()
    ) {
        self.database = database
        self.hasher = hasher
        self.resolver = resolver
        self.clock = clock
    }

    /// Book IDs of local-file audiobooks only; remote/catalog books are never candidates.
    public func candidateBookIDs() async throws -> [String] {
        try await database.prepare()
        return try await database.query(
            """
            SELECT b.id FROM books b JOIN sources s ON s.id = b.source_id
            WHERE s.kind = ? ORDER BY b.created_at, b.id
            """,
            [.string(SourceKind.localFiles.rawValue)]
        ).compactMap { $0.string("id") }
    }

    /// Fingerprints every candidate; cancellation stops the loop and propagates.
    public func fingerprintAllCandidates() async throws -> [String: LocalMediaFingerprintResult] {
        var results: [String: LocalMediaFingerprintResult] = [:]
        for id in try await candidateBookIDs() {
            try Task.checkCancellation()
            results[id] = try await fingerprint(bookID: id)
        }
        return results
    }

    public func cachedFingerprint(bookID: String) async throws -> LocalMediaFingerprint? {
        try await database.prepare()
        let rows = try await database.query(
            "SELECT scheme, book_digest, manifest_json FROM local_media_fingerprints WHERE book_id = ?",
            [.string(bookID)]
        )
        guard let row = rows.first, row.string("scheme") == LocalMediaFingerprint.currentScheme,
              let digest = row.string("book_digest"),
              let json = row.string("manifest_json"),
              let digests = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) else { return nil }
        return LocalMediaFingerprint(bookDigest: digest, chapterDigests: digests)
    }

    public func fingerprint(bookID: String) async throws -> LocalMediaFingerprintResult {
        if let cached = try await cachedFingerprint(bookID: bookID) {
            return .fingerprinted(cached, fromCache: true)
        }
        let rows = try await database.query(
            """
            SELECT c.chapter_index, c.start_time_seconds, c.duration_seconds, c.local_url, c.local_bookmark
            FROM chapters c JOIN books b ON b.id = c.book_id JOIN sources s ON s.id = b.source_id
            WHERE c.book_id = ? AND s.kind = ?
            ORDER BY c.chapter_index, c.sort_key
            """,
            [.string(bookID), .string(SourceKind.localFiles.rawValue)]
        )
        guard !rows.isEmpty else { return .pending(reason: "No local audio chapters") }

        // Group chapters by physical file (stored location is only a grouping key,
        // never fingerprint material), hashing each unique file exactly once.
        var ordinalByLocation: [String: Int] = [:]
        var fileDigests: [String] = []
        var lines: [(ordinal: Int, index: Int64, start: Int64, duration: String)] = []
        for row in rows {
            try Task.checkCancellation()
            let localURL = row.string("local_url").flatMap(URL.init(string:))
            guard let file = resolver.resolve(localURL: localURL, bookmark: ModelMapping.data(row, "local_bookmark")) else {
                return .pending(reason: "Audio file unavailable")
            }
            let location = file.standardizedFileURL.path
            let ordinal: Int
            if let known = ordinalByLocation[location] {
                ordinal = known
            } else {
                let digest: String
                do { digest = try hasher.sha256Hex(of: file) } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    return .pending(reason: "Audio file unreadable")
                }
                ordinal = fileDigests.count
                ordinalByLocation[location] = ordinal
                fileDigests.append(digest)
            }
            lines.append((
                ordinal,
                row.int("chapter_index") ?? 0,
                Self.millis(row.double("start_time_seconds") ?? 0),
                row.double("duration_seconds").map { String(Self.millis($0)) } ?? "none"
            ))
        }

        let chapterDigests = lines.map { line in
            SHA256Hex.hex(Data(
                "chapter|\(line.index)|\(fileDigests[line.ordinal])|\(line.ordinal)|\(line.start)|\(line.duration)".utf8
            ))
        }
        let bookDigest = SHA256Hex.hex(Data(
            ([LocalMediaFingerprint.currentScheme] + chapterDigests).joined(separator: "\n").utf8
        ))
        let fingerprint = LocalMediaFingerprint(bookDigest: bookDigest, chapterDigests: chapterDigests)
        let manifest = String(decoding: try JSONEncoder().encode(chapterDigests), as: UTF8.self)
        try Task.checkCancellation()
        try await database.execute(
            """
            INSERT OR REPLACE INTO local_media_fingerprints (book_id, scheme, book_digest, manifest_json, computed_at)
            VALUES (?, ?, ?, ?, ?)
            """,
            [.string(bookID), .string(fingerprint.scheme), .string(bookDigest), .string(manifest),
             .double(clock.now.timeIntervalSince1970)]
        )
        return .fingerprinted(fingerprint, fromCache: false)
    }

    private static func millis(_ seconds: Double) -> Int64 { Int64((seconds * 1000).rounded()) }
}
