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
    public var isAttested: Bool { attestedAt != nil }

    public init(
        basis: RightsBasis = .personalUseOnly,
        sourceURL: URL? = nil,
        editionYear: Int? = nil,
        evidenceNotes: String = "",
        attestedAt: Date? = nil,
        attestedBy: String? = nil,
        licenseURL: URL? = nil
    ) {
        self.basis = basis
        self.sourceURL = sourceURL
        self.editionYear = editionYear
        self.evidenceNotes = evidenceNotes
        self.attestedAt = attestedAt
        self.attestedBy = attestedBy
        self.licenseURL = licenseURL
    }
}
