import Foundation
import Testing

/// Source contract for the Siri intents (the app target is not compiled by
/// `swift test`). Pins the two properties that decide whether an intent works
/// hands-free in CarPlay: playback intents are `AudioPlaybackIntent`s, and
/// none of them asks to foreground the app — Siri refuses those while driving.
@Suite struct VoxglassIntentsContractTests {
    private static let path = "Voxglass/App/VoxglassIntents.swift"

    @Test func playbackIntentsAreAudioPlaybackIntents() throws {
        let text = try source(Self.path)
        #expect(text.contains("struct ResumeListeningIntent: AudioPlaybackIntent"))
        #expect(text.contains("struct PlayBookIntent: AudioPlaybackIntent"))
    }

    @Test func noIntentForegroundsTheApp() throws {
        let text = try source(Self.path)
        #expect(!text.contains("openAppWhenRun = true"))
        let intents = text.components(separatedBy: ": AudioPlaybackIntent").count - 1
        let backgroundOnly = text.components(separatedBy: "static let openAppWhenRun = false").count - 1
        #expect(intents >= 2)
        #expect(backgroundOnly == intents)
    }

    @Test func everyShortcutPhraseNamesTheApp() throws {
        let text = try source(Self.path)
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
        let intents = try source(Self.path)
        let carPlay = try source("Voxglass/Core/CarPlay/CarPlayMenuBuilder.swift")
        #expect(intents.contains("LibraryVoiceSearch.rank("))
        #expect(carPlay.contains("LibraryVoiceSearch.rank("))
    }

    @Test func libraryObservationIsWiredAtBootstrap() throws {
        let services = try source("Voxglass/App/AppServices.swift")
        #expect(services.contains("VoxglassIntentBridge.observeLibrary(libraryStore)"))
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
