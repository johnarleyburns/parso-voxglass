import SwiftUI
import WatchKit

@main
struct VoxglassWatchApp: App {
    @StateObject private var services = WatchAppServices.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(services)
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { services.persistPlaybackPosition() }
                }
        }
    }
}
