import SwiftUI
import VoxglassCore

@main
struct VoxglassWatchApp: App {
    @StateObject private var services = WatchAppServices.shared

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(services)
        }
    }
}
