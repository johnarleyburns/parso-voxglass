import SwiftUI

struct WatchRootView: View {
    @EnvironmentObject private var services: WatchAppServices
    var body: some View {
        NavigationStack {
            WatchLibraryView()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        // A shortcut back to whatever's currently loaded —
                        // there's no separate "Now Playing" screen any more,
                        // just this same combined book view for the book
                        // that's actually playing.
                        if let book = services.playbackBook {
                            NavigationLink { WatchBookDetailView(book: book) } label: { Image(systemName: "waveform") }
                                .accessibilityIdentifier("watch.nowPlaying")
                        }
                    }
                }
        }
        .task { services.bootstrap() }
    }
}

enum WatchAccessibilityID {
    static let connection = "watch.connection"
    static let nowPlaying = "watch.nowPlaying"
}
