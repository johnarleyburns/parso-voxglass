import SwiftUI
import VoxglassCore

struct WatchRootView: View {
    @EnvironmentObject var services: WatchAppServices

    enum Tab: String, CaseIterable {
        case listening
        case onWatch
        case search
    }

    @State private var selectedTab: Tab = .listening

    var body: some View {
        TabView(selection: $selectedTab) {
            WatchListeningView()
                .tag(Tab.listening)
                .accessibilityIdentifier(WatchAccessibilityID.rootListening)

            WatchOnDeviceView()
                .tag(Tab.onWatch)
                .accessibilityIdentifier(WatchAccessibilityID.rootOnWatch)

            WatchSearchView()
                .tag(Tab.search)
                .accessibilityIdentifier(WatchAccessibilityID.rootSearch)
        }
    }
}

public enum WatchAccessibilityID {
    public static let rootListening = "root.listening"
    public static let rootSearch = "root.search"
    public static let rootOnWatch = "root.onWatch"
    public static let bookDetail = "book.detail"
    public static let bookStream = "book.stream"
    public static let bookFetch = "book.fetch"
    public static let bookAdd = "book.add"
    public static let npPlayPause = "np.playpause"
    public static let npBack15 = "np.back15"
    public static let npForward30 = "np.forward30"
    public static let npRoute = "np.route"
    public static let fetchStatus = "fetch.status"
    public static let fetchCancel = "fetch.cancel"
    public static let fetchRetry = "fetch.retry"
    public static let chaptersList = "chapters.list"
    public static let playbackOptions = "playback.options"
    public static let widgetResume = "widget.resume"
}
