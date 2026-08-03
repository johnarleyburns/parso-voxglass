import Foundation

/// L2 — PoetryDB (NARRATION_NEEDS_SPEC §3.2): key-less JSON short poems.
/// The corpus is classic long-dead poets, but carries no citable per-poem
/// edition → grade `.practice` unless the pipeline/Gutendex attaches a
/// matching Gutenberg source (then `.submittable`). Line count is capped at
/// `shortPoemLineCeiling`.
public struct PoetryDBNeedsSource: NeedsSource {
    public var id: NeedSourceID { .poetryDB }

    public let linecountEndpoint: URL
    public let authorEndpoint: URL

    public init() {
        linecountEndpoint = URL(string: "https://poetrydb.org/linecount/\(NeedsDiscoveryConstants.shortPoemLineCeiling)")!
        authorEndpoint = URL(string: "https://poetrydb.org/author/")!
    }

    public func fetch(using fetcher: any HTTPFetching, clock: any Clock) async throws -> [NarrationNeed] {
        let descriptor = NeedsSourceDescriptors.descriptor(for: id)
        let result = try await fetcher.get(linecountEndpoint, timeout: descriptor.defaultTimeout, userAgent: NeedsSourceDescriptors.userAgent(for: id))
        guard result.statusCode == 200 else { throw HTTPFetchError.httpStatus(result.statusCode) }
        return try decode(result.data, clock: clock)
    }

    public func decode(_ data: Data, clock: any Clock) throws -> [NarrationNeed] {
        let now = clock.now
        // PoetryDB returns either an array of poems or an error object.
        if let error = try? NeedsJSONCoding.decoder.decode(PoetryDBError.self, from: data) {
            throw DiscoveryError.sourceParse(id, error.reason ?? "unknown")
        }
        let poems = try NeedsJSONCoding.decoder.decode([PoetryDBPoem].self, from: data)
        return poems
            .filter { $0.linecountValue <= NeedsDiscoveryConstants.shortPoemLineCeiling }
            .map { poem in
                poem.toNeed(now: now)
            }
    }
}

// MARK: - Decodables

public struct PoetryDBError: Sendable, Codable {
    public var status: Int?
    public var reason: String?

    public init(status: Int? = nil, reason: String? = nil) {
        self.status = status
        self.reason = reason
    }
}

public struct PoetryDBPoem: Sendable, Codable {
    public var title: String
    public var author: String
    public var lines: [String]
    public var linecount: String

    public init(title: String, author: String, lines: [String], linecount: String) {
        self.title = title
        self.author = author
        self.lines = lines
        self.linecount = linecount
    }

    public var linecountValue: Int {
        Int(linecount) ?? lines.count
    }

    func toNeed(now: Date) -> NarrationNeed {
        let count = linecountValue
        let estSeconds = count * 3
        let work = NarratableWork(
            title: title,
            author: author,
            subject: "poem",
            grade: .practice,
            estSeconds: estSeconds,
            text: lines.joined(separator: "\n")
        )
        return NarrationNeed(
            work: work,
            signal: .evergreen,
            strength: 40,
            provenance: NeedProvenance(
                sources: [.poetryDB],
                firstSeen: now,
                lastConfirmed: now,
                pdBasis: .unverified
            )
        )
    }
}
