import Foundation

/// One finding from the rule engine (§15.1).
///
/// `id` is **deterministic** — a SHA-256 over `(code, chapterID, paragraphID)`
/// truncated into a UUID — so re-running validation never reshuffles the list
/// and a fixed issue can be diffed away (`ValidationDeterminismTests`).
public struct ValidationIssue: Sendable, Identifiable, Equatable, Codable {
    public let id: UUID
    public var severity: Severity
    public var code: IssueCode
    public var title: String
    public var message: String
    public var chapterID: UUID?
    public var paragraphID: UUID?
    public var takeID: UUID?
    public var measured: Double?
    public var expected: String?
    public var fix: FixAction?

    public init(
        id: UUID,
        severity: Severity,
        code: IssueCode,
        title: String,
        message: String,
        chapterID: UUID? = nil,
        paragraphID: UUID? = nil,
        takeID: UUID? = nil,
        measured: Double? = nil,
        expected: String? = nil,
        fix: FixAction? = nil
    ) {
        self.id = id
        self.severity = severity
        self.code = code
        self.title = title
        self.message = message
        self.chapterID = chapterID
        self.paragraphID = paragraphID
        self.takeID = takeID
        self.measured = measured
        self.expected = expected
        self.fix = fix
    }

    /// Deterministic UUID from `SHA256Hex.hex(joining: [code, chapterID, paragraphID])`
    /// truncated into standard UUID format (§15.1). `-` replaces a missing ID.
    ///
    /// `variant` disambiguates two legitimate issues that share `(code, chapter,
    /// paragraph)` — e.g. the LibriVox *intro* and *outro* disclaimer both emit
    /// `missingDisclaimerParagraph` for the same chapter with no paragraph ID.
    public static func deterministicID(code: IssueCode, chapterID: UUID?, paragraphID: UUID?, variant: String = "") -> UUID {
        let hex = SHA256Hex.hex(joining: [
            code.rawValue,
            chapterID?.uuidString ?? "-",
            paragraphID?.uuidString ?? "-",
            variant
        ])
        let trimmed = String(hex.prefix(32))
        let ns = trimmed.prefix(8)
        let a = trimmed.dropFirst(8).prefix(4)
        let b = trimmed.dropFirst(12).prefix(4)
        let c = trimmed.dropFirst(16).prefix(4)
        let d = trimmed.dropFirst(20).prefix(12)
        let formatted = "\(ns)-\(a)-\(b)-\(c)-\(d)"
        return UUID(uuidString: formatted) ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    }
}
