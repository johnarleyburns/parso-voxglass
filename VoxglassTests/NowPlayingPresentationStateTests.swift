import Foundation
import Testing
@testable import VoxglassCore

@Suite struct NowPlayingPresentationStateTests {
    let a = UUID(), b = UUID()

    @Test func waitsForMatchingSessionThenPresentsOnce() {
        var s = NowPlayingPresentationState()
        s.requestPresentation(for: a)
        do { let r = s.consumeReadySession(bookID: nil); #expect(!r) }
        do { let r = s.consumeReadySession(bookID: b); #expect(!r) }
        #expect(!s.isNowPlayingPresented)
        do { let r = s.consumeReadySession(bookID: a); #expect(r) }
        #expect(s.isNowPlayingPresented)
        do { let r = s.consumeReadySession(bookID: a); #expect(!r) }
    }

    @Test func supersededRequestCannotPresentOldBook() {
        var s = NowPlayingPresentationState()
        s.requestPresentation(for: a)
        s.requestPresentation(for: b)
        do { let r = s.consumeReadySession(bookID: a); #expect(!r) }
        do { let r = s.consumeReadySession(bookID: b); #expect(r) }
    }

    @Test func cancelAndDismissClearPending() {
        var s = NowPlayingPresentationState()
        s.requestPresentation(for: a)
        s.cancelPending()
        do { let r = s.consumeReadySession(bookID: a); #expect(!r) }
        s.requestPresentation(for: a)
        s.setPresented(false)
        do { let r = s.consumeReadySession(bookID: a); #expect(!r) }
    }

    @Test func alreadyPresentedSheetStaysSingle() {
        var s = NowPlayingPresentationState()
        s.setPresented(true)
        s.requestPresentation(for: a)
        #expect(s.pendingBookID == nil)
        do { let r = s.consumeReadySession(bookID: a); #expect(!r) }
        #expect(s.isNowPlayingPresented)
    }

    @Test func heroStaysMountedUntilSheetPresented() {
        var h = ListenHeroHandoffState()
        #expect(h.allowsLiveHeroReplacement)
        h.didTapResume()
        #expect(!h.allowsLiveHeroReplacement)
        h.didPresentNowPlayingSheet()
        #expect(h.allowsLiveHeroReplacement)
    }
}
