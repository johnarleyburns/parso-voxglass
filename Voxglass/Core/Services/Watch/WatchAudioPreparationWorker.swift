import Foundation
import AVFoundation
import VoxglassWatchProtocol
import VoxglassWatchCore

/// One ordinary (non Read-with-AI) chapter to prepare. Plain immutable values only.
public struct OrdinaryWatchChapterInput: Sendable, Equatable {
    public let chapterID: UUID
    public let chapterKey: String
    public let index: Int
    public let title: String
    public let source: URL
    public let startTime: Double
    public let duration: Double?
    public let mimeType: String?

    public init(chapterID: UUID, chapterKey: String, index: Int, title: String, source: URL,
                startTime: Double, duration: Double?, mimeType: String?) {
        self.chapterID = chapterID; self.chapterKey = chapterKey; self.index = index
        self.title = title; self.source = source; self.startTime = startTime
        self.duration = duration; self.mimeType = mimeType
    }
}

public struct OrdinaryWatchPreparationInput: Sendable, Equatable {
    public let bookID: UUID
    public let chapters: [OrdinaryWatchChapterInput]
    /// Disposable derived-output directory (`WatchAAC96`).
    public let directory: URL

    public init(bookID: UUID, chapters: [OrdinaryWatchChapterInput], directory: URL) {
        self.bookID = bookID; self.chapters = chapters; self.directory = directory
    }
}

public struct PreparedWatchChapter: Sendable, Equatable {
    public let chapterID: UUID
    public let chapterKey: String
    public let url: URL
    public let bytes: Int64
    public let sha256: String
    public var duration: Double = 0
}

public struct PreparedWatchArtwork: Sendable, Equatable {
    public let url: URL
    public let bytes: Int64
    public let hash: String

    public init(url: URL, bytes: Int64, hash: String) {
        self.url = url; self.bytes = bytes; self.hash = hash
    }
}

/// Complete, immutable result. It exists only when every chapter was prepared.
public struct PreparedWatchBook: Sendable, Equatable {
    public let chapters: [WatchChapterDTO]
    public let files: [PreparedWatchChapter]
    public let artwork: PreparedWatchArtwork?
}

/// Tracks the newest preparation generation per book so a result produced for an
/// older submission can be discarded by the UI-side owner before any commit.
public struct WatchPreparationGenerations: Sendable {
    private var current: [UUID: Int] = [:]
    public init() {}

    public mutating func begin(_ bookID: UUID) -> Int {
        let next = (current[bookID] ?? 0) + 1
        current[bookID] = next
        return next
    }

    public func isCurrent(_ generation: Int, for bookID: UUID) -> Bool {
        current[bookID] == generation
    }
}

/// Prepares ordinary audio off the main thread. It holds no reference to the
/// phone relay or the watch session; AV reader/writer consumption stays inside
/// `WatchChapterTransfer`'s conversion queue. Chapters run serially.
public actor WatchAudioPreparationWorker {
    public struct Dependencies: Sendable {
        public var hash: @Sendable (URL) async throws -> String
        public var prepareAAC: @Sendable (OrdinaryWatchChapterInput, URL, String) async throws -> URL
        public var fileInfo: @Sendable (URL) async throws -> (bytes: Int64, sha256: String, duration: Double)
        public var artwork: @Sendable (URL) async -> PreparedWatchArtwork?
        /// Converts a rendered narration PCM file: (pcm, directory, pcmHash, bitRate, formatID).
        public var convertPCM: @Sendable (URL, URL, String, Int, AudioFormatID) async throws -> URL

        public init(
            hash: @escaping @Sendable (URL) async throws -> String,
            prepareAAC: @escaping @Sendable (OrdinaryWatchChapterInput, URL, String) async throws -> URL,
            fileInfo: @escaping @Sendable (URL) async throws -> (bytes: Int64, sha256: String, duration: Double),
            artwork: @escaping @Sendable (URL) async -> PreparedWatchArtwork?,
            convertPCM: @escaping @Sendable (URL, URL, String, Int, AudioFormatID) async throws -> URL = Dependencies.liveConvertPCM
        ) {
            self.hash = hash; self.prepareAAC = prepareAAC; self.fileInfo = fileInfo; self.artwork = artwork
            self.convertPCM = convertPCM
        }

        public static let liveConvertPCM: @Sendable (URL, URL, String, Int, AudioFormatID) async throws -> URL = {
            pcm, directory, hash, bitRate, formatID in
            try await WatchChapterTransfer.prepareAAC(
                source: pcm, directory: directory, sourceHash: hash,
                bitRate: bitRate, formatID: formatID)
        }

        public static func live(artwork: @escaping @Sendable (URL) async -> PreparedWatchArtwork?) -> Dependencies {
            Dependencies(
                hash: { source in
                    try await Task.detached {
                        let accessed = source.startAccessingSecurityScopedResource()
                        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
                        return try WatchChecksum.sha256(of: source)
                    }.value
                },
                prepareAAC: { chapter, directory, hash in
                    try await WatchChapterTransfer.prepareAAC(
                        source: chapter.source, directory: directory,
                        startTime: max(0, chapter.startTime),
                        duration: chapter.duration.flatMap { $0 > 0 ? $0 : nil },
                        sourceHash: hash, mimeType: chapter.mimeType)
                },
                fileInfo: { url in
                    let size = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                    let checksum = try await Task.detached { try WatchChecksum.sha256(of: url) }.value
                    let duration = try await AVURLAsset(url: url).load(.duration).seconds
                    return (size, checksum, duration)
                },
                artwork: artwork)
        }
    }

    private let dependencies: Dependencies

    public init(dependencies: Dependencies) { self.dependencies = dependencies }

    public func prepare(
        _ input: OrdinaryWatchPreparationInput,
        progress: @Sendable (WatchPreparationProgress) async -> Void
    ) async throws -> PreparedWatchBook {
        do {
            var sourceHashes: [URL: String] = [:]
            var dtos: [WatchChapterDTO] = []
            var files: [PreparedWatchChapter] = []
            for (offset, chapter) in input.chapters.enumerated() {
                try Task.checkCancellation()
                await progress(WatchPreparationProgress(
                    bookID: input.bookID, phase: .preparing,
                    completed: offset, total: input.chapters.count,
                    detail: "Preparing chapter \(offset + 1) of \(input.chapters.count): \(chapter.title). Keep Voxglass open until preparation finishes."))
                let hash: String
                if let cached = sourceHashes[chapter.source] { hash = cached }
                else {
                    hash = try await dependencies.hash(chapter.source)
                    sourceHashes[chapter.source] = hash
                }
                let url = try await dependencies.prepareAAC(chapter, input.directory, hash)
                let info = try await dependencies.fileInfo(url)
                dtos.append(WatchChapterDTO(
                    id: WatchChapterID(chapter.chapterID.uuidString), index: chapter.index,
                    title: chapter.title, duration: info.duration, startTime: 0,
                    expectedBytes: info.bytes, expectedSHA256: info.sha256,
                    durableFilename: "\(chapter.chapterID.uuidString).m4a"))
                files.append(PreparedWatchChapter(chapterID: chapter.chapterID, chapterKey: chapter.chapterKey,
                                                  url: url, bytes: info.bytes, sha256: info.sha256, duration: info.duration))
            }
            try Task.checkCancellation()
            // Artwork is nonfatal: nil simply means no cover is sent.
            let artwork = await dependencies.artwork(input.directory)
            try Task.checkCancellation()
            return PreparedWatchBook(chapters: dtos, files: files, artwork: artwork)
        } catch {
            Self.removeDisposablePreparingFiles(in: input.directory)
            throw error
        }
    }

    /// Converts an already-rendered narration PCM file (AAC-LC at 48 kbps only)
    /// and assembles its chapter record. Runs on this actor, never on MainActor.
    /// Cancellation or failure removes only unfinished `.preparing` derivatives.
    func prepareNarrationPCM(
        _ pcm: URL, chapterID: UUID, chapterKey: String, directory: URL
    ) async throws -> PreparedWatchChapter {
        do {
            try Task.checkCancellation()
            let hash = try await dependencies.hash(pcm)
            let url = try await dependencies.convertPCM(
                pcm, directory, hash, WatchNarrationEstimate.watchAACLCBitRate, kAudioFormatMPEG4AAC)
            try Task.checkCancellation()
            let info = try await dependencies.fileInfo(url)
            try Task.checkCancellation()
            return PreparedWatchChapter(chapterID: chapterID, chapterKey: chapterKey,
                                        url: url, bytes: info.bytes, sha256: info.sha256, duration: info.duration)
        } catch {
            Self.removeDisposablePreparingFiles(in: directory)
            throw error
        }
    }

    /// Inspects an already-finished cached narration file without re-rendering speech.
    func prepareCachedNarration(_ url: URL, chapterID: UUID, chapterKey: String) async throws -> PreparedWatchChapter {
        try Task.checkCancellation()
        let info = try await dependencies.fileInfo(url)
        return PreparedWatchChapter(chapterID: chapterID, chapterKey: chapterKey,
                                    url: url, bytes: info.bytes, sha256: info.sha256, duration: info.duration)
    }

    /// Removes only unfinished `.preparing` derivatives; originals and finished AAC stay.
    private static func removeDisposablePreparingFiles(in directory: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasSuffix(".preparing") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
