import Testing
@testable import VoxglassCore

@Suite struct IADateFormattingTests {
    @Test func iSO8601Timestamp() {
        #expect(IADateFormatting.humanReadable("2005-08-01T00:00:00Z") == "Aug 2005")
    }

    @Test func yearMonthDay() {
        #expect(IADateFormatting.humanReadable("2005-08-01") == "Aug 2005")
    }

    @Test func yearMonth() {
        #expect(IADateFormatting.humanReadable("2005-08") == "Aug 2005")
    }

    @Test func yearOnly() {
        #expect(IADateFormatting.humanReadable("2005") == "2005")
    }

    @Test func emptyAndNil() {
        #expect(IADateFormatting.humanReadable("") == nil)
        #expect(IADateFormatting.humanReadable("   ") == nil)
        #expect(IADateFormatting.humanReadable(nil) == nil)
    }

    @Test func garbageFallsBackToTrimmedRaw() {
        #expect(IADateFormatting.humanReadable("  not a date  ") == "not a date")
    }
}
