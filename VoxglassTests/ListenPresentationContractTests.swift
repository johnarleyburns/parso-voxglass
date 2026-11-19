import Foundation
import Testing

/// Source-shape contracts for the Listen-tab player presentation (no simulator).
///
/// Real reports:
/// - Jump Back In / Recommended pushed a book page with a back arrow instead of
///   opening a dismissable sheet.
/// - Now Playing should be titled "Book", not the book's name.
/// - Opening The Two Gentlemen of Verona (≈2 hr) showed "23 hr, 57 min left in
///   book" because the page borrowed another, longer session's total duration.
@Suite struct ListenPresentationContractTests {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func jumpBackInOpensNowPlayingSheetInsteadOfPushing() throws {
        let listen = try source("Voxglass/Features/Listen/ListenView.swift")
        let start = try #require(listen.range(of: "private var jumpBackIn: some View"))
        let end = try #require(listen.range(
            of: "private var listeningStatsSummary",
            range: start.upperBound..<listen.endIndex
        ))
        let block = listen[start.lowerBound..<end.lowerBound]

        #expect(block.contains("playback.selectAndPlay(book)"))
        #expect(block.contains("showingNowPlaying = true"))
        #expect(!block.contains("NavigationLink"))
        #expect(!block.contains("BookPageView"))
    }

    @Test func recommendedPreviewIsASheetNotANavigationPush() throws {
        let listen = try source("Voxglass/Features/Listen/ListenView.swift")
        #expect(listen.contains("previewBook = resolved"))
        #expect(listen.contains(".sheet(item: $previewBook)"))
        #expect(!listen.contains("selectedCatalogBookID"))
        #expect(!listen.contains("navigationDestination(item:"))
    }

    @Test func rootNowPlayingSheetUsesTheSheetContext() throws {
        let root = try source("Voxglass/App/RootView.swift")
        #expect(root.contains("presentationContext: .nowPlayingSheet"))
    }

    @Test func nowPlayingSheetIsTitledBookWithoutABackArrow() throws {
        let page = try source("Voxglass/Features/Player/BookPageView.swift")
        #expect(page.contains("presentationContext == .nowPlayingSheet ? String(localized: \"Book\")"))
        #expect(page.contains(".navigationBarBackButtonHidden(presentationContext == .nowPlayingSheet)"))
    }

    @Test func scrubberNeverBorrowsAnotherBooksTotalDuration() throws {
        let page = try source("Voxglass/Features/Player/BookPageView.swift")
        let marker = try #require(page.range(of: "totalBookDuration:"))
        let end = try #require(page.range(of: "onSeekChapterPosition", range: marker.upperBound..<page.endIndex))
        let argument = page[marker.lowerBound..<end.lowerBound]

        #expect(argument.contains("session?.book.id == resolved.book.id ? session?.totalBookDuration : nil"),
            "an inactive book must use its own total, not the current session's")
        #expect(argument.contains("resolved.totalDuration"))
    }

    @Test func compactHeaderUsesTheDisplayedBooksRemainingTime() throws {
        let page = try source("Voxglass/Features/Player/BookPageView.swift")
        #expect(page.contains("private func bookRemaining(for resolved: BookWithChapters) -> TimeInterval?"))
        #expect(page.contains("TimeFormatting.compactDuration(bookRemaining(for: resolved) ?? 0)"))
        #expect(!page.contains("TimeFormatting.compactDuration(playback.currentSession?.bookRemaining ?? 0)"))
    }
}
