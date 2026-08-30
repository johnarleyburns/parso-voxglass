import SwiftUI

struct WatchRootView: View {
    @EnvironmentObject private var services: WatchAppServices
    var body: some View {
        NavigationStack {
            WatchLibraryView()
                .toolbar { ToolbarItem(placement: .topBarTrailing) { NavigationLink { WatchNowPlayingView() } label: { Image(systemName: "waveform") }.accessibilityIdentifier("watch.nowPlaying") } }
        }
        .task { services.bootstrap() }
    }
}

enum WatchAccessibilityID {
    static let connection = "watch.connection"
    static let nowPlaying = "watch.nowPlaying"
}
