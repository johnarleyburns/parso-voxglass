import SwiftUI
import VoxglassCore

/// One artwork component for books and narration projects.
struct CoverPlate: View {
    enum Shape { case square, portrait, circle }

    let title: String
    let author: String?
    let coverURL: URL?
    var size: CGFloat
    var shape: Shape = .square

    @State private var image: UIImage?
    @State private var failed = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let pair = PlatePalette.pair(for: title, author: author)
        GeometryReader { proxy in
            ZStack {
                if let image {
                    artwork(image: image, pair: pair, width: proxy.size.width)
                } else {
                    typographic(pair: pair, width: proxy.size.width)
                }
                RadialGradient(colors: [.white.opacity(0.14), .clear], center: .topLeading, startRadius: 0, endRadius: max(proxy.size.width, proxy.size.height) * 0.8)
                    .allowsHitTesting(false)
                border
            }
            .clipShape(clipShape)
        }
        .frame(width: size, height: shape == .portrait ? size * 1.4 : size)
        .clipShape(clipShape)
        .accessibilityHidden(true)
        .task(id: coverURL) { await loadImage() }
    }

    @ViewBuilder
    private func artwork(image: UIImage, pair: (background: Color, ink: Color, index: Int), width: CGFloat) -> some View {
        let pixels = min(image.size.width * image.scale, image.size.height * image.scale)
        let threshold = 1.5 * width * displayScale
        if pixels >= threshold {
            Image(uiImage: image).resizable().scaledToFill()
                .shadow(color: .black.opacity(width >= 120 ? 0.70 : 0), radius: width >= 120 ? 14 : 0, y: width >= 120 ? 6 : 0)
        } else {
            ZStack {
                LinearGradient(colors: [pair.background, pair.background.opacity(0.62)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: min(width * 0.78, pixels / max(displayScale, 1) * 1.5)).shadow(radius: 10)
            }
        }
    }

    private func typographic(pair: (background: Color, ink: Color, index: Int), width: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [pair.background, pair.background.opacity(0.62)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if size >= 72 {
                VStack(alignment: .leading, spacing: 6) {
                    if let author, !author.isEmpty { Text(author.uppercased()).voxType(.eyebrow).tracking(1.4).foregroundStyle(pair.ink) }
                    Spacer()
                    Text(title).scaledFont(size: size * 0.16, weight: .medium, design: .serif).foregroundStyle(pair.ink).lineLimit(4).minimumScaleFactor(0.55)
                    Rectangle().fill(pair.ink.opacity(0.75)).frame(width: width * 0.38, height: 1)
                }
                .padding(size * 0.10)
            } else if size >= 40 {
                Text(title).scaledFont(size: size * 0.20, weight: .medium, design: .serif).foregroundStyle(pair.ink).lineLimit(3).minimumScaleFactor(0.55).padding(size * 0.12)
            } else {
                Rectangle().fill(pair.ink.opacity(0.5)).frame(width: width * 0.5, height: 1).padding(.leading, width * 0.25).padding(.bottom, width * 0.3)
            }
        }
    }

    private var clipShape: AnyShape {
        switch shape {
        case .circle: AnyShape(Circle())
        case .portrait: AnyShape(RoundedRectangle(cornerRadius: size > 120 ? Radius.plateLarge : Radius.plateSmall, style: .continuous))
        case .square: AnyShape(RoundedRectangle(cornerRadius: size > 120 ? Radius.plateLarge : Radius.plateSmall, style: .continuous))
        }
    }

    private var border: some View { RoundedRectangle(cornerRadius: shape == .circle ? size / 2 : (size > 120 ? Radius.plateLarge : Radius.plateSmall), style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1) }

    private func loadImage() async {
        guard let coverURL else { image = nil; return }
        if let cached = ArtworkService.shared.cachedImage(for: coverURL) { image = cached; return }
        let loaded = await ArtworkService.shared.image(for: coverURL)
        await MainActor.run { image = loaded; failed = loaded == nil }
    }
}
