import SwiftUI
import VoxglassCore
import VoxglassWatchCore

struct RootView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @Environment(PlaybackCoordinator.self) private var playback
    @EnvironmentObject private var offlineDownloadManager: OfflineDownloadManager
    @EnvironmentObject private var phoneAudioRelay: PhoneAudioRelay
    @State private var selectedTab: VoxglassTab = .launchDefault
    @State private var miniPlayerRouter = MiniPlayerPresentationRouter()
    @State private var deepLinkedBook: DeepLinkedBook?
    @State private var watchTransferBannerDismissed = false
    @Namespace private var zoomNamespace

    var body: some View {
        ZStack {
            tabsWithPresentation

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
        .onChange(of: playback.sleepMode) { _, _ in
            WidgetSnapshotWriter.write(playback: playback)
        }
        .onReceive(NotificationCenter.default.publisher(for: .playbackAccessibilityAnnouncement)) { notification in
            guard let message = notification.object as? String else { return }
            AccessibilityNotification.Announcement(message).post()
        }
        .onReceive(NotificationCenter.default.publisher(for: .offlineBookDownloadCompleted)) { notification in
            guard let bookID = notification.object as? UUID,
                  let title = libraryStore.book(withID: bookID)?.book.title else { return }
            AccessibilityNotification.Announcement("\(title) downloaded").post()
        }
        .onChange(of: phoneAudioRelay.connectionToast) { _, value in
            guard value != nil else { return }
            Task {
                try? await Task.sleep(for: .seconds(3))
                phoneAudioRelay.connectionToast = nil
            }
        }
    }

    private var showsWatchTransferBanner: Bool {
        phoneAudioRelay.watchTransferStatusBanner != nil && !watchTransferBannerDismissed
    }

    private func openWatchList() {
        selectedTab = .library
        NotificationCenter.default.post(name: .showMyWatchBooks, object: nil)
    }

    private var tabsWithPresentation: some View {
        tabShell
            .modifier(MiniPlayerBottomAccessory(watchBanner: showsWatchTransferBanner ? phoneAudioRelay.watchTransferStatusBanner : nil, openWatch: openWatchList, dismissWatch: { watchTransferBannerDismissed = true }))
            .onChange(of: phoneAudioRelay.watchTransferStatusBanner == nil) { _, isEmpty in
                if isEmpty { watchTransferBannerDismissed = false }
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
        .sheet(item: $deepLinkedBook) { destination in
            BookPageView(
                book: libraryStore.book(withID: destination.id),
                showingNowPlaying: .constant(false),
                presentationContext: .nowPlayingSheet
            )
            .environment(playback)
            .environmentObject(libraryStore)
            .environmentObject(offlineDownloadManager)
            .environmentObject(phoneAudioRelay)
            .presentationDragIndicator(.visible)
        }
        // Watch "Continue on iPhone" hands off here (after the person accepts it in the App
        // Switcher) and opens My Books, where "Download to Apple Watch" lives.
        .onContinueUserActivity(WatchHandoffRoute.activityType) { activity in
            if WatchHandoffRoute.route(forActivityType: activity.activityType) == .library {
                selectedTab = .library
            }
        }
        .onOpenURL { url in
            guard url.scheme == "voxglass", url.host == "book",
                  let bookID = UUID(uuidString: url.pathComponents.dropFirst().joined(separator: "/")) else { return }
            deepLinkedBook = DeepLinkedBook(id: bookID)
        }
    }

    private var tabShell: some View {
        TabView(selection: $selectedTab) {
            Tab("Listen", systemImage: "headphones", value: VoxglassTab.listen) {
                ListenView(showingNowPlaying: miniPlayerRouter.bindNowPlaying())
            }
            Tab("My Books", systemImage: "books.vertical", value: VoxglassTab.library) {
                LibraryView(showingNowPlaying: miniPlayerRouter.bindNowPlaying())
            }
            // Dedicated search/discovery destination belongs at the trailing end.
            Tab("Find", systemImage: "magnifyingglass", value: VoxglassTab.find) {
                BrowseView(showingNowPlaying: miniPlayerRouter.bindNowPlaying())
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .accessibilityAction(.magicTap) {
            playback.togglePlayPause()
        }
    }

    @MainActor
    private func handleWidgetCommand() async {
        guard let command = WidgetPlaybackCommandStore.consume() else { return }
        switch command {
        case .resume:
            if playback.currentSession == nil {
                await playback.restorePresentedSession(from: libraryStore.books)
            }
            if let session = playback.currentSession {
                if !session.isPlaying { playback.togglePlayPause() }
            } else if let book = libraryStore.recentlyPlayed.first {
                await playback.play(book)
            }
        case .togglePlayPause:
            playback.togglePlayPause()
        case .skipBackward:
            await playback.skip(by: -15)
        case .skipForward:
            await playback.skip(by: 30)
        }
        WidgetSnapshotWriter.write(playback: playback)
    }
}

private struct DeepLinkedBook: Identifiable {
    let id: UUID
}

extension Notification.Name {
    static let showMyWatchBooks = Notification.Name("voxglass.showMyWatchBooks")
}

private struct MiniPlayerBottomAccessory: ViewModifier {
    @Environment(PlaybackCoordinator.self) private var playback
    let watchBanner: WatchTransferStatusBanner?
    let openWatch: () -> Void
    let dismissWatch: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        content.tabViewBottomAccessory {
            VStack(spacing: 6) {
                if let watchBanner {
                    WatchTransferPill(banner: watchBanner, open: openWatch, dismiss: dismissWatch)
                }
                MiniPlayerAccessory().environment(playback)
            }
        }
    }
}

private struct WatchTransferPill: View {
    let banner: WatchTransferStatusBanner
    let open: () -> Void
    let dismiss: () -> Void

    var body: some View {
        let label = WatchTransferStatusBannerResolver.label(for: banner)
        HStack(spacing: 0) {
            Button(action: open) {
                HStack(spacing: 8) {
                    Image(systemName: banner.hasFailure ? "exclamationmark.triangle.fill" : "applewatch")
                    Text(label).voxType(.body).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .foregroundStyle(banner.hasFailure ? Color.red : Palette.ink)
                .padding(.leading, 16)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityHint("Opens books on Apple Watch")
            .accessibilityIdentifier("watch.transferBanner")
            Button(action: dismiss) {
                Image(systemName: "xmark").frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss Apple Watch status")
            .accessibilityIdentifier("watch.transferBanner.dismiss")
        }
    }
}

enum VoxglassTab: Hashable {
    case listen, library, find

    /// Display order in the tab bar; Find is trailing.
    static let tabBarOrder: [VoxglassTab] = [.listen, .library, .find]

    static var launchDefault: VoxglassTab {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-VoxglassInitialTab"), arguments.indices.contains(index + 1), let tab = VoxglassTab(argument: arguments[index + 1]) { return tab }
        #endif
        return .listen
    }

    init?(argument: String) {
        switch argument.lowercased() {
        case "listen", "home": self = .listen
        case "library": self = .library
        case "find", "search", "explore", "browse", "discover": self = .find
        default: return nil
        }
    }
}
