import AppKit
import Foundation
import SwiftUI

@MainActor
final class MacArtworkLoader {
    static let shared = MacArtworkLoader()

    private var cache: [URL: NSImage] = [:]

    func image(for url: URL?) async -> NSImage? {
        guard let url else { return nil }
        if let cached = cache[url] { return cached }

        guard let data = await MacArtworkDataLoader.load(from: url),
              let image = NSImage(data: data) else { return nil }

        cache[url] = image
        return image
    }
}

private enum MacArtworkDataLoader {
    static func load(from url: URL) async -> Data? {
        if url.isFileURL {
            return await Task.detached(priority: .utility) {
                try? Data(contentsOf: url)
            }.value
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let response = response as? HTTPURLResponse,
               !(200..<300).contains(response.statusCode) {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }
}

struct MacArtworkView: View {
    let title: String
    let author: String?
    let coverURL: URL?
    let size: CGSize

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                MacCoverFallback(title: title, author: author, size: size)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.12))
        }
        .clipped()
        .accessibilityLabel("Artwork for \(title)")
        .task(id: coverURL) {
            image = await MacArtworkLoader.shared.image(for: coverURL)
        }
    }
}
