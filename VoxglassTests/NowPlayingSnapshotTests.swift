import Foundation
import Testing
@testable import VoxglassCore

@Suite struct NowPlayingSnapshotTests {
    @Test func codableRoundTripClampsPlaybackValues() throws {
        let snapshot = NowPlayingSnapshot(bookID: UUID(), title: "The Odyssey", author: "Homer", chapterEyebrow: "Part 1 · 1 of 3", chapterTitle: "A Shore", fraction: 2, minutesLeftInChapter: -4, paletteIndex: 2)
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(NowPlayingSnapshot.self, from: data)
        #expect(decoded == NowPlayingSnapshot(bookID: snapshot.bookID, title: snapshot.title, author: snapshot.author, chapterEyebrow: snapshot.chapterEyebrow, chapterTitle: snapshot.chapterTitle, fraction: 1, minutesLeftInChapter: 0, paletteIndex: 2))
        #expect(data.count < 64 * 1024)
    }
}
