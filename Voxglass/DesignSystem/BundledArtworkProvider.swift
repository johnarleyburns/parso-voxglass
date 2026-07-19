import Foundation
import UIKit

enum BundledArtworkProvider {
    private static let cached: [String: String] = {
        guard let url = Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: "Artwork"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([ManifestEntry].self, from: data) else {
            return [:]
        }
        var lookup: [String: String] = [:]
        for entry in entries {
            lookup[entry.identifier] = entry.filename
        }
        return lookup
    }()

    static var bundledIdentifiers: Set<String> {
        Set(cached.keys)
    }

    static var count: Int {
        cached.count
    }

    static func image(forIdentifier identifier: String) -> UIImage? {
        guard let filename = cached[identifier] else { return nil }
        guard let url = Bundle.main.url(forResource: filename, withExtension: nil, subdirectory: "Artwork") else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    static func image(forCoverURL url: URL) -> UIImage? {
        guard let identifier = ArtworkService.extractIAIdentifier(from: url) else { return nil }
        return image(forIdentifier: identifier)
    }
}

private struct ManifestEntry: Decodable {
    let identifier: String
    let filename: String
}
