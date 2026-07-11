import XCTest
@testable import Voxglass

final class IADateFormattingTests: XCTestCase {
    func testISO8601Timestamp() {
        XCTAssertEqual(IADateFormatting.humanReadable("2005-08-01T00:00:00Z"), "Aug 2005")
    }

    func testYearMonthDay() {
        XCTAssertEqual(IADateFormatting.humanReadable("2005-08-01"), "Aug 2005")
    }

    func testYearMonth() {
        XCTAssertEqual(IADateFormatting.humanReadable("2005-08"), "Aug 2005")
    }

    func testYearOnly() {
        XCTAssertEqual(IADateFormatting.humanReadable("2005"), "2005")
    }

    func testEmptyAndNil() {
        XCTAssertNil(IADateFormatting.humanReadable(""))
        XCTAssertNil(IADateFormatting.humanReadable("   "))
        XCTAssertNil(IADateFormatting.humanReadable(nil))
    }

    func testGarbageFallsBackToTrimmedRaw() {
        XCTAssertEqual(IADateFormatting.humanReadable("  not a date  "), "not a date")
    }
}
