import SwiftUI

struct SectionTitle: View {
    var title: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.headline)
                .foregroundStyle(VoxglassTheme.ink)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(VoxglassTheme.accent)
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
                        .font(.caption.weight(.semibold))
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .foregroundStyle(isSelected ? VoxglassTheme.deepGlass : VoxglassTheme.ink)
            .background {
                Capsule()
                    .fill(isSelected ? VoxglassTheme.accent : VoxglassTheme.paperRaised)
            }
            .overlay {
                Capsule()
                    .stroke(VoxglassTheme.softLine, lineWidth: 1)
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
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isEnabled ? VoxglassTheme.accent : VoxglassTheme.secondaryInk.opacity(0.55))
                .frame(width: 32, height: 32)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(VoxglassTheme.paperRaised)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isEnabled ? VoxglassTheme.ink : VoxglassTheme.secondaryInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(VoxglassTheme.secondaryInk)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 10)

            if let count {
                Text("\(count)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(VoxglassTheme.secondaryInk)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background {
                        Capsule()
                            .fill(VoxglassTheme.paperRaised)
                    }
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(VoxglassTheme.secondaryInk.opacity(isEnabled ? 0.7 : 0.25))
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
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .foregroundStyle(VoxglassTheme.deepGlass)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(VoxglassTheme.accent)
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
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .foregroundStyle(isEnabled ? VoxglassTheme.ink : VoxglassTheme.secondaryInk)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(VoxglassTheme.paperRaised)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(VoxglassTheme.softLine, lineWidth: 1)
                }
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
            BookArtworkView(title: book.book.title, size: 46, coverURL: book.book.coverURL)
            VStack(alignment: .leading, spacing: 4) {
                Text(book.book.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(VoxglassTheme.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                Text(book.book.authorLine)
                    .font(.caption)
                    .foregroundStyle(VoxglassTheme.secondaryInk)
                    .lineLimit(1)
                Text(book.libraryDetailLine(sourceTitle: sourceTitle))
                    .font(.caption2)
                    .foregroundStyle(VoxglassTheme.secondaryInk.opacity(0.78))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(VoxglassTheme.secondaryInk.opacity(0.7))
        }
        .padding(12)
        .glassPanel()
    }
}

struct HorizontalBookCard: View {
    var book: BookWithChapters

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BookArtworkView(title: book.book.title, size: 78, coverURL: book.book.coverURL)
            Text(book.book.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(VoxglassTheme.ink)
                .lineLimit(2)
                .frame(width: 98, alignment: .leading)
            Text(book.book.authorLine)
                .font(.caption2)
                .foregroundStyle(VoxglassTheme.secondaryInk)
                .lineLimit(1)
                .frame(width: 98, alignment: .leading)
        }
        .frame(width: 112, alignment: .topLeading)
        .padding(10)
        .glassPanel()
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
                .foregroundStyle(VoxglassTheme.accent)
            Text(title)
                .font(.headline)
                .foregroundStyle(VoxglassTheme.ink)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(VoxglassTheme.secondaryInk)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .glassPanel()
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
