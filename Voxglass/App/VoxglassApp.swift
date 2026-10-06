// SPDX-License-Identifier: GPL-3.0-or-later
//
// Voxglass — Copyright (C) 2026 John Arley Burns.
// Licensed under the GNU General Public License v3.0 or later, with an
// additional permission under GPLv3 §7 allowing distribution through
// Apple's App Store. Full text, including that permission: ../../LICENSE.
// Source: https://github.com/johnarleyburns/parso-voxglass

import SwiftUI
import VoxglassCore
import CloudKit
import os

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
                .task {
                    discovery.phoneProduction = services.productionEnvironment
                    discovery.library = NarrationLibraryImporter(services: services)
                    await services.bootstrapOnce()
                    if discovery.isAuthoringV2SyncEnabled {
                        await discovery.syncAuthoringV2Now()
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    services.playbackCoordinator.handleScenePhase(newPhase)
                }
        }
    }
}

/// Small, durable launch breadcrumb for failures that never become a crash
/// report. iOS watchdog terminations and jetsam events can leave TestFlight
/// with no ordinary exception report, while this file still tells us which
/// bootstrap phase was active on the next launch.
@MainActor
final class LaunchDiagnostics {
    static let shared = LaunchDiagnostics()

    private static let logger = Logger(subsystem: "guru.parso.voxglass", category: "launch")
    private let fileURL: URL
    private var record: [String: Any] = [:]

    private init() {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        let directory = support.appendingPathComponent("Voxglass", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("launch-diagnostics.json")

        if let data = try? Data(contentsOf: fileURL),
           let previous = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let state = previous["state"] as? String,
           state == "running" || state == "deferred" {
            let phase = previous["phase"] as? String ?? "unknown"
            Self.logger.error("previous launch ended during phase=\(phase, privacy: .public)")
        }
    }

    func begin() {
        record = [
            "state": "running",
            "phase": "app-delegate",
            "startedAt": Date().timeIntervalSince1970,
            "updatedAt": Date().timeIntervalSince1970
        ]
        write()
        Self.logger.info("launch started")
    }

    func phase(_ name: String) {
        record["phase"] = name
        record["updatedAt"] = Date().timeIntervalSince1970
        write()
        Self.logger.info("launch phase=\(name, privacy: .public)")
    }

    func markInteractive() {
        record["state"] = "ready"
        record["phase"] = "interactive"
        record["updatedAt"] = Date().timeIntervalSince1970
        write()
        Self.logger.info("launch interactive")
    }

    func beginDeferredWork() {
        record["state"] = "deferred"
        record["updatedAt"] = Date().timeIntervalSince1970
        write()
    }

    func finishDeferredWork() {
        record["state"] = "ready"
        record["phase"] = "complete"
        record["updatedAt"] = Date().timeIntervalSince1970
        write()
        Self.logger.info("launch bootstrap complete")
    }

    private func write() {
        guard JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else {
            return
        }
        try? data.write(to: fileURL, options: .atomic)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        LaunchDiagnostics.shared.begin()
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
            await AppServices.shared.cloudKitSyncEngine.fetchChanges()
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
