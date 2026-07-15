import XCTest
@testable import VoxglassCore

final class SkipIntervalTests: XCTestCase {

    func testEveryAllowedBackSymbolResolves() {
        for seconds in PlaybackCoordinator.allowedSkipBackValues {
            let symbol = SkipSymbol.back(seconds)
            XCTAssertNotNil(UIImage(systemName: symbol),
                            "\(symbol) must be a valid SF Symbol")
        }
    }

    func testEveryAllowedForwardSymbolResolves() {
        for seconds in PlaybackCoordinator.allowedSkipForwardValues {
            let symbol = SkipSymbol.forward(seconds)
            XCTAssertNotNil(UIImage(systemName: symbol),
                            "\(symbol) must be a valid SF Symbol")
        }
    }

    func testUnknownValueFallsBack() {
        XCTAssertEqual(SkipSymbol.back(999), "gobackward.15")
        XCTAssertEqual(SkipSymbol.forward(999), "goforward.30")
    }
}
