import SwiftUI
import VoxglassCore

struct SectionTitle: View {
    var title: String
    var subtitle: String?
    var actionTitle: String?
    var action: (() -> Void)?
    var actionIdentifier: String?
    var titleIdentifier: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .scaledFont(size: 18, weight: .bold)
                    .foregroundStyle(Palette.ink)
                    .accessibilityIdentifier(titleIdentifier ?? "")
                if let subtitle {
                    Text(subtitle)
                        .scaledFont(size: 13)
                        .foregroundStyle(Palette.ink3)
                }
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .scaledFont(size: 13)
                    .foregroundStyle(Palette.brass)
                    .accessibilityIdentifier(actionIdentifier ?? "")
            }
        }
    }
}

struct FilterChip: View {
    var title: String
    var systemImage: String?
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .scaledFont(size: 11, weight: .semibold)
                }
                Text(title)
                    .scaledFont(size: 12.5, weight: .semibold)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .foregroundStyle(isSelected ? Color(hex: 0x221503) : Palette.ink)
            .background {
                Capsule()
                    .fill(isSelected ? Palette.brass : Color.white.opacity(0.08))
            }
            .overlay {
                if !isSelected {
                    Capsule()
                        .stroke(Palette.hairline, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .tactileTap()
    }
}

/// A lightweight swipe-to-remove row for the glass shelves, which are built
/// inside a `ScrollView` rather than a system `List`.
struct SwipeToRemoveRow<Content: View>: View {
    let isEditing: Bool
    let remove: () -> Void
    @ViewBuilder let content: Content
    @State private var offset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(role: .destructive, action: remove) {
                Label("Remove", systemImage: "trash")
                    .labelStyle(.iconOnly)
                    .frame(width: 72)
                    .frame(maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(Palette.danger)

            content
                .offset(x: offset)
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            guard isEditing else { return }
                            offset = min(0, max(-72, value.translation.width))
                        }
                        .onEnded { value in
                            withAnimation(.easeOut(duration: 0.18)) {
                                offset = isEditing && value.translation.width < -28 ? -72 : 0
                            }
                        }
                )
        }
        .clipped()
        .onChange(of: isEditing) { _, editing in
            if !editing { withAnimation { offset = 0 } }
        }
    }
}

struct VoxglassGroupedSection<Content: View>: View {
    let title: String
    let subtitle: String?
    let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: title, subtitle: subtitle)
            VStack(spacing: 0) {
                content
            }
            .glassSurface(cornerRadius: 16, fill: Color.white.opacity(0.065))
        }
    }
}

struct VoxglassListDivider: View {
    var body: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(height: 1)
            .padding(.leading, 58)
    }
}

struct SoloNarrationBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Palette.brass)
                .frame(width: 4, height: 4)
            Text("Solo Narration")
                .scaledFont(size: 9.5, weight: .bold)
                .kerning(0.3)
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(Palette.brass)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(Palette.brass.opacity(0.12))
        )
        .overlay(
            Capsule()
                .stroke(Palette.brass.opacity(0.35), lineWidth: 1)
        )
        .accessibilityLabel("Solo Narration")
    }
}

struct MyNarrationBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(NarrationPalette.mint)
                .frame(width: 4, height: 4)
            Text("My Narration")
                .scaledFont(size: 9.5, weight: .bold)
                .kerning(0.3)
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(NarrationPalette.mint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(NarrationPalette.mint.opacity(0.12)))
        .overlay(Capsule().stroke(NarrationPalette.mint.opacity(0.35), lineWidth: 1))
        .accessibilityLabel("My Narration")
    }
}

enum RowAccessory {
    case navigation
    case play
    case loading
    case download(OfflineState, showsNavigation: Bool, watchAvailable: Bool = false)
    case none
}

enum BookListRowStyle {
    case card
    case grouped
}

struct BookListRow: View {
    /// The row's own drawn height. Fixed so the two list screens that disable
    /// scrolling and size their `List` by row count stay in sync with it.
    static let rowContentHeight: CGFloat = 96
    /// Height one row occupies in a `List` — the drawn content plus the 5pt
    /// top + 5pt bottom `listRowInsets` both screens apply.
    static let fixedRowHeight: CGFloat = rowContentHeight + 10

    var title: String
    var subtitle: String
    var tertiary: String?
    var metadata: String?
    var watchStatus: String?
    var coverURL: URL?
    var accessory: RowAccessory = .navigation
    var style: BookListRowStyle = .card
    var accessibilityLabel: String?
    var showSoloBadge: Bool = false
    var showMyNarrationBadge: Bool = false

    var body: some View {
        styledRow
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel ?? "\(title), \(subtitle)")
    }

    @ViewBuilder
    private var styledRow: some View {
        switch style {
        case .card:
            rowContent
                .glassSurface(cornerRadius: 14)
        case .grouped:
            rowContent
        }
    }

    private var rowContent: some View {
        // Top-aligned, not centered: rows with more populated optional lines
        // (a "My Narration" row's real narrator/watch-status text vs. a
        // library row showing only title + subtitle) grow taller than their
        // neighbors, and centering within that variable height visibly
        // shifted the artwork and trailing accessory up or down row to row.
        // Top alignment keeps both pinned to the same offset from the row's
        // top edge regardless of how much text follows.
        HStack(alignment: .top, spacing: 12) {
            // No `.fixedSize()`: a book with a real downloaded cover has no
            // intrinsic size of its own, so the explicit frame below was
            // always respected — but the generated text+icon placeholder
            // used when a book has no artwork DOES have real intrinsic
            // content size, and `.fixedSize()` let it render at that larger
            // natural size instead of the intended 56×56, pushing the whole
            // row's artwork and trailing accessory outward for exactly the
            // books missing real cover art.
            BookArtworkView(title: title, size: 56, coverURL: coverURL, cornerRadius: 12)
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .scaledFont(size: 14.5, weight: .medium)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)
                Text(subtitle)
                    .scaledFont(size: 12)
                    .foregroundStyle(Palette.ink3)
                    .lineLimit(1)
                if let tertiary, !tertiary.isEmpty {
                    Text(tertiary)
                        .scaledFont(size: 12)
                        .foregroundStyle(Palette.brass)
                        .lineLimit(1)
                }
                if let metadata, !metadata.isEmpty {
                    Text(metadata)
                        .scaledFont(size: 11.5)
                        .foregroundStyle(Palette.ink3)
                        .lineLimit(1)
                }
                if let watchStatus, !watchStatus.isEmpty {
                    Label(watchStatus, systemImage: "applewatch")
                        .scaledFont(size: 11)
                        .foregroundStyle(Palette.brass)
                        .lineLimit(1)
                }
                // An invisible badge purely to reserve this row's height —
                // the real, visible badge(s) render as an `.overlay` below,
                // which lets them draw at full natural size and, when there
                // are two of them or the title is long, overflow rightward
                // into the row's empty space instead of either shrinking
                // (illegible) or forcing the whole HStack wider (which
                // shoved the artwork left and the accessory right — see the
                // overlay comment below for why an overlay avoids that).
                SoloNarrationBadge().opacity(0)
                    .padding(.top, 2)
            }
            .overlay(alignment: .bottomLeading) {
                // Full-size, un-shrunk badges, but as an overlay rather
                // than a normal stacked child: an overlay's content doesn't
                // count toward its parent's layout size, so however wide
                // these pills naturally want to be, they never change how
                // much width this VStack asks the outer HStack for. That's
                // what lets them spill past the text column's own width —
                // there's ample empty space to the right before the
                // trailing accessory — without that overflow pushing the
                // artwork or the accessory out of their fixed columns.
                HStack(spacing: 5) {
                    if showSoloBadge {
                        SoloNarrationBadge()
                    }
                    if showMyNarrationBadge {
                        MyNarrationBadge()
                    }
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 8)

            rowAccessory
                .frame(width: 44, alignment: .trailing)
                .accessibilityHidden(true)
        }
        // Fixed, not `minHeight`: both list screens that use this row lay their
        // `List` out at `rowCount * BookListRow.fixedRowHeight` with scrolling
        // disabled, so every row must be exactly that tall. A `minHeight` let
        // rows with more populated optional lines (a narration's narrator +
        // watch-status text) grow past their neighbors and past the height the
        // container reserved, clipping the last rows.
        .frame(height: BookListRow.rowContentHeight)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var rowAccessory: some View {
        switch accessory {
        case .navigation:
            Image(systemName: "chevron.right")
                .scaledFont(size: 11, weight: .bold)
                .foregroundStyle(Palette.ink3.opacity(0.7))
                .frame(width: 24, height: 44)
        case .play:
            Image(systemName: "play.circle.fill")
                .scaledFont(size: 27, weight: .semibold)
                .foregroundStyle(Palette.brass)
                .frame(width: 44, height: 44)
        case .loading:
            ProgressView()
                .frame(width: 44, height: 44)
        case .download(let state, let showsNavigation, let watchAvailable):
            // Leading-aligned, not the VStack default of `.center`: the
            // download icon's own HStack is 44pt wide (28 + 16 for the
            // trailing chevron), and the watch icon below it has no
            // intrinsic width of its own — centering it under that full
            // 44pt row instead of under the download icon's own 28pt
            // column visibly shifted it right by roughly half the download
            // icon's width. Giving the watch icon the same 28pt column
            // width keeps both glyphs sharing one vertical line.
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    downloadAccessory(for: state)
                    if showsNavigation {
                        Image(systemName: "chevron.right")
                            .scaledFont(size: 11, weight: .bold)
                            .foregroundStyle(Palette.ink3.opacity(0.7))
                            .frame(width: 16, height: 44)
                    }
                }
                // Always shown, not just when there's a known watch-transfer
                // record — a book with no record at all is exactly a book
                // not on the watch, same as `.notAvailable`, so it should
                // render identically (outline), not disappear entirely.
                Image(systemName: "applewatch")
                    .symbolVariant(watchAvailable ? .fill : .none)
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(watchAvailable ? Palette.brass : Palette.ink3.opacity(0.4))
                    .frame(width: 28)
                    .accessibilityLabel(watchAvailable ? "Downloaded to Apple Watch" : "Not downloaded to Apple Watch")
            }
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private func downloadAccessory(for state: OfflineState) -> some View {
        switch state {
        case .cached:
            Image(systemName: "checkmark.circle.fill")
                .scaledFont(size: 17, weight: .semibold)
                .foregroundStyle(Palette.brass)
                .frame(width: 28, height: 44)
        case .downloading(let progress):
            ZStack {
                Circle()
                    .stroke(Palette.ink3.opacity(0.3), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: CGFloat(progress))
                    .stroke(Palette.brass, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "arrow.down")
                    .scaledFont(size: 7)
                    .foregroundStyle(Palette.brass)
            }
            .frame(width: 20, height: 20)
            .frame(width: 28, height: 44)
        case .notCached:
            Image(systemName: "arrow.down.circle")
                .scaledFont(size: 17)
                .foregroundStyle(Palette.ink3)
                .frame(width: 28, height: 44)
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .scaledFont(size: 17)
                .foregroundStyle(Palette.danger)
                .frame(width: 28, height: 44)
        }
    }
}

struct DisclosureListRow: View {
    var icon: String
    var title: String
    var detail: String?
    var count: Int?
    var isEnabled: Bool = true
    var showsChevron: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .scaledFont(size: 14)
                .foregroundStyle(isEnabled ? Palette.brass : Palette.ink3.opacity(0.55))
                .frame(width: 32, height: 32)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(isEnabled ? Palette.ink : Palette.ink2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                if let detail {
                    Text(detail)
                        .scaledFont(size: 11.5)
                        .foregroundStyle(Palette.ink3)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 10)

            if let count {
                Text("\(count)")
                    .scaledFont(size: 11, weight: .semibold, design: .monospaced)
                    .foregroundStyle(Palette.ink3)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background {
                        Capsule()
                            .fill(Color.white.opacity(0.07))
                    }
            }

            if showsChevron {
                Image(systemName: "chevron.right")
                    .scaledFont(size: 11, weight: .bold)
                    .foregroundStyle(Palette.ink3.opacity(isEnabled ? 0.7 : 0.25))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .opacity(isEnabled ? 1 : 0.62)
    }
}

struct PrimaryActionButton: View {
    var title: String
    var systemImage: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .scaledFont(size: 15.5, weight: .bold)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .foregroundStyle(Color(hex: 0x221503))
                .background {
                    Capsule()
                        .fill(LinearGradient(
                            colors: [Color(hex: 0xEEB35B), Color(hex: 0xCF8F34)],
                            startPoint: .top, endPoint: .bottom))
                }
        }
        .buttonStyle(.plain)
        .tactileTap()
    }
}

struct SecondaryActionButton: View {
    var title: String
    var systemImage: String
    var isEnabled: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .scaledFont(size: 14, weight: .semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.76)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .foregroundStyle(isEnabled ? Palette.ink : Palette.ink3)
                .glassSurface(cornerRadius: 18)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .tactileTap()
    }
}

struct CompactBookRowView: View {
    var book: BookWithChapters
    var sourceTitle: String?
    var accessory: RowAccessory = .navigation
    var style: BookListRowStyle = .card
    var watchStorage: WatchBookStorageInfo?
    var isMyNarration: Bool = false

    var body: some View {
        BookListRow(
            title: book.book.title,
            subtitle: book.book.authorLine,
            tertiary: book.book.narratorLine,
            metadata: nil,
            watchStatus: watchStorageText,
            coverURL: book.book.coverURL,
            accessory: accessory,
            style: style,
            accessibilityLabel: accessibilityText,
            showSoloBadge: book.narrationKind == .solo,
            showMyNarrationBadge: isMyNarration
        )
    }

    private var accessibilityText: String {
        if let watchStorageText {
            return "\(book.book.title) by \(book.book.authorLine), \(watchStorageText)"
        }
        return "\(book.book.title) by \(book.book.authorLine)"
    }

    private var watchStorageText: String? {
        watchStorage?.phoneLibraryStatusText
    }
}

struct HorizontalBookCard: View {
    var book: BookWithChapters

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BookArtworkView(title: book.book.title, size: 132, coverURL: book.book.coverURL, cornerRadius: 14)
            Text(book.book.title)
                .scaledFont(size: 12.5, weight: .semibold)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .padding(.top, 7)
            Text(book.book.authorLine)
                .scaledFont(size: 11)
                .foregroundStyle(Palette.ink3)
                .lineLimit(1)
                .padding(.top, 1)
        }
        .frame(width: 132, alignment: .leading)
    }
}

struct EmptyStatePanel: View {
    var title: String
    var message: String
    var systemImage: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(Palette.brass)
            Text(title)
                .scaledFont(size: 16, weight: .semibold)
                .foregroundStyle(Palette.ink)
            Text(message)
                .scaledFont(size: 14)
                .foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .glassSurface(cornerRadius: 14)
    }
}

struct ProvenanceChip: View {
    let sourceKind: SourceKind?
    var body: some View {
        let (icon, text) = badge
        HStack(spacing: 4) {
            Image(systemName: icon).scaledFont(size: 8)
            Text(text)
        }
        .scaledFont(size: 8.5, weight: .bold)
        .kerning(0.5)
        .foregroundStyle(.white)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Color.black.opacity(0.45), in: Capsule())
    }

    private var badge: (String, String) {
        switch sourceKind {
        case .librivox:
            return ("waveform", "LIBRIVOX")
        case .internetArchive, .internetArchiveURL:
            return ("cloud", "ARCHIVE.ORG")
        case .localFiles, .none:
            return ("iphone", "ON DEVICE")
        }
    }
}

extension BookWithChapters {
    func libraryDetailLine(sourceTitle: String? = nil) -> String {
        var parts = [
            "\(chapters.count) chapter\(chapters.count == 1 ? "" : "s")",
            TimeFormatting.compactDuration(totalDuration)
        ]
        if let sourceTitle, !sourceTitle.isEmpty {
            parts.append(sourceTitle)
        }
        return parts.joined(separator: " - ")
    }
}


extension SourceKind {
    var displayName: String {
        switch self {
        case .librivox:
            return "LibriVox"
        case .internetArchive:
            return "Internet Archive"
        case .internetArchiveURL:
            return "Archive URL"
        case .localFiles:
            return "Local Files"
        }
    }
}
