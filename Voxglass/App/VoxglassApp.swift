import SwiftUI
import VoxglassCore
import CloudKit

@main
struct VoxglassApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var services = AppServices.shared
    @State private var discovery = DiscoveryEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(services.libraryStore)
                .environmentObject(services.catalogStore)
                .environment(services.playbackCoordinator)
                .environment(discovery)
                .environmentObject(services.homeRecommendationStore)
                .environmentObject(services.offlineDownloadManager)
                .environmentObject(services.cloudSync)
                .environmentObject(services.cloudKitSyncEngine)
                .environmentObject(services.listeningStatsStore)
                .environmentObject(services.folderWatchService)
                .environmentObject(services.playlistStore)
                .environmentObject(services.libraryBackupService)
                .environmentObject(services.phoneAudioRelay)
                .preferredColorScheme(.dark)
                .task {
                    await services.bootstrapOnce()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    services.playbackCoordinator.handleScenePhase(newPhase)
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // Device token delivered; CloudKit handles the rest
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Non-fatal on simulator / missing entitlements
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task {
            try? await AppServices.shared.cloudKitSyncEngine.fetchChanges()
            completionHandler(.newData)
        }
    }

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
