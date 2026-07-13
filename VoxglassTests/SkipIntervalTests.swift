import XCTest
@testable import Voxglass

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
}
