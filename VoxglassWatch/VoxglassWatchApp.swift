import SwiftUI
import VoxglassCore
import WatchKit
import CloudKit

@main
struct VoxglassWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    @StateObject private var services = WatchAppServices.shared

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(services)
        }
    }
}

final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        WKApplication.shared().registerForRemoteNotifications()
    }

    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        // Device token delivered
    }

    func didFailToRegisterForRemoteNotificationsWithError(_ error: Error) {
        // Non-fatal
    }

    func didReceiveRemoteNotification(
        _ userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (WKBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            try? await WatchAppServices.shared.syncEngine?.fetchChanges()
            await WatchAppServices.shared.libraryStore.refresh()
            completionHandler(.newData)
        }
    }
}
