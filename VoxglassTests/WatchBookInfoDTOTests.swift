import Foundation
import Testing
import VoxglassWatchProtocol

@Suite struct WatchBookInfoDTOTests {
    @Test func aboutBookDetailsRoundTrip() throws {
        let added = Date(timeIntervalSince1970: 1_700_000_000)
        let book = WatchBookDTO(id: WatchBookID("b"), title: "T", summary: "A summary", addedAt: added)
        let decoded = try JSONDecoder().decode(WatchBookDTO.self, from: JSONEncoder().encode(book))
        #expect(decoded.summary == "A summary")
        #expect(decoded.addedAt == added)
    }

    @Test func olderPayloadsWithoutAboutDetailsStillDecode() throws {
        let book = WatchBookDTO(id: WatchBookID("b"), title: "T")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(book)) as? [String: Any])
        object.removeValue(forKey: "summary"); object.removeValue(forKey: "addedAt")
        let decoded = try JSONDecoder().decode(WatchBookDTO.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.summary == nil && decoded.addedAt == nil)
    }
}
