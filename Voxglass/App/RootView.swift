import SwiftUI
import VoxglassCore

struct RootView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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
                        tabsWithPresentation
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

    @ViewBuilder
    private var tabs: some View {
        if surface.usesSidebar {
            adaptiveTabs
        } else {
            compactTabs
        }
    }

    private var surface: VoxglassSurface {
        if VoxglassPlatform.isMacCatalyst || horizontalSizeClass == .regular {
            return .regular
        }
        return .compact
    }

    private var compactTabs: some View {
        TabView(selection: $selectedTab) {
            ListenView(showingNowPlaying: miniPlayerRouter.bindNowPlaying())
                .tag(VoxglassTab.listen)
                .toolbar(.hidden, for: .tabBar)
            LibraryView(showingNowPlaying: miniPlayerRouter.bindNowPlaying())
                .tag(VoxglassTab.library)
                .toolbar(.hidden, for: .tabBar)
            BrowseView(showingNowPlaying: miniPlayerRouter.bindNowPlaying())
                .tag(VoxglassTab.discover)
                .toolbar(.hidden, for: .tabBar)
            NarrationTabView()
                .tag(VoxglassTab.narration)
                .toolbar(.hidden, for: .tabBar)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
                GlassDock(
                    selectedTab: $selectedTab,
                    showingNowPlaying: miniPlayerRouter.bindNowPlaying()
                )
                .environment(playback)
            }
    }

    private var adaptiveTabs: some View {
        NavigationSplitView {
            List {
                Section("Voxglass") {
                    navigationRow(.listen, title: "Listen", systemImage: "headphones")
                    navigationRow(.library, title: "My Books", systemImage: "books.vertical.fill")
                    navigationRow(.discover, title: "Discover", systemImage: "square.grid.2x2.fill")
                    navigationRow(.narration, title: "Narration", systemImage: "mic.fill")
                }
            }
            .navigationTitle("Voxglass")
            .listStyle(.sidebar)
            .frame(minWidth: 220, idealWidth: 250)
        } detail: {
            ZStack {
                VoxglassBackground()
                tabContent
                    .frame(maxWidth: 1100, maxHeight: .infinity, alignment: .topLeading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let session = playback.currentSession,
                   miniPlayerRouter.shouldShowMiniPlayer(currentBookID: session.book.id) {
                    GlassMiniPlayer(showingNowPlaying: miniPlayerRouter.bindNowPlaying())
                        .onTapGesture {
                            miniPlayerRouter.presentNowPlayingFromMiniPlayer(currentBookID: session.book.id)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                        .environment(playback)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .background(VoxglassBackground())
        .overlay(alignment: .topLeading) {
            AdaptiveNavigationShortcuts(selection: $selectedTab)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .listen:
            ListenView(showingNowPlaying: miniPlayerRouter.bindNowPlaying())
        case .library:
            LibraryView(showingNowPlaying: miniPlayerRouter.bindNowPlaying())
        case .discover:
            BrowseView(showingNowPlaying: miniPlayerRouter.bindNowPlaying())
        case .narration:
            NarrationTabView()
        }
    }

    private func navigationRow(_ tab: VoxglassTab, title: String, systemImage: String) -> some View {
        Button {
            selectedTab = tab
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selectedTab == tab ? Palette.brass : Palette.ink)
        .listRowBackground(selectedTab == tab ? Palette.brass.opacity(0.14) : Color.clear)
            .accessibilityIdentifier("navigation.\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }

    private var tabsWithPresentation: some View {
        tabs
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
    case listen
    case library
    case discover
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
        return .listen
    }

    private init?(argument: String) {
        switch argument.lowercased() {
        case "listen", "home":
            self = .listen
        case "library":
            self = .library
        case "explore", "browse", "discover", "search":
            self = .discover
        case "narration":
            self = .narration
        default:
            return nil
        }
    }
}
