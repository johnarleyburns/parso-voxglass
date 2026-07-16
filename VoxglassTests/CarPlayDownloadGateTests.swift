import XCTest
@testable import VoxglassCore

final class CarPlayDownloadGateTests: XCTestCase {

    func testNotDownloadedProYieldsDownloadAction() {
        let book = CarPlayBookSnapshot(id: UUID(), title: "B", authorLine: "A", chapterCount: 1, download: .notDownloaded)
        XCTAssertEqual(CarPlayMenuBuilder.downloadAction(for: book, isDownloadsPro: true), .download(bookID: book.id))
    }

    func testNotDownloadedFreeYieldsProUpsell() {
        let book = CarPlayBookSnapshot(id: UUID(), title: "B", authorLine: "A", chapterCount: 1, download: .notDownloaded)
        XCTAssertEqual(CarPlayMenuBuilder.downloadAction(for: book, isDownloadsPro: false), .showProUpsell(.offlineDownloads))
    }

    func testDownloadedYieldsRemoveAction() {
        let book = CarPlayBookSnapshot(id: UUID(), title: "B", authorLine: "A", chapterCount: 1, download: .downloaded)
        XCTAssertEqual(CarPlayMenuBuilder.downloadAction(for: book, isDownloadsPro: true), .removeDownload(bookID: book.id))
    }

    func testDownloadingYieldsNoneAndProgressAccessory() {
        let book = CarPlayBookSnapshot(id: UUID(), title: "B", authorLine: "A", chapterCount: 1, download: .downloading(0.5))
        XCTAssertEqual(CarPlayMenuBuilder.downloadAction(for: book, isDownloadsPro: true), .none)
    }
}
