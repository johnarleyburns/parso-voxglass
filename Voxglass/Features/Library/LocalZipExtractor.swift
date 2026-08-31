import Foundation
import ZIPFoundation

/// Extracts a local ZIP archive without loading the archive or its entries into memory.
enum LocalZipExtractor {
    private static let bufferSize = 1024 * 1024

    static func extract(_ archiveURL: URL) throws -> URL {
        let accessing = archiveURL.startAccessingSecurityScopedResource()
        defer { if accessing { archiveURL.stopAccessingSecurityScopedResource() } }

        let archive: Archive
        do {
            archive = try Archive(url: archiveURL, accessMode: .read)
        } catch {
            throw LocalZipError.invalidArchive
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxglass-zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        do {
            for entry in archive {
                let destination = try destinationURL(for: entry, in: root)
                guard entry.type != .symlink else {
                    throw LocalZipError.unsupportedArchive
                }

                let checksum = try archive.extract(
                    entry,
                    to: destination,
                    bufferSize: bufferSize,
                    skipCRC32: false,
                    allowUncontainedSymlinks: false
                )
                guard checksum == entry.checksum else {
                    throw LocalZipError.invalidArchive
                }
            }
            return root
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private static func destinationURL(for entry: Entry, in root: URL) throws -> URL {
        let normalized = entry.path.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.hasPrefix("/") else {
            throw LocalZipError.invalidArchive
        }

        let parts = normalized.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty,
              parts.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw LocalZipError.invalidArchive
        }

        return parts.enumerated().reduce(root) { partial, component in
            let isDirectory = entry.type == .directory && component.offset == parts.count - 1
            return partial.appendingPathComponent(String(component.element), isDirectory: isDirectory)
        }
    }
}

enum LocalZipError: LocalizedError {
    case invalidArchive
    case unsupportedArchive

    var errorDescription: String? {
        switch self {
        case .invalidArchive:
            return "The selected ZIP file is not a valid audiobook archive."
        case .unsupportedArchive:
            return "This ZIP archive uses a feature Voxglass cannot import."
        }
    }
}
