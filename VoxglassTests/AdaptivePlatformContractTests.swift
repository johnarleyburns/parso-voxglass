import Foundation
import Testing

/// These contracts keep the adaptive surface from silently regressing to a
/// phone-only shell. The app target is not part of the host Swift package,
/// so the source-level assertions are the appropriate headless guard; the
/// concrete Catalyst and iOS builds remain the compiler-level guards.
@Suite struct AdaptivePlatformContractTests {
    @Test func regularSurfaceUsesPersistentNavigation() throws {
        let root = repositoryRoot()
        let rootView = try source("Voxglass/App/RootView.swift", root: root)
        let adaptiveSurface = try source("Voxglass/App/AdaptiveSurface.swift", root: root)

        #expect(rootView.contains(".tabViewStyle(.sidebarAdaptable)"))
        #expect(rootView.contains("Tab(\"Listen\""))
        #expect(rootView.contains("Tab(\"Narrate\""))
        #expect(rootView.contains("MiniPlayerAccessory"))
        #expect(adaptiveSurface.contains("KeyEquivalent(\"1\")"))
        #expect(adaptiveSurface.contains("KeyEquivalent(\"4\")"))
        #expect(adaptiveSurface.contains("textDidBeginEditingNotification"))
        #expect(adaptiveSurface.contains("VoxglassConditionalKeyboardShortcut"))
    }

    @Test func catalystBuildAndWatchEmbeddingContract() throws {
        let root = repositoryRoot()
        let project = try source("project.yml", root: root)
        let audio = try source("Voxglass/Features/Production/Discovery/AudioSessionCapture.swift", root: root)
        let readme = try source("README.md", root: root)

        #expect(project.contains("SUPPORTS_MACCATALYST: YES"))
        #expect(project.contains("platformFilter: iOS"))
        #expect(audio.contains("session.availableInputs"))
        #expect(audio.contains("setPreferredInput"))
        #expect(readme.contains("platform=macOS,variant=Mac Catalyst"))
    }

    @Test func narrationKeyboardMapAndRegularPresentationContract() throws {
        let root = repositoryRoot()
        let narrationTab = try source("Voxglass/Features/Production/Discovery/NarrationTabView.swift", root: root)
        let flow = try source("Voxglass/Features/Production/Discovery/NarrationFlow.swift", root: root)
        let screens = try source("Voxglass/Features/Production/Discovery/NarrationFlowScreens.swift", root: root)

        #expect(narrationTab.contains(".sheet(item: $flowNeed)"))
        #expect(narrationTab.contains("frame(minWidth: 720, minHeight: 600)"))
        #expect(flow.contains("keyboardShortcut(.escape"))
        #expect(screens.contains("VoxglassKeyboardShortcut.record"))
        #expect(screens.contains("voxglassKeyboardShortcut(.space"))
        #expect(screens.contains("voxglassKeyboardShortcut(.return"))
        #expect(screens.contains("voxglassKeyboardShortcut(.leftArrow"))
        #expect(screens.contains("voxglassKeyboardShortcut(.rightArrow"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String, root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
