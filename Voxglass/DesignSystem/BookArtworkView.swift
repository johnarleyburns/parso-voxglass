import SwiftUI
import VoxglassCore

struct ArtworkImageView<Placeholder: View>: View {
    var url: URL?
    @ViewBuilder var placeholder: Placeholder

    @State private var image: UIImage?
    @State private var failedURL: URL?

    var body: some View {
        ZStack {
            placeholder

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .clipped()
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
    var cornerRadius: CGFloat = 14

    var body: some View {
        ArtworkImageView(url: coverURL) {
            GeneratedBookCover(title: title, cornerRadius: cornerRadius)
        }
        .aspectRatio(1, contentMode: .fill)
        .accessibilityLabel(title)
    }
}

struct SquareBookCoverView: View {
    var title: String
    var size: CGFloat
    var coverURL: URL?
    var cornerRadius: CGFloat = 14
    var showBorder: Bool = true

    var body: some View {
        BookCoverView(title: title, coverURL: coverURL, cornerRadius: cornerRadius)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .clipped()
            .overlay {
                if showBorder {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                }
            }
            .accessibilityLabel(title)
    }
}

struct BookArtworkView: View {
    var title: String
    var size: CGFloat = 68
    var coverURL: URL?
    var cornerRadius: CGFloat = 12
    var showBorder: Bool = true

    var body: some View {
        SquareBookCoverView(
            title: title,
            size: size,
            coverURL: coverURL,
            cornerRadius: cornerRadius,
            showBorder: showBorder
        )
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
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Palette.hairline, lineWidth: 1)
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
                    .scaledFont(size: 32, weight: .semibold)
                    .foregroundStyle(Color.white.opacity(0.88))
                    .padding(14)
            }
        }
    }

    private var fallbackColors: [Color] {
        let seed = abs(title.hashValue)
        let palettes: [[Color]] = [
            [Color(hex: 0x7A4B1E), Color(hex: 0x3D2410)],
            [Color(hex: 0x4A5F8A), Color(hex: 0x22304E)],
            [Color(hex: 0x5A3D78), Color(hex: 0x2A1C3E)],
            [Color(hex: 0x6E2F2F), Color(hex: 0x361616)]
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
                    .scaledFont(size: 14)
                    .foregroundStyle(Palette.brass)
                    .frame(width: 44, height: 44)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                    }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                Text(subtitle)
                    .scaledFont(size: 11.5)
                    .foregroundStyle(Palette.ink3)
                    .lineLimit(1)
                if let metadata, !metadata.isEmpty {
                    Text(metadata)
                        .scaledFont(size: 11.5)
                        .foregroundStyle(Palette.ink3)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if let trailingSystemImage {
                Image(systemName: trailingSystemImage)
                    .scaledFont(size: 11, weight: .bold)
                    .foregroundStyle(Palette.ink3.opacity(0.7))
            }
        }
        .padding(12)
        .contentShape(Rectangle())
    }
}

struct HorizontalCatalogCard: View {
    var result: InternetArchiveSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BookArtworkView(title: result.title, size: 132, coverURL: result.coverURL, cornerRadius: 14, showBorder: false)

            Text(result.title)
                .scaledFont(size: 12.5, weight: .semibold)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .padding(.top, 7)

            Text(result.authorLine)
                .scaledFont(size: 11)
                .foregroundStyle(Palette.ink3)
                .lineLimit(1)
                .padding(.top, 1)

            if result.narrationKind == .solo {
                SoloNarrationBadge()
                    .padding(.top, 4)
            }
        }
        .frame(width: 132)
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
                    RadialGradient(
                        colors: palette,
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 180
                    )
                )

            VStack(spacing: 7) {
                Image(systemName: "book.closed.fill")
                    .scaledFont(size: 24, weight: .semibold)
                Text(initials)
                    .scaledFont(size: 15, weight: .bold)
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
            [Color(hex: 0x7A4B1E), Color(hex: 0x3D2410), Color(hex: 0x1C1108)],
            [Color(hex: 0x4A5F8A), Color(hex: 0x22304E), Color(hex: 0x0F1522)],
            [Color(hex: 0x5A3D78), Color(hex: 0x2A1C3E), Color(hex: 0x181028)],
            [Color(hex: 0x6E2F2F), Color(hex: 0x361616), Color(hex: 0x1C0A0A)]
        ]
        return palettes[seed % palettes.count]
    }
}
