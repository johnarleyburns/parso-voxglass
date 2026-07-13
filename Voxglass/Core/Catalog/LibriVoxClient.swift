import Foundation

protocol LibriVoxCatalogClient: Sendable {
    func fetchSections(bookID: Int) async throws -> [LibriVoxSection]
}

struct LibriVoxSection: Decodable, Equatable, Sendable {
    var sectionNumber: String?
    var listenURL: String?
    var fileName: String?
    var readers: [LibriVoxReader]
    var urlIArchive: String?

    enum CodingKeys: String, CodingKey {
        case sectionNumber = "section_number"
        case listenURL = "listen_url"
        case fileName = "file_name"
        case readers
        case urlIArchive = "url_iarchive"
    }
}

struct LibriVoxReader: Decodable, Equatable, Sendable {
    var readerID: String?
    var displayName: String?

    enum CodingKeys: String, CodingKey {
        case readerID = "reader_id"
        case displayName = "display_name"
    }

    var displayNameOrUnknown: String {
        guard let name = displayName, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "Unknown reader"
        }
        return name
    }
}

private struct LibriVoxBookResponse: Decodable {
    struct Book: Decodable {
        var sections: [LibriVoxSection]?
    }
    var books: [Book]?
}

final class LibriVoxClient: LibriVoxCatalogClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchSections(bookID: Int) async throws -> [LibriVoxSection] {
        let url = URL(string: "https://librivox.org/api/feed/audiobooks/?id=\(bookID)&extended=1&format=json")!

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw LibriVoxError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        let bookResponse = try JSONDecoder().decode(LibriVoxBookResponse.self, from: data)

        guard let books = bookResponse.books, let firstBook = books.first else {
            throw LibriVoxError.bookNotFound
        }

        return firstBook.sections ?? []
    }
}

enum LibriVoxError: Error {
    case badStatus(Int)
    case bookNotFound
}
