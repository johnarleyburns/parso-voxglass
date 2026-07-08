import SwiftUI

struct RootView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @State private var selectedTab: VoxglassTab = .home
    @State private var showingNowPlaying = false

    var body: some View {
        TabView(selection: $selectedTab) {
            ListenView(
                showingNowPlaying: $showingNowPlaying,
                selectLibrary: { selectedTab = .library },
                selectSearch: { selectedTab = .search }
            )
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(VoxglassTab.home)

            LibraryView(showingNowPlaying: $showingNowPlaying)
                .tabItem { Label("Library", systemImage: "books.vertical.fill") }
                .tag(VoxglassTab.library)

            BrowseView(showingNowPlaying: $showingNowPlaying)
                .tabItem { Label("Browse", systemImage: "square.grid.2x2.fill") }
                .tag(VoxglassTab.browse)

            SearchView(showingNowPlaying: $showingNowPlaying)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(VoxglassTab.search)

            SettingsView(showingNowPlaying: $showingNowPlaying)
                .tabItem { Label("More", systemImage: "ellipsis.circle.fill") }
                .tag(VoxglassTab.more)
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
    case home
    case library
    case browse
    case search
    case more
}
