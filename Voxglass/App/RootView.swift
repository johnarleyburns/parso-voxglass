import SwiftUI
import VoxglassCore

struct RootView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @Environment(PlaybackCoordinator.self) private var playback
    @EnvironmentObject private var offlineDownloadManager: OfflineDownloadManager
    @EnvironmentObject private var phoneAudioRelay: PhoneAudioRelay
    @State private var selectedTab: VoxglassTab = .launchDefault
    @StateObject private var miniPlayerRouter = MiniPlayerPresentationRouter()
    @State private var showSplash = !ProcessInfo.processInfo.arguments.contains("-VoxglassDisableAnimatedSplash")
    @AppStorage(AppPreferencesStore.Keys.hasCompletedSplash) private var hasCompletedSplash = false
    @AppStorage(AppPreferencesStore.Keys.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @AppStorage(AppPreferencesStore.Keys.selectedCollectionIDs) private var selectedCollectionIDsRaw = ""

    var body: some View {
        ZStack {
            // The animated splash's own opacity fades in from 0, and it used
            // to sit as an overlay directly above the real content (tabs /
            // onboarding), both already built and rendering underneath —
            // during that fade-in, the real content was genuinely visible
            // through it (reported as "briefly seeing my last usage of the
            // app, very wide, then the splash"). Building the real content
            // only once the splash is done removes anything for it to fade
            // in over.
            if showSplash {
                AnimatedSplashView(isPresented: $showSplash)
                    .zIndex(10)
            } else {
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
            }

            if let toast = phoneAudioRelay.connectionToast {
                VStack {
                    Text(toast)
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .glassSurface(cornerRadius: 16)
                        .accessibilityIdentifier("watch.connectionToast")
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Spacer()
                }
                .safeAreaPadding(.top, 10)
                .zIndex(20)
            }
        }
        .tint(VoxglassTheme.accent)
        .animation(.easeInOut(duration: 0.2), value: phoneAudioRelay.connectionToast)
        .onChange(of: phoneAudioRelay.connectionToast) { _, value in
            guard value != nil else { return }
            Task {
                try? await Task.sleep(for: .seconds(3))
                phoneAudioRelay.connectionToast = nil
            }
        }
    }

    private var tabs: some View {
        ZStack {
            VoxglassBackground()

            TabView(selection: $selectedTab) {
                ListenView(
                    showingNowPlaying: miniPlayerRouter.bindNowPlaying(),
                    selectLibrary: { selectedTab = .library }
                )
                .tag(VoxglassTab.home)
                .toolbar(.hidden, for: .tabBar)

                LibraryView(showingNowPlaying: miniPlayerRouter.bindNowPlaying())
                    .tag(VoxglassTab.library)
                    .toolbar(.hidden, for: .tabBar)

                BrowseView(showingNowPlaying: miniPlayerRouter.bindNowPlaying())
                    .tag(VoxglassTab.browse)
                    .toolbar(.hidden, for: .tabBar)

                SearchView(showingNowPlaying: miniPlayerRouter.bindNowPlaying())
                    .tag(VoxglassTab.search)
                    .toolbar(.hidden, for: .tabBar)

                NarrationTabView()
                    .tag(VoxglassTab.narration)
                    .toolbar(.hidden, for: .tabBar)
            }
            // Keep the last item in child navigation stacks above the custom
            // dock. The dock's own safe-area inset handles the live height;
            // this is a fixed fallback for nested/custom scroll containers.
            .safeAreaPadding(.bottom, VoxglassLayout.chromeBottomClearance)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            GlassDock(
                selectedTab: $selectedTab,
                showingNowPlaying: miniPlayerRouter.bindNowPlaying()
            )
            .environment(playback)
        }
        .sheet(isPresented: miniPlayerRouter.bindNowPlaying()) {
            BookPageView(book: nil, showingNowPlaying: miniPlayerRouter.bindNowPlaying(), presentationContext: .nowPlayingSheet)
                .environment(playback)
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
    case narration

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
        case "narration":
            self = .narration
        default:
            return nil
        }
    }
}
