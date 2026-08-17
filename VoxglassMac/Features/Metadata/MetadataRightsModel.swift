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

    // Artwork (§18.1.12, F-28)
    public private(set) var coverOriginal: ArtworkPreview?
    public private(set) var coverOriginalData: Data?
    public private(set) var cover2400: ArtworkPreview?
    /// Validation of the current cover against the destination's `ArtworkRule`.
    public private(set) var artworkIssues: [String] = []
    public private(set) var isGenerating2400 = false

    public var hasCover: Bool { coverOriginal != nil }

    private let store: any ProductionStore
    private let artworkStore: any ArtworkStore
    private var working: AudiobookProject

    public init(
        project: AudiobookProject,
        store: any ProductionStore,
        assets: any ContentAddressedStore,
        artworkStore: any ArtworkStore = InMemoryArtworkStore()
    ) {
        self.working = project
        self.store = store
        self.artworkStore = artworkStore
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
        Task { await loadExistingArtwork() }
    }

    /// Restores any stored artwork so the tab reflects the saved state.
    private func loadExistingArtwork() async {
        if let original = try? await artworkStore.load(role: .coverOriginal) {
            coverOriginal = ArtworkPreview.preview(data: original)
            coverOriginalData = original
        }
        if let derivative = try? await artworkStore.load(role: .cover2400) {
            cover2400 = ArtworkPreview.preview(data: derivative)
        }
        await validateArtwork()
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

    // MARK: - Artwork (§18.1.12)

    /// Loads a cover image, validates it against the destination's artwork
    /// rule, stores the original, and generates the 2400 px derivative that
    /// becomes `working.metadata.coverRef`.
    public func importArtwork(at url: URL) async {
        guard let data = try? Data(contentsOf: url) else {
            artworkIssues = ["Could not read the image file."]
            return
        }
        guard let preview = ArtworkPreview.preview(data: data) else {
            artworkIssues = ["That file is not a readable image."]
            return
        }
        do {
            _ = try await artworkStore.store(data, role: .coverOriginal, ext: url.pathExtension.isEmpty ? "jpg" : url.pathExtension)
            coverOriginal = preview
            coverOriginalData = data
            isGenerating2400 = true
            defer { isGenerating2400 = false }
            if let derivative = ArtworkResizer.resizeTo2400(data: data),
               let derivativePreview = ArtworkPreview.preview(data: derivative) {
                let ref = try await artworkStore.store(derivative, role: .cover2400, ext: "jpg")
                working.metadata.coverRef = ref
                cover2400 = derivativePreview
            } else {
                artworkIssues = ["Could not generate the 2400 px derivative."]
            }
            await validateArtwork()
        } catch {
            self.error = "Failed to store artwork: \(error.localizedDescription)"
        }
    }

    public func removeArtwork() async {
        try? await artworkStore.remove(role: .coverOriginal)
        try? await artworkStore.remove(role: .cover2400)
        working.metadata.coverRef = nil
        coverOriginal = nil
        coverOriginalData = nil
        cover2400 = nil
        await validateArtwork()
    }

    /// The destination rule the cover must satisfy (from the working project's
    /// intended destination).
    public var artworkRule: ArtworkRule {
        DestinationProfile.profile(for: working.profile.intendedDestination).artwork
    }

    private func validateArtwork() async {
        artworkIssues = []
        guard let cover = coverOriginal else {
            if case .requiredSquare = artworkRule {
                artworkIssues.append("This destination requires cover art.")
            }
            return
        }
        switch artworkRule {
        case .none:
            break
        case .optionalSquare(let minPx), .requiredSquare(let minPx, _, _):
            let shortest = min(cover.pixelWidth, cover.pixelHeight)
            if cover.pixelWidth != cover.pixelHeight {
                artworkIssues.append("Cover is \(cover.pixelWidth)×\(cover.pixelHeight); this destination requires a square image.")
            } else if shortest < minPx {
                artworkIssues.append("Cover is \(shortest) px on the short side; this destination needs at least \(minPx) px.")
            }
        }
    }

    // MARK: - Private

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func emptyNil(_ s: String) -> String? {
        let t = trimmed(s)
        return t.isEmpty ? nil : t
    }
}
