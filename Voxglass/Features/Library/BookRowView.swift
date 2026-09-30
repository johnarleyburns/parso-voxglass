import SwiftUI
import VoxglassCore

struct BookRowView: View {
    var book: BookWithChapters
    var isCurrent: Bool = false
    var playAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            BookArtworkView(title: book.book.title, size: 48, coverURL: book.book.coverURL)
            VStack(alignment: .leading, spacing: 4) {
                Text(book.book.title)
                    .font(.headline)
                    .foregroundStyle(VoxglassTheme.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                if let author = book.book.displayAuthorLine {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(VoxglassTheme.secondaryInk)
                        .lineLimit(1)
                }
                Text("\(book.chapters.count) chapter\(book.chapters.count == 1 ? "" : "s") · \(TimeFormatting.compactDuration(book.totalDuration))")
                    .font(.caption)
                    .foregroundStyle(VoxglassTheme.secondaryInk.opacity(0.78))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: playAction) {
                Image(systemName: isCurrent ? "waveform.circle.fill" : "play.circle.fill")
                    .scaledFont(size: 34, weight: .semibold) // type-exempt: display progress numeral
                    .foregroundStyle(VoxglassTheme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCurrent ? "Current book" : "Play \(book.book.title)") // l10n-exempt: state-dependent accessibility or status copy
        }
        .padding(12)
        .raisedSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibilityLabel)
        .accessibilityAction(named: isCurrent ? "Pause" : "Play") {
            playAction()
        }
    }

    private var rowAccessibilityLabel: String {
        var parts: [String] = [book.book.title]
        if let author = book.book.displayAuthorLine, !author.isEmpty {
            parts.append("by \(author)")
        }
        if !book.book.narrators.isEmpty {
            parts.append("read by \(book.book.narrators.joined(separator: ", "))")
        }
        return parts.joined(separator: ", ")
    }
}
