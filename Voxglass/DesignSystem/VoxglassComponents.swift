import SwiftUI
import VoxglassCore

struct SectionTitle: View {
    var title: String
    var subtitle: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .scaledFont(size: 18, weight: .bold)
                    .foregroundStyle(Palette.ink)
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

enum RowAccessory {
    case navigation
    case play
    case loading
    case download(OfflineState, showsNavigation: Bool)
    case none
}

enum BookListRowStyle {
    case card
    case grouped
}

struct BookListRow: View {
    var title: String
    var subtitle: String
    var tertiary: String?
    var metadata: String?
    var coverURL: URL?
    var accessory: RowAccessory = .navigation
    var style: BookListRowStyle = .card
    var accessibilityLabel: String?

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
        HStack(alignment: .center, spacing: 12) {
            BookArtworkView(title: title, size: 56, coverURL: coverURL, cornerRadius: 12)
                .frame(width: 56, height: 56)
                .fixedSize()

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .scaledFont(size: 14.5, weight: .medium)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.86)
                    .fixedSize(horizontal: false, vertical: true)
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
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            rowAccessory
                .accessibilityHidden(true)
        }
        .frame(minHeight: 76)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
        case .download(let state, let showsNavigation):
            HStack(spacing: 4) {
                downloadAccessory(for: state)
                if showsNavigation {
                    Image(systemName: "chevron.right")
                        .scaledFont(size: 11, weight: .bold)
                        .foregroundStyle(Palette.ink3.opacity(0.7))
                        .frame(width: 16, height: 44)
                }
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
    var showsLock: Bool = false

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

            if showsLock {
                ProLockBadge()
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
    }
}

struct CompactBookRowView: View {
    var book: BookWithChapters
    var sourceTitle: String?
    var accessory: RowAccessory = .navigation
    var style: BookListRowStyle = .card

    var body: some View {
        BookListRow(
            title: book.book.title,
            subtitle: book.book.authorLine,
            tertiary: book.book.narratorLine,
            metadata: nil,
            coverURL: book.book.coverURL,
            accessory: accessory,
            style: style,
            accessibilityLabel: "\(book.book.title) by \(book.book.authorLine)"
        )
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

struct ProLockBadge: View {
    var body: some View {
        Image(systemName: "lock.fill")
            .scaledFont(size: 10, weight: .semibold)
            .foregroundStyle(Color(hex: 0x221503))
            .padding(5)
            .background(Palette.brass, in: Circle())
            .accessibilityHidden(true)
    }
}

private struct ProLockedModifier: ViewModifier {
    let feature: ProFeature
    let identifier: String
    let onTapLocked: () -> Void

    func body(content: Content) -> some View {
        if ProFeature.isEnabled(feature) {
            content
        } else {
            Button(action: onTapLocked) {
                content
                    .allowsHitTesting(false)
                    .overlay(alignment: .topTrailing) {
                        ProLockBadge()
                            .padding(6)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier)
            .accessibilityAddTraits(.isButton)
        }
    }
}

extension View {
    /// Standardized Pro gate: when `feature` is not entitled, the content renders
    /// with a `lock.fill` badge, gains a stable `accessibilityIdentifier`, and any
    /// tap invokes `onTapLocked` (present the paywall) instead of the content's own
    /// interaction. When entitled, the content is returned untouched.
    func proLocked(
        _ feature: ProFeature,
        id: String,
        onTapLocked: @escaping () -> Void
    ) -> some View {
        modifier(ProLockedModifier(feature: feature, identifier: id, onTapLocked: onTapLocked))
    }

    /// Uniform paywall presentation used by every gated touchpoint.
    func paywallSheet(isPresented: Binding<Bool>) -> some View {
        sheet(isPresented: isPresented) {
            NavigationStack {
                ProPaywallView()
            }
        }
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
