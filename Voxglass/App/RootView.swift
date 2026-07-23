import SwiftUI
import VoxglassCore

struct RootView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @EnvironmentObject private var offlineDownloadManager: OfflineDownloadManager
    @State private var selectedTab: VoxglassTab = .launchDefault
    @StateObject private var miniPlayerRouter = MiniPlayerPresentationRouter()
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
                        showingNowPlaying: miniPlayerRouter.bindNowPlaying(),
                        selectLibrary: { selectedTab = .library }
                    )
                case .library:
                    LibraryView(showingNowPlaying: miniPlayerRouter.bindNowPlaying())
                case .browse:
                    BrowseView(showingNowPlaying: miniPlayerRouter.bindNowPlaying())
                case .search:
                    SearchView(showingNowPlaying: miniPlayerRouter.bindNowPlaying())
                case .more:
                    SettingsView(showingNowPlaying: miniPlayerRouter.bindNowPlaying())
                }
            }

            GlassDock(
                selectedTab: $selectedTab,
                showingNowPlaying: miniPlayerRouter.bindNowPlaying()
            )
            .environmentObject(playback)
        }
        .sheet(isPresented: miniPlayerRouter.bindNowPlaying()) {
            BookPageView(book: nil, showingNowPlaying: miniPlayerRouter.bindNowPlaying(), presentationContext: .nowPlayingSheet)
                .environmentObject(playback)
                .environmentObject(libraryStore)
                .environmentObject(offlineDownloadManager)
                .presentationDragIndicator(.visible)
        }
        .environmentObject(miniPlayerRouter)
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
