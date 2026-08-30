import Foundation

public protocol WatchStableID: RawRepresentable, Codable, Hashable, Sendable, Comparable,
    CustomStringConvertible, ExpressibleByStringLiteral where RawValue == String {
    init(_ rawValue: String)
}

public extension WatchStableID {
    init(rawValue: String) { self.init(rawValue) }
    init(stringLiteral value: String) { self.init(value) }
    var description: String { rawValue }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct WatchBookID: WatchStableID { public let rawValue: String; public init(_ value: String) { rawValue = value } }
public struct WatchChapterID: WatchStableID { public let rawValue: String; public init(_ value: String) { rawValue = value } }
public struct WatchPairedLibraryID: WatchStableID {
    public let rawValue: String
    public init(_ value: String) { rawValue = value }
    public static let unknown = Self("")
    public var isKnown: Bool { !rawValue.isEmpty }
}

public enum WatchProtocolVersion { public static let current = 1 }
public enum WatchTransportChannel: String, Codable, Sendable { case immediate, applicationContext, userInfo, file }
public enum WatchCapability: String, Codable, Sendable, CaseIterable { case libraryProjection, playback, downloadManagement, reconciliation }
public enum WatchDownloadState: Codable, Equatable, Sendable {
    case notRequested, queued, preparing, transferring, installing, downloaded, removing, failed(String)
}

public struct WatchChapterDTO: Codable, Equatable, Sendable {
    public var id: WatchChapterID; public var index: Int; public var title: String; public var duration: Double
    public var approvedStreamURL: URL?
    public init(id: WatchChapterID, index: Int, title: String, duration: Double, approvedStreamURL: URL? = nil) {
        self.id = id; self.index = index; self.title = title; self.duration = duration; self.approvedStreamURL = approvedStreamURL
    }
}
public struct WatchBookDTO: Codable, Equatable, Sendable {
    public var id: WatchBookID; public var title: String; public var author: String?; public var narrator: String?
    public var duration: Double; public var artworkKey: String?; public var metadataRevision: Int64; public var chapters: [WatchChapterDTO]
    public init(id: WatchBookID, title: String, author: String? = nil, narrator: String? = nil, duration: Double = 0,
                artworkKey: String? = nil, metadataRevision: Int64 = 0, chapters: [WatchChapterDTO] = []) {
        self.id=id; self.title=title; self.author=author; self.narrator=narrator; self.duration=duration; self.artworkKey=artworkKey; self.metadataRevision=metadataRevision; self.chapters=chapters
    }
}
public struct WatchLibrarySnapshot: Codable, Equatable, Sendable {
    public var pairedLibraryID: WatchPairedLibraryID; public var revision: Int64; public var books: [WatchBookDTO]
    public init(pairedLibraryID: WatchPairedLibraryID, revision: Int64, books: [WatchBookDTO]) { self.pairedLibraryID=pairedLibraryID; self.revision=revision; self.books=books }
}
public struct WatchManifest: Codable, Equatable, Sendable {
    public var bookID: WatchBookID; public var revision: Int64; public var requiredChapterIDs: [WatchChapterID]
    public init(bookID: WatchBookID, revision: Int64, requiredChapterIDs: [WatchChapterID]) { self.bookID=bookID; self.revision=revision; self.requiredChapterIDs=requiredChapterIDs }
}
public struct WatchManifestAcknowledgement: Codable, Equatable, Sendable {
    public var bookID: WatchBookID; public var revision: Int64; public var complete: Bool; public var installedBytes: Int64
    public init(bookID: WatchBookID, revision: Int64, complete: Bool, installedBytes: Int64) { self.bookID=bookID; self.revision=revision; self.complete=complete; self.installedBytes=installedBytes }
}

public enum WatchMessageKind: String, Codable, Sendable, CaseIterable {
    case hello, helloReply, librarySnapshot, bookDetailRequest, bookDetailResponse, playRequest, jitChapterRequest
    case playbackSnapshot, setBookDownload, removeBookDownload, downloadStatusSnapshot, bookManifest, assetFile
    case watchManifest, reconcileRequest, error
    public var channel: WatchTransportChannel {
        switch self {
        case .hello, .helloReply, .bookDetailRequest, .bookDetailResponse, .playRequest, .jitChapterRequest, .error: .immediate
        case .librarySnapshot, .playbackSnapshot, .downloadStatusSnapshot: .applicationContext
        case .setBookDownload, .removeBookDownload, .bookManifest, .watchManifest, .reconcileRequest: .userInfo
        case .assetFile: .file
        }
    }
}

public struct WatchHello: Codable, Equatable, Sendable {
    public var protocolVersion: Int; public var pairedLibraryID: WatchPairedLibraryID; public var capabilities: [WatchCapability]; public var lastAppliedRevision: Int64
    public init(protocolVersion: Int = WatchProtocolVersion.current, pairedLibraryID: WatchPairedLibraryID = .unknown, capabilities: [WatchCapability] = WatchCapability.allCases, lastAppliedRevision: Int64 = 0) { self.protocolVersion=protocolVersion; self.pairedLibraryID=pairedLibraryID; self.capabilities=capabilities; self.lastAppliedRevision=lastAppliedRevision }
}
public struct WatchHelloReply: Codable, Equatable, Sendable {
    public var protocolVersion: Int; public var pairedLibraryID: WatchPairedLibraryID; public var capabilities: [WatchCapability]; public var revision: Int64
    public init(protocolVersion: Int = WatchProtocolVersion.current, pairedLibraryID: WatchPairedLibraryID, capabilities: [WatchCapability] = WatchCapability.allCases, revision: Int64 = 0) { self.protocolVersion=protocolVersion; self.pairedLibraryID=pairedLibraryID; self.capabilities=capabilities; self.revision=revision }
}

public struct WatchProtocolEnvelope: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = WatchProtocolVersion.current
    public static let payloadKey = "watchProtocolEnvelope"
    public var version: Int; public var messageID: UUID; public var correlationID: UUID?; public var pairedLibraryID: WatchPairedLibraryID
    public var projectionRevision: Int64; public var sentAt: Date; public var kind: WatchMessageKind; public var payload: Data
    public init(version: Int = Self.currentProtocolVersion, messageID: UUID = UUID(), correlationID: UUID? = nil, pairedLibraryID: WatchPairedLibraryID, projectionRevision: Int64 = 0, sentAt: Date = Date(), kind: WatchMessageKind, payload: Data) { self.version=version; self.messageID=messageID; self.correlationID=correlationID; self.pairedLibraryID=pairedLibraryID; self.projectionRevision=projectionRevision; self.sentAt=sentAt; self.kind=kind; self.payload=payload }
    public func encoded() throws -> Data { let e=PropertyListEncoder(); e.outputFormat = .binary; return try e.encode(self) }
    public static func encode<T: Encodable>(kind: WatchMessageKind, payload: T, libraryID: WatchPairedLibraryID, revision: Int64 = 0, correlationID: UUID? = nil) throws -> Data { let e=PropertyListEncoder(); e.outputFormat = .binary; return try Self(correlationID: correlationID, pairedLibraryID: libraryID, projectionRevision: revision, kind: kind, payload: e.encode(payload)).encoded() }
    public static func decode(_ data: Data) throws -> Self { try PropertyListDecoder().decode(Self.self, from: data) }
    public func decodePayload<T: Decodable>(_ type: T.Type) throws -> T { try PropertyListDecoder().decode(type, from: payload) }
    public static func dictionary(for data: Data) -> [String: Any] { [payloadKey: data] }
    public static func payloadData(in dictionary: [String: Any]) -> Data? { dictionary[payloadKey] as? Data }
}

public enum WatchProtocolFaultCode: String, Codable, Sendable { case malformed, unsupportedVersion, wrongPair, staleRevision, timeout, unreachable, failed }
public struct WatchProtocolFault: Error, Codable, Equatable, Sendable { public var code: WatchProtocolFaultCode; public init(_ code: WatchProtocolFaultCode) { self.code=code } }

public protocol WatchDuplexTransport: Sendable {
    var isReachable: Bool { get async }
    func send(_ data: Data, over channel: WatchTransportChannel) async throws
    func receive() async -> Data
}
