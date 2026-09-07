import Foundation

public enum RightsBasis: String, Codable, Sendable, CaseIterable {
    case publicDomainUS      = "Public domain in the United States"
    case ownCopyright        = "I own the copyright"
    case productionLicense   = "I have a production license"
    case personalUseOnly     = "Personal use only"
}

public struct RightsEvidence: Codable, Sendable, Equatable {
    public var basis: RightsBasis
    public var sourceURL: URL?
    public var editionYear: Int?
    public var evidenceNotes: String
    public var attestedAt: Date?
    public var attestedBy: String?
    public var licenseURL: URL?
    /// True when the work's catalog source explicitly has no citable
    /// per-work URL (e.g. an individual poem from PoetryDB, which indexes
    /// poem text but not a citable published edition page) — so the record
    /// flow should not ask the user to supply one. `nil` (the case for any
    /// project persisted before this field existed, or one never linked to
    /// a catalog need) means "unknown," which preserves the original
    /// "ask when there's no URL" behavior.
    public var sourceURLKnownUnavailable: Bool?
    public var isAttested: Bool { attestedAt != nil }

    public init(
        basis: RightsBasis = .personalUseOnly,
        sourceURL: URL? = nil,
        editionYear: Int? = nil,
        evidenceNotes: String = "",
        attestedAt: Date? = nil,
        attestedBy: String? = nil,
        licenseURL: URL? = nil,
        sourceURLKnownUnavailable: Bool? = nil
    ) {
        self.basis = basis
        self.sourceURL = sourceURL
        self.editionYear = editionYear
        self.evidenceNotes = evidenceNotes
        self.attestedAt = attestedAt
        self.attestedBy = attestedBy
        self.licenseURL = licenseURL
        self.sourceURLKnownUnavailable = sourceURLKnownUnavailable
    }
}
