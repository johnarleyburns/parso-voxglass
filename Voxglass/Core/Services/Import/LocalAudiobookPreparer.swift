import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Prepares a user-selected local audiobook folder off the main actor. The
/// audio file stays at its original path; only a security-scoped bookmark and
/// small cover image are retained by the library import.
public enum LocalAudiobookPreparer {
    public struct Prepared: Sendable {
        public let folderName: String
        public let audioURL: URL
        public let bookmark: Data
        public let markers: [LocalChapterMarker]
        public let audioDuration: TimeInterval
        public let coverURL: URL?

        public init(folderName: String, audioURL: URL, bookmark: Data, markers: [LocalChapterMarker], audioDuration: TimeInterval, coverURL: URL?) {
            self.folderName = folderName
            self.audioURL = audioURL
            self.bookmark = bookmark
            self.markers = markers
            self.audioDuration = audioDuration
            self.coverURL = coverURL
        }
    }

    public static func prepare(folderURL: URL) async throws -> Prepared {
        let files = try localFiles(in: folderURL)
        guard let audioURL = files.first(where: { AudioFormatSelection.allPlayableExtensions.contains($0.pathExtension.lowercased()) }) else {
            throw LocalAudiobookImportError.missingAudio
        }
        guard let textURL = files.first(where: { $0.pathExtension.lowercased() == "txt" }) else {
            throw LocalAudiobookImportError.missingChapterText
        }

        let markers = try LocalChapterParser.parse(String(contentsOf: textURL, encoding: .utf8))
        let asset = AVURLAsset(url: audioURL)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard duration.isFinite, let lastMarker = markers.last, duration > lastMarker.startTime else {
            throw LocalAudiobookImportError.invalidChapterTiming
        }

        let bookmark = try audioURL.bookmarkData()
        let coverSource = files.first { url in
            guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return type.conforms(to: .image)
        }
        let coverURL = coverSource.flatMap { try? copyCoverIntoApplicationSupport($0) }
        return Prepared(
            folderName: audioURL.deletingPathExtension().lastPathComponent,
            audioURL: audioURL,
            bookmark: bookmark,
            markers: markers,
            audioDuration: duration,
            coverURL: coverURL
        )
    }

    private static func copyCoverIntoApplicationSupport(_ sourceURL: URL) throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Voxglass/LocalArtwork", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("\(UUID().uuidString).\(sourceURL.pathExtension)")
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    private static func localFiles(in folderURL: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: folderURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL, (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            return url
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

public enum LocalAudiobookImportError: LocalizedError, Sendable, Equatable {
    case missingAudio
    case missingChapterText
    case invalidChapterTiming

    public var errorDescription: String? {
        switch self {
        case .missingAudio: return "No supported audio file was found in that folder."
        case .missingChapterText: return "No chapter text file was found in that folder."
        case .invalidChapterTiming: return "The chapter timestamps do not fit within the selected audio file."
        }
    }
}
