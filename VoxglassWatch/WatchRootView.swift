import SwiftUI
import VoxglassWatchProtocol

/// Watch redesign §4 — one navigation stack: Home → Player / Book page → Chapters / Speed / Sleep,
/// plus Downloads and About from Home's footer.
struct WatchRootView: View {
    @EnvironmentObject private var services: WatchAppServices
    @State private var path: [WatchRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            WatchHomeView(path: $path)
                .navigationDestination(for: WatchRoute.self) { route in
                    switch route {
                    case .player:
                        WatchPlayerView(path: $path)
                    case .book(let id):
                        if let book = services.books.first(where: { $0.id == id }) {
                            WatchBookPageView(book: book, path: $path)
                        }
                    case .chapters(let id):
                        if let book = services.books.first(where: { $0.id == id }) ?? services.playbackBook {
                            WatchChaptersView(book: book, path: $path)
                        }
                    case .speed:
                        WatchSpeedView()
                    case .sleep:
                        WatchSleepView()
                    case .downloads:
                        WatchDownloadsView()
                    case .about:
                        WatchAboutView()
                    case .syncStatus:
                        WatchListeningSyncStatusView()
                    }
                }
        }
        .task {
            services.bootstrap()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                services.session.publishCurrentReports()
            }
        }
    }
}

enum WatchRoute: Hashable {
    case player
    case book(WatchBookID)
    case chapters(WatchBookID)
    case speed
    case sleep
    case downloads
    case about
    case syncStatus
}

enum WatchAccessibilityID {
    static let connection = "watch.connection"
    static let nowPlaying = "watch.nowPlaying"
}
