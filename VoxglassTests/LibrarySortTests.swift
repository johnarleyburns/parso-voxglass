import Testing
import Foundation
@testable import VoxglassCore

/// Pure in-memory sort comparator + LibraryStore visibleBooks (P1-2).
@Suite struct LibrarySortTests {

    private func makeBook(id: UUID, title: String, authors: [String], duration: TimeInterval?, updatedAt: Date) -> BookWithChapters {
        let book = Book(id: id, title: title, authors: authors, sourceID: UUID(),
                        createdAt: updatedAt, updatedAt: updatedAt)
        let chapter = Chapter(bookID: id, title: "Ch", index: 0, duration: duration)
        return BookWithChapters(book: book, chapters: [chapter])
    }

    @Test func sortByRecentOrdersNewestFirst() {
        let a = makeBook(id: UUID(), title: "A", authors: ["X"], duration: nil, updatedAt: Date(timeIntervalSince1970: 100))
        let b = makeBook(id: UUID(), title: "B", authors: ["X"], duration: nil, updatedAt: Date(timeIntervalSince1970: 200))
        let sorted = [a, b].sorted(by: LibrarySort.recent.comparator())
        #expect(sorted.map(\.book.title) == ["B", "A"])
    }

    @Test func sortByTitleCaseInsensitive() {
        let zebra = makeBook(id: UUID(), title: "Zebra", authors: ["X"], duration: nil, updatedAt: Date())
        let apple = makeBook(id: UUID(), title: "apple", authors: ["X"], duration: nil, updatedAt: Date())
        let sorted = [zebra, apple].sorted(by: LibrarySort.title.comparator())
        #expect(sorted.map(\.book.title) == ["apple", "Zebra"])
    }

    @Test func sortByDurationPushesNilToEnd() {
        let known = makeBook(id: UUID(), title: "K", authors: ["X"], duration: 100, updatedAt: Date())
        let unknown = makeBook(id: UUID(), title: "U", authors: ["X"], duration: nil, updatedAt: Date())
        let sorted = [unknown, known].sorted(by: LibrarySort.duration.comparator())
        #expect(sorted.map(\.book.title) == ["K", "U"])
    }

    @MainActor @Test func filterAndSortOnVisibleBooks() {
        let store = LibraryStore(repository: LibraryRepository(database: AppDatabase.makeTemporaryDatabase(named: "sort-\(UUID().uuidString)")))
        store.filter = .favorites
        store.sort = .title
        // With an empty DB, visibleBooks must stay empty.
        #expect(store.visibleBooks.isEmpty)
    }
}
