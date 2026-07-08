import SwiftUI

struct BookRowView: View {
    var book: BookWithChapters
    var isCurrent: Bool = false
    var playAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            BookArtworkView(title: book.book.title, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(book.book.title)
                    .font(.headline)
                    .foregroundStyle(VoxglassTheme.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Text(book.book.authorLine)
                    .font(.subheadline)
                    .foregroundStyle(VoxglassTheme.secondaryInk)
                    .lineLimit(1)
                Text("\(book.chapters.count) chapter\(book.chapters.count == 1 ? "" : "s") · \(TimeFormatting.compactDuration(book.totalDuration))")
                    .font(.caption)
                    .foregroundStyle(VoxglassTheme.secondaryInk.opacity(0.78))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: playAction) {
                Image(systemName: isCurrent ? "waveform.circle.fill" : "play.circle.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(VoxglassTheme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCurrent ? "Current book" : "Play \(book.book.title)")
        }
        .padding(12)
        .glassPanel()
    }
}

