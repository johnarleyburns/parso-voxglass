import SwiftUI
import VoxglassCore

/// Compatibility wrapper while feature call sites migrate to `CoverPlate`.
@available(*, deprecated, message: "Use CoverPlate")
struct BookCoverView: View {
    var title: String
    var coverURL: URL?
    var cornerRadius: CGFloat = 14
    var body: some View {
        CoverPlate(title: title, author: nil, coverURL: coverURL, size: 68)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Compatibility wrapper while feature call sites migrate to `CoverPlate`.
@available(*, deprecated, message: "Use CoverPlate")
struct SquareBookCoverView: View {
    var title: String
    var size: CGFloat
    var coverURL: URL?
    var cornerRadius: CGFloat = 14
    var showBorder: Bool = true
    var body: some View {
        CoverPlate(title: title, author: nil, coverURL: coverURL, size: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay { if showBorder { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Palette.hairline) } }
    }
}

/// Compatibility wrapper while feature call sites migrate to `CoverPlate`.
@available(*, deprecated, message: "Use CoverPlate")
struct BookArtworkView: View {
    var title: String
    var size: CGFloat = 68
    var coverURL: URL?
    var cornerRadius: CGFloat = 12
    var showBorder: Bool = true
    var author: String?
    var shape: CoverPlate.Shape = .square

    var body: some View {
        CoverPlate(title: title, author: author, coverURL: coverURL, size: size, shape: shape)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay { if showBorder { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Palette.hairline) } }
            .accessibilityHidden(true)
    }
}

struct CollectionArtworkView: View {
    var title: String
    var systemImage: String
    var assetName: String?
    var remoteImageURL: URL?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let assetName, UIImage(named: assetName) != nil {
                Image(assetName).resizable().scaledToFill()
            } else {
                CoverPlate(title: title, author: nil, coverURL: remoteImageURL, size: 180)
                Image(systemName: systemImage).font(.title2).foregroundStyle(.white.opacity(0.88)).padding(14)
            }
        }
        .clipped()
        .overlay { RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.hairline) }
        .accessibilityHidden(true)
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
            if artworkURL != nil { CoverPlate(title: fallbackTitle, author: nil, coverURL: artworkURL, size: 48) }
            else { Image(systemName: systemImage).foregroundStyle(Palette.brass).frame(width: 44, height: 44).background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9)) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).voxType(.bookTitle).foregroundStyle(Palette.ink).lineLimit(2).minimumScaleFactor(0.82)
                Text(subtitle).voxType(.meta).foregroundStyle(Palette.ink3).lineLimit(1)
                if let metadata { Text(metadata).voxType(.meta).foregroundStyle(Palette.ink3).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if let trailingSystemImage { Image(systemName: trailingSystemImage).foregroundStyle(Palette.ink3.opacity(0.7)) }
        }
        .padding(12)
        .contentShape(Rectangle())
    }
}

struct HorizontalCatalogCard: View {
    var result: InternetArchiveSearchResult
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CoverPlate(title: result.title, author: result.authorLine, coverURL: result.coverURL, size: 132)
            Text(result.title).voxType(.bookTitle).foregroundStyle(Palette.ink).lineLimit(1).padding(.top, 7)
            Text(result.authorLine).voxType(.meta).foregroundStyle(Palette.ink3).lineLimit(1).padding(.top, 1)
        }
        .frame(width: 132)
    }
}

extension Book {
    /// A display-only author fallback for imported books.
    var displayAuthorLine: String? {
        guard authors.isEmpty || authors == ["Local Files"] else { return authorLine }
        return ImportedTitles.parse(title).author
    }
}

struct ImportedTag: View {
    var body: some View {
        Text("IMPORTED").voxType(.eyebrow).foregroundStyle(Palette.ink2).padding(.horizontal, 5).padding(.vertical, 3)
            .overlay { RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.14)) }
    }
}
