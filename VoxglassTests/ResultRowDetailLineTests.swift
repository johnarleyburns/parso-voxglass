import XCTest
@testable import Voxglass

final class ResultRowDetailLineTests: XCTestCase {
    private func makeResult(
        collections: [String] = [],
        downloads: Int? = nil,
        date: String? = nil
    ) -> InternetArchiveSearchResult {
        InternetArchiveSearchResult(
            identifier: "id",
            title: "Title",
            creators: ["Author"],
            description: nil,
            collections: collections,
            downloads: downloads,
            date: date
        )
    }

    func testFormatsDateAndJoinsDownloads() {
        let row = InternetArchiveResultRow(
            result: makeResult(downloads: 12431, date: "2005-08-01T00:00:00Z"),
            isPlaying: false
        )
        XCTAssertEqual(row.detailLine, "Aug 2005 - 12431 downloads")
    }

    func testDownloadsOnlyWhenDateMissing() {
        let row = InternetArchiveResultRow(
            result: makeResult(downloads: 42, date: nil),
            isPlaying: false
        )
        XCTAssertEqual(row.detailLine, "42 downloads")
    }

    func testFallsBackToSourceKindWhenBothAbsent() {
        let row = InternetArchiveResultRow(
            result: makeResult(collections: ["librivoxaudio"]),
            isPlaying: false
        )
        XCTAssertEqual(row.detailLine, SourceKind.librivox.displayName)
    }
}
