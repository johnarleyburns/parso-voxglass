import SwiftUI
import VoxglassCore

struct RootView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @Environment(PlaybackCoordinator.self) private var playback
    @EnvironmentObject private var offlineDownloadManager: OfflineDownloadManager
    @EnvironmentObject private var phoneAudioRelay: PhoneAudioRelay
    @State private var selectedTab: VoxglassTab = .launchDefault
    @State private var miniPlayerRouter = MiniPlayerPresentationRouter()
    @Namespace private var zoomNamespace
    @State private var showSplash = !ProcessInfo.processInfo.arguments.contains("-VoxglassDisableAnimatedSplash")
    @AppStorage(AppPreferencesStore.Keys.hasCompletedSplash) private var hasCompletedSplash = false
    @AppStorage(AppPreferencesStore.Keys.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @AppStorage(AppPreferencesStore.Keys.selectedCollectionIDs) private var selectedCollectionIDsRaw = ""

    var body: some View {
        ZStack {
            if showSplash {
                AnimatedSplashView(isPresented: $showSplash).zIndex(10)
            } else if !hasCompletedSplash {
                SplashView { hasCompletedSplash = true }
            } else if !hasCompletedOnboarding {
                OnboardingPreferencesView(initialSelection: AppPreferencesStore.decodeCollectionIDs(selectedCollectionIDsRaw)) { ids in
                    selectedCollectionIDsRaw = AppPreferencesStore.encodeCollectionIDs(ids)
                    hasCompletedOnboarding = true
                } skipAction: {
                    selectedCollectionIDsRaw = ""
                    hasCompletedOnboarding = true
                }
            } else {
                tabsWithPresentation
            }

            if let toast = phoneAudioRelay.connectionToast {
                VStack {
                    Text(toast)
                        .voxType(.body)
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .glassEffect(.regular, in: .capsule)
                        .accessibilityIdentifier("watch.connectionToast")
                    Spacer()
                }
                .safeAreaPadding(.top, 10)
                .zIndex(20)
            }
        }
        .tint(VoxglassTheme.accent)
        .environment(miniPlayerRouter)
        .environment(\.voxglassZoomNamespace, zoomNamespace)
        .animation(.easeInOut(duration: 0.2), value: phoneAudioRelay.connectionToast)
        .onChange(of: playback.currentSession) { _, _ in
            WidgetSnapshotWriter.write(playback: playback)
        }
        .onChange(of: playback.currentSession?.isPlaying) { _, _ in
            WidgetSnapshotWriter.write(playback: playback)
        }
        .onChange(of: phoneAudioRelay.connectionToast) { _, value in
            guard value != nil else { return }
            Task {
                try? await Task.sleep(for: .seconds(3))
                phoneAudioRelay.connectionToast = nil
            }
        }
    }

    private var tabsWithPresentation: some View {
        TabView(selection: $selectedTab) {
            Tab("Listen", systemImage: "headphones", value: VoxglassTab.listen) {
                ListenView(showingNowPlaying: miniPlayerRouter.bindNowPlaying())
            }
            Tab("My Books", systemImage: "books.vertical", value: VoxglassTab.library) {
                LibraryView(showingNowPlaying: miniPlayerRouter.bindNowPlaying())
            }
            Tab("Discover", systemImage: "square.grid.2x2", value: VoxglassTab.discover) {
                BrowseView(showingNowPlaying: miniPlayerRouter.bindNowPlaying())
            }
            Tab("Narrate", systemImage: "mic", value: VoxglassTab.narration) {
                NarrationTabView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            MiniPlayerAccessory().environment(playback)
        }
        .sheet(isPresented: miniPlayerRouter.bindNowPlaying()) {
            BookPageView(book: nil, showingNowPlaying: miniPlayerRouter.bindNowPlaying(), presentationContext: .nowPlayingSheet)
                .environment(playback)
                .environmentObject(libraryStore)
                .environmentObject(offlineDownloadManager)
                .presentationDragIndicator(.visible)
        }
        .overlay(alignment: .topLeading) { AdaptiveNavigationShortcuts(selection: $selectedTab) }
        .task {
            if libraryStore.books.isEmpty { await libraryStore.refresh() }
            WidgetSnapshotWriter.write(playback: playback)
        }
        .task(id: "widget-snapshot-refresh") {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                WidgetSnapshotWriter.write(playback: playback)
            }
        }
        .task(id: "widget-command-poll") {
            while !Task.isCancelled {
                await handleWidgetCommand()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @MainActor
    private func handleWidgetCommand() async {
        guard WidgetPlaybackCommandStore.consume() == .resume else { return }
        if playback.currentSession == nil {
            await playback.restorePresentedSession(from: libraryStore.books)
        }
        if let session = playback.currentSession {
            if !session.isPlaying { playback.togglePlayPause() }
        } else if let book = libraryStore.recentlyPlayed.first {
            await playback.play(book)
        }
        WidgetSnapshotWriter.write(playback: playback)
    }
}

enum VoxglassTab: Hashable {
    case listen, library, discover, narration

    static var launchDefault: VoxglassTab {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-VoxglassInitialTab"), arguments.indices.contains(index + 1), let tab = VoxglassTab(argument: arguments[index + 1]) { return tab }
        #endif
        return .listen
    }

    private init?(argument: String) {
        switch argument.lowercased() {
        case "listen", "home": self = .listen
        case "library": self = .library
        case "explore", "browse", "discover", "search": self = .discover
        case "narration", "narrate": self = .narration
        default: return nil
        }
    }
}
