import XCTest
@testable import Voxglass

/// Skip-interval symbol mapping + coordinator call-log assertions (P1-1).
final class SkipIntervalTests: XCTestCase {

    func testEveryAllowedBackSymbolResolves() {
        for seconds in PlaybackCoordinator.allowedSkipBackValues {
            let symbol = PlaybackCoordinator.skipBackSymbol(seconds)
            XCTAssertNotNil(UIImage(systemName: symbol),
                            "\(symbol) must be a valid SF Symbol")
        }
    }

    func testEveryAllowedForwardSymbolResolves() {
        for seconds in PlaybackCoordinator.allowedSkipForwardValues {
            let symbol = PlaybackCoordinator.skipForwardSymbol(seconds)
            XCTAssertNotNil(UIImage(systemName: symbol),
                            "\(symbol) must be a valid SF Symbol")
        }
    }

    func testUnknownValueFallsBack() {
        XCTAssertEqual(PlaybackCoordinator.skipBackSymbol(999), "gobackward.15")
        XCTAssertEqual(PlaybackCoordinator.skipForwardSymbol(999), "goforward.30")
    }

    @MainActor func testSkipForwardUsesConfiguredInterval() async {
        let suite = UserDefaults(suiteName: "skip-test-\(UUID().uuidString)")!
        suite.set(45, forKey: AppPreferencesStore.Keys.skipForwardInterval)
        let db = AppDatabase.makeTemporaryDatabase(named: "skip-coord-\(UUID().uuidString)")
        let engine = FakeAudioEngine()
        engine.duration = 300
        engine.currentTime = 10
        let coordinator = PlaybackCoordinator(engine: engine, positionStore: SQLitePositionStore(database: db))

        // Simulate a remote-command skip-forward invocation (the closure reads UserDefaults at call time).
        await coordinator.skip(by: TimeInterval(suite.integer(forKey: AppPreferencesStore.Keys.skipForwardInterval)))
        XCTAssertTrue(engine.calls.contains(.seek(55)),
                      "Forward by 45 from position 10 → seek to 55")
    }
}
