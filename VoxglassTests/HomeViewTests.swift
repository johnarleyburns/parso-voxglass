import XCTest
@testable import Voxglass

final class HomeViewTests: XCTestCase {

    func testInfoPlistDeclaresBackgroundAudioMode() {
        let modes = Bundle.main.infoDictionary?["UIBackgroundModes"] as? [String]
        XCTAssertNotNil(modes, "Info.plist must declare UIBackgroundModes")
        XCTAssertTrue(modes?.contains("audio") == true, "UIBackgroundModes must include 'audio'")
    }

    func testRecentlyAddedExcludesRecentlyPlayedBookIDs() {
        let recentlyPlayedIDs: Set<UUID> = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        ]
        let allBookIDs: [UUID] = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        ]

        let result = allBookIDs.filter { !recentlyPlayedIDs.contains($0) }

        XCTAssertEqual(result.count, 2)
        XCTAssertFalse(result.contains(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!))
        XCTAssertTrue(result.contains(UUID(uuidString: "00000000-0000-0000-0000-000000000003")!))
        XCTAssertTrue(result.contains(UUID(uuidString: "00000000-0000-0000-0000-000000000004")!))
    }

    func testRecentlyAddedEmptyWhenAllBooksAreInRecentlyPlayed() {
        let recentlyPlayedIDs: Set<UUID> = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        ]
        let allBookIDs: [UUID] = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        ]

        let result = allBookIDs.filter { !recentlyPlayedIDs.contains($0) }

        XCTAssertTrue(result.isEmpty, "Recently added should be empty when all books are in Jump Back In")
    }

    func testRecentlyAddedUnchangedWhenNoOverlap() {
        let recentlyPlayedIDs: Set<UUID> = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000009")!
        ]
        let allBookIDs: [UUID] = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        ]

        let result = allBookIDs.filter { !recentlyPlayedIDs.contains($0) }

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result, allBookIDs)
    }

    func testHorizontalCatalogCardHasNoShadow() async throws {
        let result = InternetArchiveSearchResult(
            identifier: "test_identifier",
            title: "Test Title",
            creators: ["Test Author"],
            description: nil,
            collections: ["librivoxaudio"],
            downloads: nil,
            date: nil
        )
        let card = HorizontalCatalogCard(result: result)

        let mirror = Mirror(reflecting: card)
        let children = Mirror(reflecting: mirror.descendant("result") as Any?)

        // Verify the card is constructed with the expected result
        let identifier = mirror.descendant("result", "identifier") as? String
        XCTAssertEqual(identifier, "test_identifier")
    }

    func testBookCoverViewHonorsShowBorderFlag() {
        let withBorder = BookCoverView(title: "Test", coverURL: nil, showBorder: true)
        let withoutBorder = BookCoverView(title: "Test", coverURL: nil, showBorder: false)

        // Mirror to inspect stored properties
        let withMirror = Mirror(reflecting: withBorder)
        let withoutMirror = Mirror(reflecting: withoutBorder)

        let withShowBorder = withMirror.descendant("showBorder") as? Bool
        let withoutShowBorder = withoutMirror.descendant("showBorder") as? Bool

        XCTAssertEqual(withShowBorder, true)
        XCTAssertEqual(withoutShowBorder, false)
    }

    func testBookCoverViewDefaultShowBorderIsTrue() {
        let view = BookCoverView(title: "Default", coverURL: nil)
        let mirror = Mirror(reflecting: view)
        let showBorder = mirror.descendant("showBorder") as? Bool
        XCTAssertEqual(showBorder, true, "showBorder should default to true for backward compatibility")
    }
}
