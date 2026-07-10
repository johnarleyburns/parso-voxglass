import SwiftUI

struct RootView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @State private var selectedTab: VoxglassTab = .launchDefault
    @State private var showingNowPlaying = false
    @AppStorage(AppPreferencesStore.Keys.hasCompletedSplash) private var hasCompletedSplash = false
    @AppStorage(AppPreferencesStore.Keys.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @AppStorage(AppPreferencesStore.Keys.selectedTasteIDs) private var selectedTasteIDsRaw = ""

    var body: some View {
        Group {
            if !hasCompletedSplash {
                SplashView {
                    hasCompletedSplash = true
                }
            } else if !hasCompletedOnboarding {
                OnboardingPreferencesView(
                    initialSelection: AppPreferencesStore.decodeTasteIDs(selectedTasteIDsRaw)
                ) { selectedTasteIDs in
                    selectedTasteIDsRaw = AppPreferencesStore.encodeTasteIDs(selectedTasteIDs)
                    hasCompletedOnboarding = true
                } skipAction: {
                    selectedTasteIDsRaw = ""
                    hasCompletedOnboarding = true
                }
            } else {
                tabs
            }
        }
        .tint(VoxglassTheme.accent)
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            ListenView(
                showingNowPlaying: $showingNowPlaying,
                selectLibrary: { selectedTab = .library },
                selectSearch: { selectedTab = .search }
            )
            .tabItem { Label("Listen", systemImage: "headphones") }
            .tag(VoxglassTab.home)

            LibraryView(showingNowPlaying: $showingNowPlaying)
                .tabItem { Label("Library", systemImage: "books.vertical.fill") }
                .tag(VoxglassTab.library)

            BrowseView(showingNowPlaying: $showingNowPlaying)
                .tabItem { Label("Explore", systemImage: "square.grid.2x2.fill") }
                .tag(VoxglassTab.browse)

            SearchView(showingNowPlaying: $showingNowPlaying)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(VoxglassTab.search)

            SettingsView(showingNowPlaying: $showingNowPlaying)
                .tabItem { Label("More", systemImage: "ellipsis.circle.fill") }
                .tag(VoxglassTab.more)
        }
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

    static var launchDefault: VoxglassTab {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-VoxglassInitialTab"),
           arguments.indices.contains(index + 1),
           let tab = VoxglassTab(argument: arguments[index + 1]) {
            return tab
        }
        #endif
        return .home
    }

    private init?(argument: String) {
        switch argument.lowercased() {
        case "listen", "home":
            self = .home
        case "library":
            self = .library
        case "explore", "browse":
            self = .browse
        case "search":
            self = .search
        case "more", "settings":
            self = .more
        default:
            return nil
        }
    }
}
