import SwiftUI
import VoxglassCore

@main
struct VoxglassApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var services = AppServices()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(services.libraryStore)
                .environmentObject(services.catalogStore)
                .environmentObject(services.playbackCoordinator)
                .environmentObject(services.homeRecommendationStore)
                .environmentObject(services.offlineDownloadManager)
                .environmentObject(services.cloudSync)
                .environmentObject(services.listeningStatsStore)
                .environmentObject(services.folderWatchService)
                .environmentObject(services.playlistStore)
                .environmentObject(services.libraryBackupService)
                .preferredColorScheme(.dark)
                .task {
                    await services.bootstrap()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    services.playbackCoordinator.handleScenePhase(newPhase)
                }
        }
    }
}

/// Receives background `URLSession` relaunch events and hands the system
/// completion handler to the offline download manager (§7).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == OfflineDownloadManager.sessionIdentifier,
              let manager = OfflineDownloadManager.current else {
            completionHandler()
            return
        }
        manager.handleBackgroundEvents(completionHandler: completionHandler)
    }
}
