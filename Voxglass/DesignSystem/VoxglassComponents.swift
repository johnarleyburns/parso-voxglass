import SwiftUI

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
            .frame(height: 34)
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

struct DisclosureListRow: View {
    var icon: String
    var title: String
    var detail: String?
    var count: Int?
    var isEnabled: Bool = true

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

            Image(systemName: "chevron.right")
                .scaledFont(size: 11, weight: .bold)
                .foregroundStyle(Palette.ink3.opacity(isEnabled ? 0.7 : 0.25))
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

    var body: some View {
        HStack(spacing: 12) {
            BookArtworkView(title: book.book.title, size: 56, coverURL: book.book.coverURL, cornerRadius: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.book.title)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2, reservesSpace: true)
                    .minimumScaleFactor(0.82)
                Text(book.book.authorLine)
                    .scaledFont(size: 11.5)
                    .foregroundStyle(Palette.ink3)
                    .lineLimit(1)
                Text(book.libraryDetailLine(sourceTitle: sourceTitle))
                    .scaledFont(size: 11.5)
                    .foregroundStyle(Palette.ink3)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .scaledFont(size: 11, weight: .bold)
                .foregroundStyle(Palette.ink3.opacity(0.7))
        }
        .frame(minHeight: 72)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .glassSurface(cornerRadius: 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(book.book.title) by \(book.book.authorLine)")
    }
}

struct HorizontalBookCard: View {
    var book: BookWithChapters

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BookCoverView(title: book.book.title, coverURL: book.book.coverURL)
                .frame(width: 132, height: 132)
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

enum NarratorDisplay {
    static func chapterLine(chapter: Chapter, bookNarrators: [String]) -> String? {
        guard !chapter.narrators.isEmpty else { return nil }
        let uniqueBookNarrators = Set(bookNarrators)
        if uniqueBookNarrators.count <= 1 { return nil }
        return chapter.narrators.joined(separator: ", ")
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
