import Foundation

public protocol LibriVoxCatalogClient: Sendable {
    func fetchSections(bookID: Int) async throws -> [LibriVoxSection]
}

public struct LibriVoxSection: Decodable, Equatable, Sendable {
    public var sectionNumber: String?
    public var listenURL: String?
    public var fileName: String?
    public var readers: [LibriVoxReader]
    public var urlIArchive: String?

    public enum CodingKeys: String, CodingKey {
        case sectionNumber = "section_number"
        case listenURL = "listen_url"
        case fileName = "file_name"
        case readers
        case urlIArchive = "url_iarchive"
    }
}

public struct LibriVoxReader: Decodable, Equatable, Sendable {
    public var readerID: String?
    public var displayName: String?

    public enum CodingKeys: String, CodingKey {
        case readerID = "reader_id"
        case displayName = "display_name"
    }

    public var displayNameOrUnknown: String {
        guard let name = displayName, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "Unknown reader"
        }
        return name
    }
}

private struct LibriVoxBookResponse: Decodable {
    public struct Book: Decodable {
        var sections: [LibriVoxSection]?
    }
    public var books: [Book]?
}

public final class LibriVoxClient: LibriVoxCatalogClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchSections(bookID: Int) async throws -> [LibriVoxSection] {
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

public enum LibriVoxError: Error {
    case badStatus(Int)
    case bookNotFound
}
