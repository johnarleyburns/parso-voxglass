import Foundation
import Testing
@testable import VoxglassCore

struct BookProgressResolverTests {
    let bookID = UUID()
    let chapters: [Chapter]

    init() {
        let id = bookID
        chapters = (0..<4).map { Chapter(bookID: id, title: "Ch \($0)", index: $0, duration: 300) }
    }

    func point(chapter: Int, position: TimeInterval, updatedAt: TimeInterval = 0, finished: Bool = false) -> PlaybackPosition {
        PlaybackPosition(bookID: bookID, chapterID: chapters[chapter].id, position: position,
                         updatedAt: Date(timeIntervalSince1970: updatedAt), isFinished: finished)
    }

    @Test func laterChapterWinsDespiteOlderTimestamp() {
        let phone = point(chapter: 3, position: 10, updatedAt: 100)
        let watch = point(chapter: 1, position: 250, updatedAt: 999)
        #expect(BookProgressResolver.compare(watch, to: phone, in: chapters) == .behind)
        #expect(BookProgressResolver.compare(phone, to: watch, in: chapters) == .ahead)
    }

    @Test func fartherOffsetWinsInSameChapterDespiteOlderTimestamp() {
        let phone = point(chapter: 2, position: 80, updatedAt: 100)
        let watch = point(chapter: 2, position: 42, updatedAt: 999)
        #expect(BookProgressResolver.compare(watch, to: phone, in: chapters) == .behind)
    }

    @Test func equalAndToleranceBoundary() {
        let base = point(chapter: 1, position: 50)
        #expect(BookProgressResolver.compare(point(chapter: 1, position: 50), to: base, in: chapters) == .equalOrWithinTolerance)
        #expect(BookProgressResolver.compare(point(chapter: 1, position: 52), to: base, in: chapters) == .equalOrWithinTolerance)
        #expect(BookProgressResolver.compare(point(chapter: 1, position: 48), to: base, in: chapters) == .equalOrWithinTolerance)
        #expect(BookProgressResolver.compare(point(chapter: 1, position: 52.5), to: base, in: chapters) == .ahead)
        #expect(BookProgressResolver.compare(point(chapter: 1, position: 47.5), to: base, in: chapters) == .behind)
    }

    @Test func unknownChapterIsIndeterminate() {
        let base = point(chapter: 1, position: 50)
        let unknown = PlaybackPosition(bookID: bookID, chapterID: UUID(), position: 10)
        #expect(BookProgressResolver.compare(unknown, to: base, in: chapters) == .indeterminate)
        #expect(BookProgressResolver.compare(base, to: unknown, in: chapters) == .indeterminate)
    }

    @Test func nonFiniteAndNegativeAreRejected() {
        var bad = point(chapter: 3, position: 10)
        bad.position = .nan
        var negative = point(chapter: 3, position: 10)
        negative.position = -5
        let good = point(chapter: 0, position: 5)
        #expect(BookProgressResolver.compare(bad, to: good, in: chapters) == .indeterminate)
        #expect(BookProgressResolver.furthest([bad, negative, good], in: chapters)?.chapterID == good.chapterID)
        #expect(BookProgressResolver.furthest([bad], in: chapters) == nil)
    }

    @Test func furthestChoosesLaterChapterAcrossPersistedRows() {
        let result = BookProgressResolver.furthest([
            point(chapter: 0, position: 0, updatedAt: 999),
            point(chapter: 3, position: 42, updatedAt: 100)
        ], in: chapters)
        #expect(result?.chapterID == chapters[3].id)
        #expect(result?.position == 42)
    }

    @Test func timestampOnlyBreaksExactTies() {
        let older = point(chapter: 1, position: 30, updatedAt: 1)
        let newer = point(chapter: 1, position: 30, updatedAt: 2)
        #expect(BookProgressResolver.furthest([newer, older], in: chapters)?.updatedAt == newer.updatedAt)
    }

    @Test func finishedNonFinalChapterIsBehindNextChapterAtZero() {
        let finished = point(chapter: 1, position: 300, finished: true)
        let next = point(chapter: 2, position: 0)
        #expect(BookProgressResolver.compare(next, to: finished, in: chapters) == .ahead)
        #expect(BookProgressResolver.furthest([finished, next], in: chapters)?.chapterID == chapters[2].id)
    }

    @Test func restartAtZeroOfFinalChapterIsNotAhead() {
        let finishedFinal = point(chapter: 3, position: 300, finished: true)
        let restart = point(chapter: 0, position: 0, updatedAt: 999)
        #expect(BookProgressResolver.compare(restart, to: finishedFinal, in: chapters) == .behind)
    }
}
