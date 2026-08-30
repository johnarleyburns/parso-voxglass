import SwiftUI
import VoxglassCore

struct WatchRootView: View {
    @EnvironmentObject var services: WatchAppServices
    @Environment(\.scenePhase) private var scenePhase

    @State private var lastForegroundFetch: Date = .distantPast

    var body: some View {
        NavigationStack {
            WatchListeningView()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            WatchNowPlayingView()
                        } label: {
                            Image(systemName: "waveform")
                        }
                        .accessibilityIdentifier(WatchAccessibilityID.nowPlaying)
                    }
                }
        }
        .task {
            await services.bootstrap()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { @MainActor in
                    if Date().timeIntervalSince(lastForegroundFetch) > 30 {
                        lastForegroundFetch = Date()
                        await services.refreshFromPhone()
                    }
                    await services.refreshLocalLibrary()
                }
            }
        }
    }
}

public enum WatchAccessibilityID {
    public static let rootListening = "watch.library"
    public static let rootSearch = "watch.library"
    public static let rootOnWatch = "watch.library"
    public static let connection = "watch.connection"
    public static let nowPlaying = "watch.nowPlaying"
    public static let bookDetail = "book.detail"
    public static let bookStream = "book.stream"
    public static let bookFetch = "book.fetch"
    public static let bookAdd = "book.add"
    public static let npPlayPause = "np.playpause"
    public static let npState = "np.state"
    public static let npChapterNumber = "np.chapterNumber"
    public static let npElapsed = "np.elapsed"
    public static let npRemaining = "np.remaining"
    public static let npDownload = "np.download"
    public static let npBack15 = "np.back15"
    public static let npForward30 = "np.forward30"
    public static let npChapterPrev = "watch.player.previousChapter"
    public static let npChapterNext = "watch.player.nextChapter"
    public static let bookMeta = "book.meta"
    public static let npRoute = "np.route"
    public static let fetchStatus = "fetch.status"
    public static let fetchOverallState = "fetch.overallState"
    public static let fetchCancel = "fetch.cancel"
    public static let fetchRetry = "fetch.retry"
    public static let fetchChapters = "fetch.chapters"
    public static let chaptersList = "chapters.list"
    public static let playbackOptions = "playback.options"
    public static let widgetResume = "widget.resume"

    public static func fetchChapterState(_ chapterNumber: Int) -> String {
        "fetch.chapter.\(chapterNumber).state"
    }
}
