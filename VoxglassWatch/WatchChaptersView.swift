import SwiftUI
import VoxglassCore

struct WatchChaptersView: View {
    let book: BookWithChapters
    var onChapterSelected: ((Chapter) -> Void)?
    @State private var currentChapterID: UUID?

    var body: some View {
        List(book.chapters.naturallySorted()) { chapter in
            Button {
                currentChapterID = chapter.id
                onChapterSelected?(chapter)
            } label: {
                HStack {
                    Text(chapter.title)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer()
                    if let duration = chapter.duration {
                        Text(WatchTimeFormat.time(duration))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listRowBackground(
                chapter.id == currentChapterID
                    ? Color.accentColor.opacity(0.2)
                    : Color.clear
            )
        }
        .accessibilityIdentifier(WatchAccessibilityID.chaptersList)
    }
}
