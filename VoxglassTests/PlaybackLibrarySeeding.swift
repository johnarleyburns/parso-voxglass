import Foundation
@testable import VoxglassCore

extension AppDatabase {
    /// Position writes reject (book, chapter) pairs that are not in the library,
    /// so playback tests must seed the rows their fake books refer to.
    func seedLibrary(for book: BookWithChapters) async {
        try? await execute(
            "INSERT INTO sources (id, kind, title, created_at) VALUES (?, ?, ?, ?)",
            [.string(book.book.sourceID.uuidString), .string(SourceKind.localFiles.rawValue), .string("Local"), .double(0)]
        )
        try? await execute(
            "INSERT INTO books (id, title, authors_json, source_id, created_at, updated_at, is_favorite) VALUES (?, ?, ?, ?, ?, ?, ?)",
            [.string(book.book.id.uuidString), .string(book.book.title), .string("[]"), .string(book.book.sourceID.uuidString), .double(0), .double(0), .bool(false)]
        )
        for chapter in book.chapters {
            try? await execute(
                "INSERT INTO chapters (id, book_id, title, sort_key, chapter_index, duration_seconds) VALUES (?, ?, ?, ?, ?, ?)",
                [.string(chapter.id.uuidString), .string(book.book.id.uuidString), .string(chapter.title), .string(chapter.sortKey), .int(Int64(chapter.index)), .double(100)]
            )
        }
    }
}
