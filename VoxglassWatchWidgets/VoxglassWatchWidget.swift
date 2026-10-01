import AppIntents
import SwiftUI
import WidgetKit
import VoxglassWatchCore

/// Watch redesign A2 — the "Continue listening" Smart Stack card: the book, chapter, time left,
/// a progress line, and resume/pause. Tapping the card opens the watch app's Home.
struct ContinueListeningEntry: TimelineEntry {
    let date: Date
    let state: WatchContinueListeningState?
    var relevance: TimelineEntryRelevance? {
        state.map { TimelineEntryRelevance(score: $0.relevance(at: date)) }
    }
}

struct ContinueListeningProvider: TimelineProvider {
    func placeholder(in context: Context) -> ContinueListeningEntry {
        ContinueListeningEntry(date: Date(), state: WatchContinueListeningState(
            bookTitle: "Moby Dick", chapterIndex: 2, chapterTitle: "Loomings", progress: 0.18,
            remainingInBook: 14 * 3600, isPlaying: false, anchorDate: Date()))
    }

    func getSnapshot(in context: Context, completion: @escaping (ContinueListeningEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context)
                                     : ContinueListeningEntry(date: Date(), state: WatchContinueListeningStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ContinueListeningEntry>) -> Void) {
        let state = WatchContinueListeningStore.load()
        let now = Date()
        // The app reloads on every structural change. Hourly entries only re-rank evening relevance.
        let entries = (0..<4).map { ContinueListeningEntry(date: now.addingTimeInterval(Double($0) * 3600), state: state) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(4 * 3600))))
    }
}

struct ContinueListeningWidgetView: View {
    let entry: ContinueListeningEntry

    var body: some View {
        if let state = entry.state {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(state.isPlaying ? String(localized: "Listening") : String(localized: "Continue"),
                          systemImage: "book.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(accent)
                    Text(state.bookTitle).font(.headline).lineLimit(1)
                    Text("Ch \(state.chapterIndex + 1) · \(Self.duration(state.remainingInBook)) left")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    ProgressView(value: state.progress).tint(accent)
                }
                Button(intent: ResumeListeningIntent()) {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.plain)
                .frame(width: 30, height: 30)
                .accessibilityLabel(state.isPlaying ? Text("Pause") : Text("Resume"))
            }
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Label { Text(verbatim: "Voxglass") } icon: { Image(systemName: "book.fill") }.font(.caption2.weight(.semibold)).foregroundStyle(accent)
                Text("No book in progress").font(.headline)
            }
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: max(60, seconds)) ?? ""
    }

    private var accent: Color { Color(red: 0xD8 / 255, green: 0xAD / 255, blue: 0x67 / 255) }
}

struct VoxglassContinueListeningWidget: Widget {
    let kind = "VoxglassWatchContinueListening"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ContinueListeningProvider()) { entry in
            ContinueListeningWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color.black }
        }
        .configurationDisplayName("Continue Listening")
        .description("The audiobook you're in, with time left and resume.")
        .supportedFamilies([.accessoryRectangular])
    }
}

@main
struct VoxglassWatchWidgets: WidgetBundle {
    var body: some Widget {
        VoxglassContinueListeningWidget()
    }
}
