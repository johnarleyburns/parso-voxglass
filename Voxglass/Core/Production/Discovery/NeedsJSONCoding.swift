import Foundation

/// Shared JSON plumbing for discovery payloads: ISO-8601 dates (readable seed
/// files, deterministic cache) and sorted keys (stable output for the last-good
/// cache and checksum comparisons).
public enum NeedsJSONCoding {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func isoDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

/// Diagnostics-only error surface (NARRATION_NEEDS_SPEC §4.3, §14.3). These are
/// written to the diagnostics log, never surfaced in the UI — failures degrade
/// to the next ladder rung and the surface stays full and calm.
public enum DiscoveryError: Error, Sendable, Equatable {
    case resourceMissing(String)
    case sourceTimeout(NeedSourceID)
    case sourceParse(NeedSourceID, String)
    case sourceAuthWall(NeedSourceID)
    case pdUnverified(NeedSourceID, String)
    case cacheMiss
    case breakerOpen(NeedSourceID)
    case emptySeed
}
