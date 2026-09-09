import Foundation
import Testing
@testable import VoxglassWatchCore
@testable import VoxglassWatchProtocol

@Suite("Watch playback")
struct WatchPlaybackTests {
    private let bookID = WatchBookID("book")

    private func chapter(url: URL? = URL(string: "https://example.com/chapter.mp3"), filename: String = "chapter.mp3") -> WatchChapterDTO {
        WatchChapterDTO(
            id: "chapter", index: 0, title: "Chapter", duration: 100, startTime: 12,
            expectedBytes: nil, expectedSHA256: nil, durableFilename: filename,
            approvedStreamURL: url
        )
    }

    @Test("Downloaded chapter wins and retains shared-file offset")
    func downloadedWins() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let expected = root.appendingPathComponent("book/chapter.mp3")
        let source = try WatchPlaybackSourceResolver.resolve(
            bookID: bookID, chapter: chapter(), downloadsRoot: root, allowsStreaming: true,
            fileExists: { $0 == expected }
        )
        #expect(source.kind == .downloaded)
        #expect(source.url == expected)
        #expect(source.assetOffset == 12)
    }

    @Test("Downloaded chapter works while disconnected")
    func downloadedDisconnected() throws {
        let source = try WatchPlaybackSourceResolver.resolve(
            bookID: bookID, chapter: chapter(), downloadsRoot: URL(fileURLWithPath: "/tmp/downloads"),
            allowsStreaming: false, fileExists: { _ in true }
        )
        #expect(source.kind == .downloaded)
    }

    @Test("App-written downloaded file is the resolved playback source")
    func realDownloadedFileResolves() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("book", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("chapter.mp3")
        try Data([0x1F, 0x0B]).write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = try WatchPlaybackSourceResolver.resolve(
            bookID: bookID, chapter: chapter(), downloadsRoot: root, allowsStreaming: false
        )
        #expect(source.kind == .downloaded)
        #expect(source.url == file)
    }

    @Test("Only approved credential-free HTTPS streams resolve")
    func streamPolicy() throws {
        let root = URL(fileURLWithPath: "/tmp/downloads")
        let valid = try WatchPlaybackSourceResolver.resolve(
            bookID: bookID, chapter: chapter(), downloadsRoot: root, allowsStreaming: true,
            fileExists: { _ in false }
        )
        #expect(valid.kind == .stream)

        for value in ["http://example.com/a.mp3", "https://user:pass@example.com/a.mp3", "file:///tmp/a.mp3"] {
            #expect(throws: WatchPlaybackResolutionError.chapterUnavailable) {
                try WatchPlaybackSourceResolver.resolve(
                    bookID: bookID, chapter: chapter(url: URL(string: value)), downloadsRoot: root,
                    allowsStreaming: true, fileExists: { _ in false }
                )
            }
        }
    }

    @Test("Remote playback is unavailable while disconnected")
    func streamDisconnected() {
        #expect(throws: WatchPlaybackResolutionError.chapterUnavailable) {
            try WatchPlaybackSourceResolver.resolve(
                bookID: bookID, chapter: chapter(), downloadsRoot: URL(fileURLWithPath: "/tmp/downloads"),
                allowsStreaming: false, fileExists: { _ in false }
            )
        }
    }

    @Test("Unsafe durable filenames are rejected")
    func unsafeFilename() {
        for filename in ["../chapter.mp3", "/tmp/chapter.mp3", "folder/chapter.mp3", "folder\\chapter.mp3", ""] {
            #expect(throws: WatchPlaybackResolutionError.invalidFilename) {
                try WatchPlaybackSourceResolver.resolve(
                    bookID: bookID, chapter: chapter(filename: filename),
                    downloadsRoot: URL(fileURLWithPath: "/tmp/downloads"), allowsStreaming: true
                )
            }
        }
    }

    @Test("Reducer never infers playing from preparation and ignores stale callbacks")
    func honestStateAndStaleEvents() {
        let initial = WatchPlaybackReducer.preparing(bookID: bookID, chapter: chapter(), chapterCount: 3, position: 0, token: 8)
        #expect(initial.phase == .preparing)
        #expect(WatchPlaybackReducer.reduce(initial, event: .playing, token: 7) == initial)
        #expect(WatchPlaybackReducer.reduce(initial, event: .playing, token: 8).phase == .playing)
    }

    @Test("Reducer exposes buffering, interruptions, route loss, and failures honestly")
    func stateTransitions() {
        let initial = WatchPlaybackReducer.preparing(bookID: bookID, chapter: chapter(), chapterCount: 3, position: 0, token: 1)
        #expect(WatchPlaybackReducer.reduce(initial, event: .waitingForOutput, token: 1).statusText == "Waiting for headphones")
        #expect(WatchPlaybackReducer.reduce(initial, event: .buffering, token: 1).phase == .buffering)
        #expect(WatchPlaybackReducer.reduce(initial, event: .interruption, token: 1).phase == .paused)
        let lost = WatchPlaybackReducer.reduce(initial, event: .routeLost, token: 1)
        #expect(lost.phase == .failed("Connect Bluetooth headphones, then try again."))
    }

    @Test("Time, progress, and chapter boundaries are safe")
    func timeAndBoundaries() {
        var initial = WatchPlaybackReducer.preparing(bookID: bookID, chapter: chapter(), chapterCount: 3, position: 0, token: 1)
        initial = WatchPlaybackReducer.reduce(initial, event: .time(position: .infinity, duration: .nan), token: 1)
        #expect(initial.position == 0)
        #expect(initial.progress == 0)
        #expect(!initial.canGoPrevious)
        #expect(initial.canGoNext)
        initial.chapterIndex = 2
        initial.position = 500
        #expect(initial.progress == 1)
        #expect(initial.canGoPrevious)
        #expect(!initial.canGoNext)
    }

    @Test("Position store round trips, permits backward seek, removes one book, and recovers corruption")
    func positionPersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = root.appendingPathComponent("positions.json")
        let store = WatchPlaybackPositionStore(url: url)
        try await store.save(42, bookID: "one", chapterID: "chapter")
        try await store.save(12, bookID: "one", chapterID: "chapter")
        try await store.save(.nan, bookID: "two", chapterID: "chapter")
        #expect(await store.position(bookID: "one", chapterID: "chapter") == 12)
        #expect(await store.position(bookID: "two", chapterID: "chapter") == 0)

        let reopened = WatchPlaybackPositionStore(url: url)
        #expect(await reopened.position(bookID: "one", chapterID: "chapter") == 12)
        try await reopened.remove(bookID: "one")
        #expect(await reopened.position(bookID: "one", chapterID: "chapter") == 0)

        try Data("broken".utf8).write(to: url)
        let recovered = WatchPlaybackPositionStore(url: url)
        #expect(await recovered.position(bookID: "two", chapterID: "chapter") == 0)
    }

    @Test("Watch production wiring contains required audio ownership and no optimistic facade")
    func productionWiring() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let engine = try String(contentsOf: root.appendingPathComponent("VoxglassWatch/WatchPlaybackEngine.swift"), encoding: .utf8)
        let service = try String(contentsOf: root.appendingPathComponent("VoxglassWatch/WatchAppServices.swift"), encoding: .utf8)
        // The dedicated Now Playing screen was merged into the book detail
        // view (one combined book + now-playing screen, not two) — the
        // progress-display guard below now applies to that file instead.
        let view = try String(contentsOf: root.appendingPathComponent("VoxglassWatch/WatchBookDetailView.swift"), encoding: .utf8)
        let app = try String(contentsOf: root.appendingPathComponent("VoxglassWatch/VoxglassWatchApp.swift"), encoding: .utf8)
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        let info = try String(contentsOf: root.appendingPathComponent("VoxglassWatch/Resources/Info.plist"), encoding: .utf8)

        for required in [
            "setCategory(.playback", ".spokenAudio", ".longFormAudio", "await session.activate",
            "MPNowPlayingInfoCenter.default()", "MPRemoteCommandCenter.shared()",
            "AVAudioSession.interruptionNotification", "AVAudioSession.routeChangeNotification",
            "nowPlayingInfo = nil", "WatchPlaybackSourceResolver.resolve", "streamingAllowed"
        ] {
            #expect(engine.contains(required), "Missing Watch playback wiring: \(required)")
        }
        #expect(app.contains("scenePhase") && app.contains("persistPlaybackPosition"),
                "Watch app must persist playback position on background")
        #expect(project.contains("sdk: MediaPlayer.framework"))
        #expect(info.contains("<string>audio</string>"))
        #expect(!service.contains("isPlaying: true"))
        #expect(!view.contains("ProgressView(value: 0.25)"))
        #expect(!engine.contains("PlaybackCoordinator"))
    }
}
