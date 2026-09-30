import Foundation
import Testing

/// Source contract for the Siri intents (the app target is not compiled by
/// `swift test`). Pins the two properties that decide whether an intent works
/// hands-free in CarPlay: playback intents are `AudioPlaybackIntent`s, and
/// none of them asks to foreground the app — Siri refuses those while driving.
@Suite struct VoxglassIntentsContractTests {
    private static let appPath = "Voxglass/App/VoxglassIntents.swift"
    private static let sharedPath = "VoxglassShared/PlaybackControlIntents.swift"

    @Test func playbackIntentsAreAudioPlaybackIntents() throws {
        let appText = try source(Self.appPath)
        let sharedText = try source(Self.sharedPath)
        #expect(sharedText.contains("struct ResumeListeningIntent: AudioPlaybackIntent"))
        #expect(!withoutLineComments(appText).contains("struct ResumeListeningIntent"))
        #expect(appText.contains("struct PlayBookIntent: AudioPlaybackIntent"))
    }

    @Test func noIntentForegroundsTheApp() throws {
        let appText = try source(Self.appPath)
        let sharedText = try source(Self.sharedPath)
        #expect(!appText.contains("openAppWhenRun = true"))
        #expect(!sharedText.contains("openAppWhenRun = true"))
        let appIntents = declarationCount(appText, marker: ": AudioPlaybackIntent")
        let sharedIntents = declarationCount(sharedText, marker: "static let openAppWhenRun = false")
        #expect(appIntents == 1)
        #expect(sharedIntents == 5)
        #expect(declarationCount(appText, marker: "static let openAppWhenRun = false") == appIntents)
    }

    @Test func everyShortcutPhraseNamesTheApp() throws {
        let text = try source(Self.appPath)
        let phrases = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("\"") && $0.contains("\\(") }
        #expect(!phrases.isEmpty)
        for phrase in phrases {
            #expect(phrase.contains("\\(.applicationName)"), "\(phrase)")
        }
    }

    @Test func siriBookLookupSharesTheCarPlaySearchMatcher() throws {
        let intents = try source(Self.appPath)
        let carPlay = try source("Voxglass/Core/CarPlay/CarPlayMenuBuilder.swift")
        #expect(intents.contains("LibraryVoiceSearch.rank("))
        #expect(carPlay.contains("LibraryVoiceSearch.rank("))
    }

    @Test func libraryObservationIsWiredAtBootstrap() throws {
        let services = try source("Voxglass/App/AppServices.swift")
        #expect(services.contains("VoxglassIntentBridge.observeLibrary(libraryStore)"))
    }

    @Test func sharedAndWidgetTargetsHaveNoSecondPlaybackStore() throws {
        let paths = [
            "VoxglassShared/PlaybackControlIntents.swift",
            "VoxglassShared/PlaybackCommand.swift",
            "VoxglassShared/BookActivityAttributes.swift",
            "VoxglassWidgets/VoxglassWidgets.swift",
            "VoxglassWidgets/PlaybackCommandRouter.swift"
        ]
        for path in paths {
            let text = try source(path)
            for forbidden in ["PositionStore", "SQLitePositionStore", "AppDatabase(", "LibraryRepository"] {
                #expect(!text.contains(forbidden), "Second playback store leaked into \(path): \(forbidden)")
            }
        }
    }

    @Test func skipCommandsUseStoredIntervals() throws {
        let router = try source("Voxglass/App/PlaybackCommandRouter.swift")
        #expect(router.contains("Keys.skipBackInterval"))
        #expect(router.contains("Keys.skipForwardInterval"))
        #expect(!router.contains("skip(by: -15"))
        #expect(!router.contains("skip(by: 30"))
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func declarationCount(_ text: String, marker: String) -> Int {
        text.split(separator: "\n").count { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("//") && trimmed.contains(marker)
        }
    }

    private func withoutLineComments(_ text: String) -> String {
        text.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
