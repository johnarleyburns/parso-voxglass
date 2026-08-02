import Foundation
import Observation
import VoxglassCore

/// Backs Metadata & Rights (spec §18.1.12): book details, rights evidence,
/// artwork, identifiers, and the live Narration Origin Audit. The model edits a
/// working copy of the project; nothing is written until `save()`.
@Observable @MainActor
public final class MetadataRightsModel {
    // Book details
    public var title: String
    public var subtitle: String
    public var author: String
    public var narrator: String
    public var translator: String
    public var language: String
    public var description: String
    public var subjectsText: String
    public var publisher: String
    public var copyrightYearText: String
    public var productionYearText: String
    public var rightsHolder: String
    public var isbn: String
    public var asin: String

    // Rights
    public var rightsBasis: RightsBasis
    public var sourceURLText: String
    public var editionYearText: String
    public var evidenceNotes: String
    public var attestedBy: String
    public var attestationDate: Date?

    // Identifiers
    public var archiveIdentifier: String
    public private(set) var suggestedIdentifier: String

    // Derived
    public private(set) var eligibility: EligibilityProfile
    public private(set) var error: String?
    public private(set) var didSave = false

    public var isAttested: Bool { attestationDate != nil }

    private let store: any ProductionStore
    private var working: AudiobookProject

    public init(
        project: AudiobookProject,
        store: any ProductionStore,
        assets: any ContentAddressedStore
    ) {
        self.working = project
        self.store = store
        let m = project.metadata
        let r = project.rights

        title = m.title
        subtitle = m.subtitle ?? ""
        author = m.author
        narrator = m.narrator
        translator = m.translator ?? ""
        language = m.language
        description = m.description
        subjectsText = m.subjects.joined(separator: ", ")
        publisher = m.publisher ?? ""
        copyrightYearText = m.copyrightYear.map(String.init) ?? ""
        productionYearText = m.productionYear.map(String.init) ?? ""
        rightsHolder = m.rightsHolder ?? ""
        isbn = m.isbn ?? ""
        asin = m.asin ?? ""

        rightsBasis = r.basis
        sourceURLText = r.sourceURL?.absoluteString ?? ""
        editionYearText = r.editionYear.map(String.init) ?? ""
        evidenceNotes = r.evidenceNotes
        attestedBy = r.attestedBy ?? ""
        attestationDate = r.attestedAt

        archiveIdentifier = m.archiveIdentifier ?? ""
        suggestedIdentifier = ""
        eligibility = EligibilityProfile.evaluate(project)
        suggestIdentifier()
    }

    /// Set the rights attestation (checkbox toggled).
    public func setAttested(_ attested: Bool) {
        attestationDate = attested ? (attestationDate ?? Date()) : nil
    }

    /// Re-derive the suggested Internet Archive identifier from current fields.
    public func suggestIdentifier() {
        suggestedIdentifier = IdentifierSuggester().suggest(
            title: title,
            author: author,
            narrator: narrator,
            year: Int(editionYearText)
        )
    }

    /// Validate the current archive identifier against the archive's rules.
    public var isArchiveIdentifierValid: Bool {
        archiveIdentifier.isEmpty || IdentifierSuggester().isValid(archiveIdentifier)
    }

    /// Persist the working copy. On success `eligibility` and `didSave` refresh.
    public func save() async {
        do {
            working.metadata.title = trimmed(title)
            working.metadata.subtitle = emptyNil(subtitle)
            working.metadata.author = trimmed(author)
            working.metadata.narrator = trimmed(narrator)
            working.metadata.translator = emptyNil(translator)
            working.metadata.language = language
            working.metadata.description = description
            working.metadata.subjects = subjectsText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            working.metadata.publisher = emptyNil(publisher)
            working.metadata.copyrightYear = Int(copyrightYearText)
            working.metadata.productionYear = Int(productionYearText)
            working.metadata.rightsHolder = emptyNil(rightsHolder)
            working.metadata.isbn = emptyNil(isbn)
            working.metadata.asin = emptyNil(asin)
            working.metadata.archiveIdentifier = emptyNil(archiveIdentifier)

            working.rights.basis = rightsBasis
            working.rights.sourceURL = URL(string: trimmed(sourceURLText))
            working.rights.editionYear = Int(editionYearText)
            working.rights.evidenceNotes = evidenceNotes
            working.rights.attestedBy = emptyNil(attestedBy)
            working.rights.attestedAt = attestationDate

            try await store.save(working)
            eligibility = EligibilityProfile.evaluate(working)
            didSave = true
            error = nil
        } catch {
            self.error = "Failed to save metadata: \(error.localizedDescription)"
        }
    }

    public var workingProject: AudiobookProject { working }

    // MARK: - Private

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func emptyNil(_ s: String) -> String? {
        let t = trimmed(s)
        return t.isEmpty ? nil : t
    }
}
