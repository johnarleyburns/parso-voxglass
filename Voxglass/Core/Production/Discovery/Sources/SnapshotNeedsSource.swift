import Foundation

/// L1 — J's pipeline output (NARRATION_NEEDS_SPEC §3.0, §3.x): current open
/// LibriVox projects, the weekly pin, and great-books gaps, all PD-verified.
/// A full `[NarrationNeed]` JSON payload. On any failure it contributes
/// nothing (last-good cache covers freshness).
public struct SnapshotNeedsSource: NeedsSource {
    public var id: NeedSourceID { .snapshot }

    public let endpoint: URL

    public init(endpoint: URL? = nil) {
        self.endpoint = endpoint ?? URL(string: "https://parso.guru/voxglass/needs.json")!
    }

    public func fetch(using fetcher: any HTTPFetching, clock: any Clock) async throws -> [NarrationNeed] {
        let descriptor = NeedsSourceDescriptors.descriptor(for: id)
        let result = try await fetcher.get(
            endpoint,
            timeout: descriptor.defaultTimeout,
            userAgent: NeedsSourceDescriptors.userAgent(for: id)
        )
        guard result.statusCode == 200 else {
            throw HTTPFetchError.httpStatus(result.statusCode)
        }
        guard !result.looksLikeAuthWall else {
            throw HTTPFetchError.authWall
        }
        return try NeedsJSONCoding.decoder.decode([NarrationNeed].self, from: result.data)
    }
}
