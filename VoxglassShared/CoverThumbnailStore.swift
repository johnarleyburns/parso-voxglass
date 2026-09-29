import Foundation
import AVFoundation
import UIKit

/// Small, shared artwork cache for Live Activities and widgets. Artwork is
/// deliberately kept outside the ActivityKit payload so updates stay tiny.
enum CoverThumbnailStore {
    static let appGroup = "group.guru.parso.voxglass"
    private static let directoryName = "Artwork"
    private static let maximumCount = 20

    static func save(imageData: Data, bookID: UUID) {
        guard let image = UIImage(data: imageData),
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return }
        let directory = container.appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let size = CGSize(width: 160, height: 160)
        let thumbnail = UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: AVMakeRect(aspectRatio: image.size, insideRect: CGRect(origin: .zero, size: size)))
        }
        guard let jpeg = thumbnail.jpegData(compressionQuality: 0.8) else { return }
        try? jpeg.write(to: directory.appendingPathComponent("\(bookID.uuidString).jpg"), options: .atomic)
        trim(directory)
    }

    static func url(for bookID: UUID) -> URL? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        let url = container.appendingPathComponent(directoryName).appendingPathComponent("\(bookID.uuidString).jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func trim(_ directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let images = files.filter { $0.pathExtension == "jpg" }
        for file in images.sorted(by: { modificationDate($0) < modificationDate($1) }).dropLast(maximumCount) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
