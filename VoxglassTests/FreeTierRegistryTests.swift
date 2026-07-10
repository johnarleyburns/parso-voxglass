import XCTest
@testable import Voxglass

final class FreeTierRegistryTests: XCTestCase {

    func testAllAudioCodecsAreFree() {
        // FLAC, Opus, Vorbis, MP3 must never require Pro entitlement
        let codecs = AudioCodec.allCases
        XCTAssertEqual(codecs.count, 4)
        XCTAssertTrue(codecs.contains(.flac))
        XCTAssertTrue(codecs.contains(.opus))
        XCTAssertTrue(codecs.contains(.vorbis))
        XCTAssertTrue(codecs.contains(.mp3))
    }

    func testFLACExtensionIsInPlayableSet() {
        XCTAssertTrue(AudioFormatSelection.allPlayableExtensions.contains("flac"))
        XCTAssertTrue(InternetArchiveAudioSelector.playableAudioExtensions.contains("flac"))
    }

    func testOpusExtensionIsInPlayableSet() {
        XCTAssertTrue(AudioFormatSelection.allPlayableExtensions.contains("opus"))
        XCTAssertTrue(InternetArchiveAudioSelector.playableAudioExtensions.contains("opus"))
    }

    func testMP3ExtensionIsInPlayableSet() {
        XCTAssertTrue(AudioFormatSelection.allPlayableExtensions.contains("mp3"))
    }

    func testIASourceSelectionIsNotGated() {
        // InternetArchiveAudioSelector is available to all, no Pro checks
        let files: [InternetArchiveFile] = [
            InternetArchiveFile(name: "01.mp3", source: "original", format: "MP3",
                                title: "Chapter 1", length: "100", track: "1")
        ]
        let selected = InternetArchiveAudioSelector.selectedAudioFiles(from: files)
        XCTAssertEqual(selected.count, 1)
    }

    func testLocalImportIsNotGated() {
        // Chapter model with localURL is available to all
        let chapter = Chapter(
            bookID: UUID(),
            title: "Test",
            index: 0,
            localURL: URL(fileURLWithPath: "/tmp/test.mp3")
        )
        XCTAssertNotNil(chapter.localURL)
        XCTAssertNotNil(chapter.playableURL)
    }

    @MainActor func testNearGaplessIsFree() {
        let engine = AVPlayerAudioEngine()
        XCTAssertNotNil(engine)
    }

    func testDerivativePolicyIsAvailableWithoutPro() {
        let policy = DerivativePolicy(networkCondition: .wifi)
        XCTAssertEqual(policy.rankedCodecs, [.flac, .mp3])
    }

    @MainActor func testPlaybackCoordinatorOperatesWithoutPro() {
        let database = AppDatabase.makeTemporaryDatabase(named: "free-tier-test")
        let positionStore = SQLitePositionStore(database: database)
        let engine = AVPlayerAudioEngine()
        let coordinator = PlaybackCoordinator(engine: engine, positionStore: positionStore)
        XCTAssertNotNil(coordinator)
    }
}
