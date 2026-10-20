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

    private func swiftFiles(under directory: String) -> [URL] {
        let base = repoRoot.appendingPathComponent(directory)
        let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    @Test func obsoleteLaunchGateFilesAndAssetsStayDeleted() {
        let fm = FileManager.default
        for path in [
            "Voxglass/Features/Onboarding",
            "Voxglass/Resources/Assets.xcassets/splash.imageset",
        ] {
            #expect(!fm.fileExists(atPath: repoRoot.appendingPathComponent(path).path), "\(path) was reintroduced")
        }
    }

    @Test func noAppAuthoredLaunchInterstitialIsReintroduced() throws {
        let banned = ["struct SplashView", "struct AnimatedSplashView", "struct OnboardingPreferencesView",
                      "hasCompletedSplash", "hasCompletedOnboarding", "Image(\"splash\")"]
        for file in swiftFiles(under: "Voxglass") {
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in banned {
                #expect(!text.contains(token), "\(token) found in \(file.lastPathComponent)")
            }
        }
    }

    @Test func staticLaunchScreenIsKept() throws {
        let plist = try source("Voxglass/Resources/Info.plist")
        #expect(plist.contains("<key>UILaunchScreen</key>"))
        let project = try source("project.yml")
        #expect(project.contains("UILaunchScreen:"))
    }

    @Test func deepLinkRoutingAndNormalTabsRemainAvailable() throws {
        let root = try source("Voxglass/App/RootView.swift")
        #expect(root.contains("url.scheme == \"voxglass\", url.host == \"book\""))
        #expect(root.contains("deepLinkedBook = DeepLinkedBook(id: bookID)"))
        #expect(root.contains("guru.parso.voxglass.watch.library"))
        #expect(root.contains("case listen, library, narration, find"))
        #expect(root.contains("[.listen, .library, .narration, .find]"))
        #expect(root.contains("return .listen"))
    }
}
