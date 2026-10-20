import Foundation
import Testing
@testable import VoxglassCore

@Suite struct LaunchRoutingTests {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func rootViewEntersTabShellWithoutFirstRunGate() throws {
        let root = try source("Voxglass/App/RootView.swift")
        #expect(!root.contains("hasCompletedSplash"))
        #expect(!root.contains("hasCompletedOnboarding"))
        #expect(!root.contains("SplashView"))
        #expect(!root.contains("OnboardingPreferencesView"))
        #expect(root.contains("tabsWithPresentation"))
        #expect(root.contains(".onOpenURL"))
        #expect(root.contains("MiniPlayerBottomAccessory"))
    }

    @Test func legacyFirstRunKeysAreNotInPreferences() throws {
        let prefs = try source("Voxglass/Core/AppPreferencesStore.swift")
        #expect(!prefs.contains("hasCompletedSplash"))
        #expect(!prefs.contains("hasCompletedOnboarding"))
        #expect(prefs.contains("selectedCollectionIDs"))
        #expect(prefs.contains("selectedLanguages"))
    }
}
