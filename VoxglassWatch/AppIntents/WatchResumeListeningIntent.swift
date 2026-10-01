import AppIntents
import Foundation

/// Watch redesign A2 — the Smart Stack card's resume/pause. As an `AudioPlaybackIntent` it runs in
/// the watch app's process (which owns the audio), so the widget extension compiles only the
/// declaration (`VOXGLASS_WATCH_WIDGET`) and the app compiles the real `perform()`.
struct ResumeListeningIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Resume or Pause Voxglass"
    static let description = IntentDescription("Continues the book you were listening to, or pauses it.")

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !VOXGLASS_WATCH_WIDGET
        let services = WatchAppServices.shared
        if services.books.isEmpty { services.bootstrap() }
        if let book = services.heroBook {
            if services.playbackBook?.id == book.id {
                services.togglePlayPause()
            } else {
                services.play(book, chapterIndex: services.resumeChapterIndex(for: book))
            }
        }
        #endif
        return .result()
    }
}
