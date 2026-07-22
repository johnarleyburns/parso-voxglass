import SwiftUI
import VoxglassCore

struct RootView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @EnvironmentObject private var offlineDownloadManager: OfflineDownloadManager
    @State private var selectedTab: VoxglassTab = .launchDefault
    @State private var showingNowPlaying = false
    @State private var showSplash = !ProcessInfo.processInfo.arguments.contains("-VoxglassDisableAnimatedSplash")
    @AppStorage(AppPreferencesStore.Keys.hasCompletedSplash) private var hasCompletedSplash = false
    @AppStorage(AppPreferencesStore.Keys.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @AppStorage(AppPreferencesStore.Keys.selectedCollectionIDs) private var selectedCollectionIDsRaw = ""

    var body: some View {
        ZStack {
            Group {
                if !hasCompletedSplash {
                    SplashView {
                        hasCompletedSplash = true
                    }
                } else if !hasCompletedOnboarding {
                    OnboardingPreferencesView(
                        initialSelection: AppPreferencesStore.decodeCollectionIDs(selectedCollectionIDsRaw)
                    ) { selectedCollectionIDs in
                        selectedCollectionIDsRaw = AppPreferencesStore.encodeCollectionIDs(selectedCollectionIDs)
                        hasCompletedOnboarding = true
                    } skipAction: {
                        selectedCollectionIDsRaw = ""
                        hasCompletedOnboarding = true
                    }
                } else {
                    tabs
                }
            }

            if showSplash {
                AnimatedSplashView(isPresented: $showSplash)
                    .zIndex(10)
            }
        }
        .tint(VoxglassTheme.accent)
    }

    private var tabs: some View {
        ZStack(alignment: .bottom) {
            VoxglassBackground()

            Group {
                switch selectedTab {
                case .home:
                    ListenView(
                        showingNowPlaying: $showingNowPlaying,
                        selectLibrary: { selectedTab = .library }
                    )
                case .library:
                    LibraryView(showingNowPlaying: $showingNowPlaying)
                case .browse:
                    BrowseView(showingNowPlaying: $showingNowPlaying)
                case .search:
                    SearchView(showingNowPlaying: $showingNowPlaying)
                case .more:
                    SettingsView(showingNowPlaying: $showingNowPlaying)
                }
            }

            GlassDock(
                selectedTab: $selectedTab,
                showingNowPlaying: $showingNowPlaying
            )
            .environmentObject(playback)
        }
        .sheet(isPresented: $showingNowPlaying) {
            BookPageView(book: nil, showingNowPlaying: $showingNowPlaying)
                .environmentObject(playback)
                .environmentObject(libraryStore)
                .environmentObject(offlineDownloadManager)
                .presentationDragIndicator(.visible)
        }
        .task {
            if libraryStore.books.isEmpty {
                await libraryStore.refresh()
            }
        }
    }
}

enum VoxglassTab: Hashable {
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
