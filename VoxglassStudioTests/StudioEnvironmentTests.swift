import Foundation
import Testing
import VoxglassCore
@testable import VoxglassStudioKit

@MainActor
@Suite struct StudioEnvironmentTests {

    // MARK: - .test(seed:) wiring (§4.3, §19.6)

    @Test func testEnvironmentIsFlaggedAndWiresFakes() {
        let env = StudioEnvironment.test(seed: .empty)
        #expect(env.isTestEnvironment)
        #expect(env.capture is UITestAudioCapture)
        #expect(env.license.provider is UITestLicenseProvider)
        #expect(env.transcoder is UITestTranscoder)
    }

    @Test func testEnvironmentVariantsAllWireFakes() {
        for seed in UITestSeed.allCases {
            let env = StudioEnvironment.test(seed: seed)
            #expect(env.isTestEnvironment, "seed \(seed.rawValue) must flag the test environment")
            #expect(env.capture is UITestAudioCapture, "seed \(seed.rawValue) must wire the fake capture")
        }
    }

    // MARK: - Launch-argument parsing (§19.6)

    @Test func uiTestSeedParsesArguments() {
        #expect(UITestSeed(arguments: ["-uiTestSeed", "empty"]) == .empty)
        #expect(UITestSeed(arguments: ["-uiTestSeed", "onePreviewProject"]) == .onePreviewProject)
        #expect(UITestSeed(arguments: ["-uiTestSeed", "watchQueue"]) == .watchQueue)
        #expect(UITestSeed(arguments: ["-uiTestSeed", "oneFlaggedQueue"]) == .oneFlaggedQueue)
        #expect(UITestSeed(arguments: ["-uiTestSeed", "librivoxReady"]) == .librivoxReady)
        #expect(UITestSeed(arguments: []) == nil)
        #expect(UITestSeed(arguments: ["-useTemporaryStore"]) == nil)
        #expect(UITestSeed(arguments: ["-uiTestSeed"]) == nil)
        #expect(UITestSeed(arguments: ["-uiTestSeed", "bogus"]) == nil)
        #expect(UITestSeed(arguments: ["-uiTestSeed", "empty", "-useTemporaryStore"]) == .empty)
    }

    @Test func everySeedArgumentHasACompanionLaunchArgumentsSet() {
        // `.live` is never reachable when a seed is present: the seed branch
        // wins in `StudioApp.init` before the `-useTemporaryStore` branch.
        for seed in UITestSeed.allCases {
            let args = ["-uiTestSeed", seed.rawValue, "-useTemporaryStore"]
            #expect(UITestSeed(arguments: args) == seed)
        }
    }

    // MARK: - Navigation model (§18.1.1)

    @Test func navigateToTabAndSheet() {
        let env = StudioEnvironment.test(seed: .empty)
        env.navigate(to: .record)
        #expect(env.selectedTab == .record)
        #expect(env.presentedSheet == nil)

        env.navigate(to: .sourceImport)
        #expect(env.presentedSheet == .sourceImport)

        env.navigate(to: .dashboard)
        #expect(env.selectedTab == .dashboard)
        #expect(env.presentedSheet == nil)
    }

    @Test func closeProjectReturnsToLibrary() {
        let env = StudioEnvironment.test(seed: .empty)
        var dismissed = false
        env.onDismissProjectWindow = { dismissed = true }
        env.setProject(AudiobookProject(
            id: UUID(),
            metadata: BookMetadata(title: "T", author: "A", narrator: "N")
        ))
        #expect(env.selectedTab == .dashboard)
        env.closeProject()
        #expect(env.currentProject == nil)
        #expect(dismissed)
    }
}
