import SwiftUI

struct RootView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @State private var selectedTab: VoxglassTab = .listen
    @State private var showingNowPlaying = false

    var body: some View {
        TabView(selection: $selectedTab) {
            ListenView(showingNowPlaying: $showingNowPlaying)
                .tabItem { Label("Listen", systemImage: "house.fill") }
                .tag(VoxglassTab.listen)

            LibraryView(showingNowPlaying: $showingNowPlaying)
                .tabItem { Label("Library", systemImage: "books.vertical.fill") }
                .tag(VoxglassTab.library)

            DiscoverView()
                .tabItem { Label("Discover", systemImage: "safari.fill") }
                .tag(VoxglassTab.discover)

            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(VoxglassTab.search)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
                .tag(VoxglassTab.settings)
        }
        .tint(VoxglassTheme.accent)
        .safeAreaInset(edge: .bottom) {
            if playback.currentSession != nil {
                MiniPlayerView(showingNowPlaying: $showingNowPlaying)
                    .environmentObject(playback)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
        }
        .sheet(isPresented: $showingNowPlaying) {
            NowPlayingView()
                .environmentObject(playback)
                .presentationDragIndicator(.visible)
        }
        .task {
            if libraryStore.books.isEmpty {
                await libraryStore.refresh()
            }
        }
    }
}

private enum VoxglassTab: Hashable {
    case listen
    case library
    case discover
    case search
    case settings
}

