import SwiftUI
import UIKit

struct ArtworkImageView<Placeholder: View>: View {
    var url: URL?
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: Placeholder

    @State private var image: UIImage?
    @State private var failedURL: URL?

    var body: some View {
        ZStack {
            placeholder

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            }
        }
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        guard let url, failedURL != url else {
            image = nil
            return
        }

        if let cached = ArtworkService.shared.cachedImage(for: url) {
            image = cached
            return
        }

        image = await ArtworkService.shared.image(for: url)
        if image == nil {
            failedURL = url
        }
    }
}

struct BookCoverView: View {
    var title: String
    var coverURL: URL?
    var cornerRadius: CGFloat = 8

    var body: some View {
        ArtworkImageView(url: coverURL) {
            GeneratedBookCover(title: title, cornerRadius: cornerRadius)
        }
        .aspectRatio(0.72, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        }
        .accessibilityLabel(title)
    }
}

struct BookArtworkView: View {
    var title: String
    var size: CGFloat = 68
    var coverURL: URL?

    var body: some View {
        BookCoverView(title: title, coverURL: coverURL)
            .frame(width: size, height: size * 1.28)
            .accessibilityHidden(true)
    }
}

struct CollectionArtworkView: View {
    var title: String
    var systemImage: String
    var assetName: String?
    var remoteImageURL: URL?

    var body: some View {
        GeometryReader { geometry in
            ArtworkImageView(url: remoteImageURL) {
                fallback
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(VoxglassTheme.softLine, lineWidth: 1)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var fallback: some View {
        if let assetName, UIImage(named: assetName) != nil {
            Image(assetName)
                .resizable()
                .scaledToFill()
        } else {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: fallbackColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: systemImage)
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .padding(14)
            }
        }
    }

    private var fallbackColors: [Color] {
        let seed = abs(title.hashValue)
        let palettes: [[Color]] = [
            [Color(red: 0.10, green: 0.15, blue: 0.14), Color(red: 0.78, green: 0.52, blue: 0.28)],
            [Color(red: 0.12, green: 0.12, blue: 0.18), Color(red: 0.54, green: 0.34, blue: 0.65)],
            [Color(red: 0.08, green: 0.18, blue: 0.22), Color(red: 0.42, green: 0.66, blue: 0.72)],
            [Color(red: 0.18, green: 0.10, blue: 0.12), Color(red: 0.74, green: 0.30, blue: 0.36)]
        ]
        return palettes[seed % palettes.count]
    }
}

struct VisualSummaryRow: View {
    var artworkURL: URL?
    var fallbackTitle: String
    var systemImage: String
    var title: String
    var subtitle: String
    var metadata: String?
    var trailingSystemImage: String?

    var body: some View {
        HStack(spacing: 12) {
            if artworkURL != nil {
                BookArtworkView(title: fallbackTitle, size: 48, coverURL: artworkURL)
            } else {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(VoxglassTheme.accent)
                    .frame(width: 44, height: 44)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(VoxglassTheme.paperRaised)
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(VoxglassTheme.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(VoxglassTheme.secondaryInk)
                    .lineLimit(1)
                if let metadata, !metadata.isEmpty {
                    Text(metadata)
                        .font(.caption2)
                        .foregroundStyle(VoxglassTheme.secondaryInk.opacity(0.78))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if let trailingSystemImage {
                Image(systemName: trailingSystemImage)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(VoxglassTheme.secondaryInk.opacity(0.7))
            }
        }
        .padding(12)
        .contentShape(Rectangle())
    }
}

struct HorizontalCatalogCard: View {
    var result: InternetArchiveSearchResult
    var isImporting: Bool
    var importAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BookCoverView(title: result.title, coverURL: result.coverURL)
                .frame(width: 104, height: 136)
                .shadow(color: .black.opacity(0.16), radius: 10, y: 6)

            Text(result.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(VoxglassTheme.ink)
                .lineLimit(2)
                .frame(width: 112, alignment: .leading)

            Text(result.authorLine)
                .font(.caption2)
                .foregroundStyle(VoxglassTheme.secondaryInk)
                .lineLimit(1)
                .frame(width: 112, alignment: .leading)

            Button(action: importAction) {
                HStack(spacing: 6) {
                    if isImporting {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.down.circle.fill")
                    }
                    Text("Import")
                        .lineLimit(1)
                }
                .font(.caption.weight(.bold))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .foregroundStyle(VoxglassTheme.deepGlass)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(VoxglassTheme.accent)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Import \(result.title)")
        }
        .frame(width: 128, alignment: .topLeading)
        .padding(10)
        .glassPanel()
        .onAppear {
            ArtworkService.shared.prefetch(urls: [result.coverURL], limit: 1)
        }
    }
}

private struct GeneratedBookCover: View {
    var title: String
    var cornerRadius: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: palette,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(spacing: 7) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 24, weight: .semibold))
                Text(initials)
                    .font(.system(size: 15, weight: .bold, design: .serif))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.65)
            }
            .foregroundStyle(Color(red: 1.0, green: 0.865, blue: 0.620))
            .padding(9)

            VStack {
                Spacer()
                Rectangle()
                    .fill(Color.black.opacity(0.20))
                    .frame(height: 10)
            }
        }
    }

    private var initials: String {
        let parts = title
            .split(separator: " ")
            .prefix(3)
            .compactMap(\.first)
        let value = String(parts)
        return value.isEmpty ? "VG" : value.uppercased()
    }

    private var palette: [Color] {
        let seed = abs(title.hashValue)
        let palettes: [[Color]] = [
            [Color(red: 0.06, green: 0.09, blue: 0.08), Color(red: 0.50, green: 0.32, blue: 0.19), VoxglassTheme.accent],
            [Color(red: 0.08, green: 0.08, blue: 0.14), Color(red: 0.32, green: 0.28, blue: 0.55), Color(red: 0.78, green: 0.52, blue: 0.80)],
            [Color(red: 0.09, green: 0.14, blue: 0.17), Color(red: 0.25, green: 0.52, blue: 0.58), Color(red: 0.86, green: 0.68, blue: 0.40)],
            [Color(red: 0.16, green: 0.06, blue: 0.08), Color(red: 0.48, green: 0.20, blue: 0.24), Color(red: 0.87, green: 0.50, blue: 0.36)]
        ]
        return palettes[seed % palettes.count]
    }
}
