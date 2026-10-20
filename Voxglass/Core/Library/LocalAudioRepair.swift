import AVFoundation
import Foundation
import os
import UniformTypeIdentifiers

/// Repository-provided classification of a book's audio source, used by
/// playback to tell "local import lost its file" from "remote source missing".
public struct LocalSourceContext: Equatable, Sendable {
    /// `sources.kind = localFiles` or `books.content_key` starts `local:`.
    public let isLocalImport: Bool
    /// True when any chapter still carries a local URL or bookmark.
    public let hasLocalBinding: Bool

    public init(isLocalImport: Bool, hasLocalBinding: Bool) {
        self.isLocalImport = isLocalImport
        self.hasLocalBinding = hasLocalBinding
    }
}

/// Typed result of a book-scoped local audio repair. Everything except
/// `.success` leaves every database row untouched.
public enum LocalAudioRepairOutcome: Equatable, Sendable {
    /// Nothing was written: the proposed mapping awaiting user confirmation.
    case preview(LocalAudioRepairPreview)
    case success(repaired: Int)
    case noMatch
    case ambiguous(chapterIDs: [UUID])
    case incompleteMapping
    case invalidDuration
    case denied
    case cancelled
    case error
}

public struct LocalAudioRepairPreview: Equatable, Sendable {
    public enum Layout: Equatable, Sendable {
        /// One audio file holds every chapter (offsets preserved).
        case sharedFile
        case multiFile
    }

    public var layout: Layout
    /// Audio files reachable through the selection.
    public var candidates: [URL]
    /// Chapters with exactly one candidate.
    public var proposed: [UUID: URL]
    /// Chapters with more than one candidate; need explicit picker mapping.
    public var ambiguous: [UUID: [URL]]
    /// Chapters with no candidate; need explicit picker mapping.
    public var unmatched: [UUID]

    public var isComplete: Bool { ambiguous.isEmpty && unmatched.isEmpty }
}

/// Seams for the I/O a repair performs while it holds security-scoped access.
public struct LocalAudioRepairEnvironment: Sendable {
    public var access: any SecurityScopedAccessing
    public var makeBookmark: @Sendable (URL) throws -> Data
    public var probeDuration: @Sendable (URL) async -> TimeInterval?
    public var isSupportedAudio: @Sendable (URL) -> Bool
    /// Test seam: appends a failing statement to the repair transaction.
    public var injectTransactionFailure: Bool

    public init(
        access: any SecurityScopedAccessing,
        makeBookmark: @escaping @Sendable (URL) throws -> Data,
        probeDuration: @escaping @Sendable (URL) async -> TimeInterval?,
        isSupportedAudio: @escaping @Sendable (URL) -> Bool,
        injectTransactionFailure: Bool = false
    ) {
        self.access = access
        self.makeBookmark = makeBookmark
        self.probeDuration = probeDuration
        self.isSupportedAudio = isSupportedAudio
        self.injectTransactionFailure = injectTransactionFailure
    }

    public static let system = LocalAudioRepairEnvironment(
        access: SystemSecurityScopedAccess(),
        makeBookmark: { try $0.bookmarkData() },
        probeDuration: { url in
            guard let time = try? await AVURLAsset(url: url).load(.duration) else { return nil }
            return time.seconds
        },
        isSupportedAudio: { url in
            AudioFormatSelection.allPlayableExtensions.contains(url.pathExtension.lowercased())
        }
    )
}

private let repairLog = Logger(subsystem: "guru.parso.voxglass", category: "local-audio-repair")

extension LibraryRepository {
    /// Classifies a book as a local import (never every nil-URL chapter).
    public func localSourceContext(bookID: UUID) async -> LocalSourceContext? {
        do {
            try await database.prepare()
            let rows = try await database.query("""
            SELECT s.kind AS kind, b.content_key AS content_key,
                   (SELECT COUNT(*) FROM chapters c WHERE c.book_id = b.id
                      AND (c.local_url IS NOT NULL OR c.local_bookmark IS NOT NULL)) AS bound
            FROM books b JOIN sources s ON s.id = b.source_id
            WHERE b.id = ?
            """, [ModelMapping.databaseValue(bookID)])
            guard let row = rows.first else { return nil }
            let isLocal = row.string("kind") == SourceKind.localFiles.rawValue
                || (row.string("content_key") ?? "").hasPrefix("local:")
            let bound = (row.int("bound") ?? 0) > 0
            repairLog.info("local classification isLocal=\(isLocal, privacy: .public) bindingPresent=\(bound, privacy: .public)")
            return LocalSourceContext(isLocalImport: isLocal, hasLocalBinding: bound)
        } catch {
            return nil
        }
    }

    /// Book-scoped repair of missing local chapter bindings. With `mapping`
    /// nil it only returns a `.preview` (the user must confirm); with a
    /// complete chapterID→file `mapping` it validates everything while holding
    /// security-scoped access to `selection`, then commits atomically. Only
    /// `local_url`/`local_bookmark` of the chosen book's chapters change.
    public func repairLocalAudio(
        bookID: UUID,
        selection: URL,
        mapping: [UUID: URL]?
    ) async -> LocalAudioRepairOutcome {
        let env = localRepairEnvironment
        let outcome = await performLocalAudioRepair(bookID: bookID, selection: selection, mapping: mapping, env: env)
        switch outcome {
        case .success(let count): repairLog.info("repair outcome=success count=\(count, privacy: .public)")
        case .preview: repairLog.info("repair outcome=preview")
        default: repairLog.info("repair outcome=\(String(describing: outcome).prefix(24), privacy: .public)")
        }
        return outcome
    }

    private func performLocalAudioRepair(
        bookID: UUID, selection: URL, mapping: [UUID: URL]?, env: LocalAudioRepairEnvironment
    ) async -> LocalAudioRepairOutcome {
        guard env.access.startAccessing(selection) else { return .denied }
        defer { env.access.stopAccessing(selection) }
        do {
            try Task.checkCancellation()
            guard let context = await localSourceContext(bookID: bookID), context.isLocalImport,
                  let book = try await bookWithChapters(forBookID: bookID), !book.chapters.isEmpty
            else { return .noMatch }
            let keyRows = try await database.query(
                "SELECT id, content_key FROM chapters WHERE book_id = ?", [ModelMapping.databaseValue(bookID)]
            )
            var keys: [UUID: String] = [:]
            for row in keyRows {
                if let id = row.string("id").flatMap(UUID.init(uuidString:)), let key = row.string("content_key") {
                    keys[id] = key
                }
            }
            let chapters = book.chapters
            let shared = chapters.count > 1 && chapters.contains { $0.startTime > 0 }
            let candidates = Self.audioCandidates(in: selection, env: env)
            if candidates.isEmpty { return .noMatch }

            guard let mapping else {
                var preview = Self.makePreview(chapters: chapters, keys: keys, candidates: candidates, shared: shared)
                preview.candidates = candidates
                return .preview(preview)
            }
            return try await commit(
                chapters: chapters, shared: shared, selection: selection, candidates: candidates,
                mapping: mapping, env: env
            )
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .error
        }
    }

    private func commit(
        chapters: [Chapter], shared: Bool, selection: URL, candidates: [URL],
        mapping: [UUID: URL], env: LocalAudioRepairEnvironment
    ) async throws -> LocalAudioRepairOutcome {
        guard Set(mapping.keys) == Set(chapters.map(\.id)) else { return .incompleteMapping }
        let allowed = Set(candidates.map(Self.canonical))
        guard mapping.values.allSatisfy({ allowed.contains(Self.canonical($0)) }) else { return .noMatch }
        let files = Set(mapping.values.map(Self.canonical))

        if shared {
            guard files.count == 1, let file = mapping.values.first else { return .incompleteMapping }
            guard let duration = await env.probeDuration(file), duration.isFinite, duration > 0 else {
                return .invalidDuration
            }
            let maxStart = chapters.map(\.startTime).max() ?? 0
            let end = chapters.map { $0.startTime + ($0.duration ?? 0) }.max() ?? 0
            guard duration > maxStart, duration + 1 >= end else { return .invalidDuration }
        } else if files.count != mapping.count {
            // Two chapters bound to one file would silently replay the same audio.
            return .ambiguous(chapterIDs: mapping.keys.sorted { $0.uuidString < $1.uuidString })
        }

        try Task.checkCancellation()
        var bookmarks: [URL: Data] = [:]
        for file in files {
            let fm = FileManager.default
            guard fm.fileExists(atPath: file.path), fm.isReadableFile(atPath: file.path),
                  env.isSupportedAudio(file) else { return .noMatch }
            guard let bookmark = try? env.makeBookmark(file) else { return .denied }
            bookmarks[file] = bookmark
        }
        var statements: [(sql: String, bindings: [DatabaseValue])] = []
        for chapter in chapters {
            guard let url = mapping[chapter.id], let bookmark = bookmarks[Self.canonical(url)] else {
                return .incompleteMapping
            }
            statements.append((
                "UPDATE chapters SET local_url = ?, local_bookmark = ? WHERE id = ? AND book_id = ?",
                [
                    ModelMapping.databaseValue(url), ModelMapping.databaseValue(bookmark),
                    ModelMapping.databaseValue(chapter.id), ModelMapping.databaseValue(chapter.bookID)
                ]
            ))
        }
        if env.injectTransactionFailure {
            statements.append(("UPDATE repair_fault_injection SET x = 1", []))
        }
        try Task.checkCancellation()
        do {
            try await database.executeBatch(statements)
        } catch {
            return .error
        }
        return .success(repaired: chapters.count)
    }

    static func canonical(_ url: URL) -> URL {
        URL(fileURLWithPath: url.path).standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func audioCandidates(in selection: URL, env: LocalAudioRepairEnvironment) -> [URL] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: selection.path, isDirectory: &isDirectory) else { return [] }
        if !isDirectory.boolValue {
            return env.isSupportedAudio(selection) ? [selection] : []
        }
        guard let enumerator = fm.enumerator(
            at: selection, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { env.isSupportedAudio($0) && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.path < $1.path }
    }

    /// Matching never uses directory or array order: filename stem against the
    /// chapter content key, then against the normalized chapter title, and a
    /// chapter is proposed only when exactly one file matches and no other
    /// chapter claims the same file.
    private static func makePreview(
        chapters: [Chapter], keys: [UUID: String], candidates: [URL], shared: Bool
    ) -> LocalAudioRepairPreview {
        var preview = LocalAudioRepairPreview(
            layout: shared ? .sharedFile : .multiFile,
            candidates: candidates, proposed: [:], ambiguous: [:], unmatched: []
        )
        if shared {
            if candidates.count == 1, let only = candidates.first {
                for chapter in chapters { preview.proposed[chapter.id] = only }
            } else {
                for chapter in chapters { preview.ambiguous[chapter.id] = candidates }
            }
            return preview
        }
        let stems = candidates.map { (url: $0, stem: ContentKey.normalize($0.deletingPathExtension().lastPathComponent)) }
        var matches: [UUID: [URL]] = [:]
        for chapter in chapters {
            var found: [URL] = []
            if let key = keys[chapter.id], !key.isEmpty, !key.hasPrefix("idx:") {
                found = stems.filter { $0.stem == key }.map(\.url)
            }
            if found.isEmpty {
                let title = ContentKey.normalize(chapter.title)
                if !title.isEmpty { found = stems.filter { $0.stem == title }.map(\.url) }
            }
            matches[chapter.id] = found
        }
        var claims: [URL: Int] = [:]
        for urls in matches.values where urls.count == 1 { claims[canonical(urls[0]), default: 0] += 1 }
        for chapter in chapters {
            let urls = matches[chapter.id] ?? []
            if urls.isEmpty {
                preview.unmatched.append(chapter.id)
            } else if urls.count > 1 || claims[canonical(urls[0]), default: 0] > 1 {
                preview.ambiguous[chapter.id] = urls
            } else {
                preview.proposed[chapter.id] = urls[0]
            }
        }
        return preview
    }
}
