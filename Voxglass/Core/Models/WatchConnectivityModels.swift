import Foundation

public enum WatchPhoneAction {
    public static let requestLibrary = "watch.requestLibrary"
    public static let requestPlaybackState = "watch.requestPlaybackState"
    public static let searchLibriVox = "watch.searchLibriVox"
    public static let playBook = "watch.playBook"
    public static let playRemote = "watch.playRemote"
    public static let playbackCommand = "watch.playbackCommand"
    public static let reportWatchStorage = "watch.reportWatchStorage"
}

public struct WatchPhoneEmptyPayload: Codable, Equatable, Sendable {
    public init() {}
}

public struct WatchPhoneLibrarySnapshot: Codable, Equatable, Sendable {
    public var books: [BookWithChapters]
    public var playbackState: WatchPhonePlaybackState?
    public var generatedAt: Date

    public init(
        books: [BookWithChapters],
        playbackState: WatchPhonePlaybackState? = nil,
        generatedAt: Date = Date()
    ) {
        self.books = books
        self.playbackState = playbackState
        self.generatedAt = generatedAt
    }
}

public struct WatchPhoneSearchRequest: Codable, Equatable, Sendable {
    public var query: String
    public var limit: Int

    public init(query: String, limit: Int = 15) {
        self.query = query
        self.limit = limit
    }
}

public struct WatchPhoneSearchResponse: Codable, Equatable, Sendable {
    public var results: [InternetArchiveSearchResult]

    public init(results: [InternetArchiveSearchResult]) {
        self.results = results
    }
}

public struct WatchPhonePlayBookRequest: Codable, Equatable, Sendable {
    public var bookID: UUID
    public var chapterID: UUID?

    public init(bookID: UUID, chapterID: UUID? = nil) {
        self.bookID = bookID
        self.chapterID = chapterID
    }
}

public struct WatchPhonePlayRemoteRequest: Codable, Equatable, Sendable {
    public var identifier: String

    public init(identifier: String) {
        self.identifier = identifier
    }
}

public enum WatchPhonePlaybackCommand: String, Codable, Equatable, Sendable {
    case togglePlayPause
    case pause
    case skipBackward
    case skipForward
    case previousChapter
    case nextChapter
}

public struct WatchPhonePlaybackCommandRequest: Codable, Equatable, Sendable {
    public var command: WatchPhonePlaybackCommand
    public var seconds: TimeInterval?

    public init(command: WatchPhonePlaybackCommand, seconds: TimeInterval? = nil) {
        self.command = command
        self.seconds = seconds
    }
}

public struct WatchPhonePlaybackState: Codable, Equatable, Sendable {
    public var accepted: Bool
    public var session: PlaybackSession?
    public var errorMessage: String?
    public var generatedAt: Date

    public init(
        accepted: Bool,
        session: PlaybackSession? = nil,
        errorMessage: String? = nil,
        generatedAt: Date = Date()
    ) {
        self.accepted = accepted
        self.session = session
        self.errorMessage = errorMessage
        self.generatedAt = generatedAt
    }
}

public enum WatchPhoneMessageCodec {
    public static let actionKey = "action"
    public static let payloadKey = "payload"
    public static let errorKey = "error"

    public static func message<Payload: Encodable>(
        action: String,
        payload: Payload
    ) throws -> [String: Any] {
        [
            actionKey: action,
            payloadKey: try JSONEncoder().encode(payload)
        ]
    }

    public static func message(action: String) -> [String: Any] {
        [actionKey: action]
    }

    public static func action(from message: [String: Any]) -> String? {
        message[actionKey] as? String
    }

    public static func payload<Payload: Decodable>(
        _ type: Payload.Type,
        from message: [String: Any]
    ) throws -> Payload {
        guard let data = message[payloadKey] as? Data else {
            throw WatchPhoneMessageError.missingPayload
        }
        return try JSONDecoder().decode(type, from: data)
    }

    public static func reply<Payload: Encodable>(_ payload: Payload) throws -> [String: Any] {
        [payloadKey: try JSONEncoder().encode(payload)]
    }

    public static func errorReply(_ message: String) -> [String: Any] {
        [errorKey: message]
    }

    public static func replyPayload<Payload: Decodable>(
        _ type: Payload.Type,
        from reply: [String: Any]
    ) throws -> Payload {
        if let error = reply[errorKey] as? String {
            throw WatchPhoneMessageError.remoteError(error)
        }
        return try payload(type, from: reply)
    }
}

public enum WatchPhoneMessageError: Error, LocalizedError, Equatable {
    case missingPayload
    case missingAction
    case remoteError(String)

    public var errorDescription: String? {
        switch self {
        case .missingPayload:
            "The iPhone reply did not include a payload."
        case .missingAction:
            "The watch request did not include an action."
        case .remoteError(let message):
            message
        }
    }
}

public enum WatchPhoneSmokeFixtures {
    public static let aliceIdentifier = "alice_in_wonderland_librivox"
    public static let aliceTitle = "Alice's Adventures in Wonderland"

    public static func aliceInWonderland() -> BookWithChapters {
        let sourceID = UUID(uuidString: "A11CE000-0000-4000-8000-000000000001")!
        let bookID = UUID(uuidString: "A11CE000-0000-4000-8000-000000000002")!
        let book = Book(
            id: bookID,
            title: aliceTitle,
            authors: ["Lewis Carroll"],
            narrators: ["LibriVox Volunteers"],
            summary: "A public-domain LibriVox recording used by the watch smoke path.",
            sourceID: sourceID,
            coverURL: URL(string: "https://archive.org/services/img/\(aliceIdentifier)?scale=2"),
            createdAt: Date(timeIntervalSince1970: 1_136_937_600),
            updatedAt: Date(timeIntervalSince1970: 1_136_937_600)
        )
        let chapters = (1...3).map { index in
            Chapter(
                id: UUID(uuidString: String(format: "A11CE000-0000-4000-8000-0000000001%02d", index))!,
                bookID: bookID,
                title: "Chapter \(index)",
                sortKey: String(format: "%02d", index),
                index: index - 1,
                duration: 640,
                remoteURL: URL(string: String(format: "https://archive.org/download/%@/wonderland_ch_%02d_64kb.mp3", aliceIdentifier, index))
            )
        }
        return BookWithChapters(book: book, chapters: chapters)
    }
}
