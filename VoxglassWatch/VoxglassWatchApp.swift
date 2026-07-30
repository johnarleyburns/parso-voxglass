import SwiftUI
import VoxglassCore
import WatchKit

@main
struct VoxglassWatchApp: App {
    @StateObject private var services = WatchAppServices.shared

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(services)
                .environmentObject(services.offlineManager)
        }
    }
}
