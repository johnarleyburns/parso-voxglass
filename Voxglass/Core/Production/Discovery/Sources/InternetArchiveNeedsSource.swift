import Foundation

/// L2 — Internet Archive (NARRATION_NEEDS_SPEC §3.3): texts + gap signal.
/// `GET archive.org/advancedsearch.php?q=collection:(gutenbergbooks)+AND+mediatype:(texts)&fl[]=…&output=json&rows=…`.
/// Grade from edition `year <= currentYear − 96` → `.iaVerifiedEdition`. Also
/// queries `collection:(librivoxaudio)` to raise `NeedSignal.catalogGap` for
/// texts absent from it (approximate, per-title; the authoritative gap list
/// comes from L1/the great-books audit).
public struct InternetArchiveNeedsSource: NeedsSource {
    public var id: NeedSourceID { .internetArchive }

    public let textsEndpoint: URL
    public let audioEndpoint: URL
    public let currentYear: Int

    public init(currentYear: Int = Calendar.current.component(.year, from: Date())) { // determinism-exempt: live runtime default
        self.currentYear = currentYear
        textsEndpoint = InternetArchiveNeedsSource.searchURL(collection: "gutenbergbooks", rows: 100)
        audioEndpoint = InternetArchiveNeedsSource.searchURL(collection: "librivoxaudio", rows: 200)
    }

    public func fetch(using fetcher: any HTTPFetching, clock: any Clock) async throws -> [NarrationNeed] {
        let descriptor = NeedsSourceDescriptors.descriptor(for: id)
        let texts = try await fetcher.get(textsEndpoint, timeout: descriptor.defaultTimeout, userAgent: NeedsSourceDescriptors.userAgent(for: id))
        guard texts.statusCode == 200 else { throw HTTPFetchError.httpStatus(texts.statusCode) }
        let docs = try decodeTexts(texts.data)
        let audio = (try? await fetcher.get(audioEndpoint, timeout: descriptor.defaultTimeout, userAgent: NeedsSourceDescriptors.userAgent(for: id)))
            .flatMap { $0.statusCode == 200 ? (try? decodeRecorded($0.data)) : nil }
        let recordedTitles = Set((audio ?? []).map { NeedID.normalize($0) })

        let now = clock.now
        return docs.map { doc in
            doc.toNeed(now: now, currentYear: currentYear, recordedSet: recordedTitles)
        }
    }

    public func decodeTexts(_ data: Data) throws -> [IADoc] {
        let response = try NeedsJSONCoding.decoder.decode(IASearchResponse.self, from: data)
        return response.response.docs
    }

    public func decodeRecorded(_ data: Data) throws -> [String] {
        let response = try NeedsJSONCoding.decoder.decode(IASearchResponse.self, from: data)
        return response.response.docs.map(\.title)
    }

    private static func searchURL(collection: String, rows: Int) -> URL {
        var components = URLComponents(string: "https://archive.org/advancedsearch.php")
        components?.queryItems = [
            URLQueryItem(name: "q", value: "collection:(\(collection)) AND mediatype:(texts)"),
            URLQueryItem(name: "fl[]", value: "identifier"),
            URLQueryItem(name: "fl[]", value: "title"),
            URLQueryItem(name: "fl[]", value: "creator"),
            URLQueryItem(name: "fl[]", value: "year"),
            URLQueryItem(name: "output", value: "json"),
            URLQueryItem(name: "rows", value: "\(rows)")
        ]
        return components?.url ?? URL(string: "https://archive.org/advancedsearch.php")!
    }
}

// MARK: - Decodables

public struct IASearchResponse: Sendable, Codable {
    public var response: IADocsResponse

    public init(response: IADocsResponse) {
        self.response = response
    }
}

public struct IADocsResponse: Sendable, Codable {
    public var numFound: Int
    public var docs: [IADoc]

    public init(numFound: Int, docs: [IADoc]) {
        self.numFound = numFound
        self.docs = docs
    }
}

public struct IADoc: Sendable, Codable {
    public var identifier: String
    public var title: String
    public var creator: String?
    public var year: Int?

    public init(identifier: String, title: String, creator: String? = nil, year: Int? = nil) {
        self.identifier = identifier
        self.title = title
        self.creator = creator
        self.year = year
    }

    public func toNeed(now: Date, currentYear: Int, recordedSet: Set<String>) -> NarrationNeed {
        let author = creator ?? "Unknown"
        let isRecorded = recordedSet.contains(NeedID.normalize(title))
        let pdBasis: PDBasis = {
            if let year, year <= currentYear - NeedsDiscoveryConstants.rollingCopyrightLine {
                return .iaVerifiedEdition
            }
            return .unverified
        }()
        let estSeconds = 16_200 // prose default; a book-length read
        let work = NarratableWork(
            title: title,
            author: author,
            subject: "book",
            grade: pdBasis == .unverified ? .practice : .submittable,
            estSeconds: estSeconds,
            sourcePageURL: URL(string: "https://archive.org/details/\(identifier)")
        )
        return NarrationNeed(
            work: work,
            signal: isRecorded ? .evergreen : .catalogGap,
            strength: isRecorded ? 30 : 70,
            provenance: NeedProvenance(
                sources: [.internetArchive],
                firstSeen: now,
                lastConfirmed: now,
                pdBasis: pdBasis,
                editionYear: year
            )
        )
    }
}
