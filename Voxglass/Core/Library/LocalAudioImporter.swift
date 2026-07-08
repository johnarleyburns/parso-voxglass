import AVFoundation
import Foundation
import UniformTypeIdentifiers

struct LocalAudioImporter {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func importAudio(from urls: [URL]) async throws -> [ImportedAudioFile] {
        var imported: [ImportedAudioFile] = []
        for url in urls {
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let expanded = try audioFiles(in: url)
            for fileURL in expanded {
                imported.append(try await importAudioFile(fileURL))
            }
        }
        return imported
    }

    private func audioFiles(in url: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return []
        }

        if isDirectory.boolValue {
            let contents = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            return contents
                .filter { Self.isSupportedAudioURL($0) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }

        return Self.isSupportedAudioURL(url) ? [url] : []
    }

    private func importAudioFile(_ sourceURL: URL) async throws -> ImportedAudioFile {
        let destinationDirectory = try localAudioDirectory()
        let destinationURL = uniqueDestinationURL(for: sourceURL, in: destinationDirectory)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)

        let asset = AVURLAsset(url: destinationURL)
        let duration = try? await asset.load(.duration).seconds
        let title = sourceURL.deletingPathExtension().lastPathComponent
        return ImportedAudioFile(
            title: title.isEmpty ? "Untitled Audio" : title,
            localURL: destinationURL,
            duration: duration?.isFinite == true ? duration : nil
        )
    }

    private func localAudioDirectory() throws -> URL {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("Voxglass", isDirectory: true)
        .appendingPathComponent("LocalAudio", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func uniqueDestinationURL(for sourceURL: URL, in directory: URL) -> URL {
        let fileExtension = sourceURL.pathExtension.isEmpty ? "audio" : sourceURL.pathExtension
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let safeBaseName = baseName.isEmpty ? "audio" : baseName
        return directory.appendingPathComponent("\(safeBaseName)-\(UUID().uuidString).\(fileExtension)")
    }

    static func isSupportedAudioURL(_ url: URL) -> Bool {
        let supportedExtensions = Set(["mp3", "m4a", "m4b", "aac", "wav", "aiff", "caf"])
        return supportedExtensions.contains(url.pathExtension.lowercased())
    }
}

struct ImportedAudioFile: Equatable, Sendable {
    var title: String
    var localURL: URL
    var duration: TimeInterval?
}

extension UTType {
    static var voxglassImportTypes: [UTType] {
        var types: [UTType] = [.audio, .mp3, .mpeg4Audio, .folder]
        if let m4b = UTType(filenameExtension: "m4b") {
            types.append(m4b)
        }
        return types
    }
}

