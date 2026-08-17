import Foundation
import Observation
import VoxglassCore

@MainActor
@Observable
public final class NewProjectModel {
    public enum WizardStep: Int, CaseIterable {
        case details = 1
        case rights = 2
        case location = 3
    }

    // Step 1 — details (§8.2)
    public var title = ""
    public var author = ""
    public var narrator = ""
    public var language = "en"
    public var purpose: ProjectPurpose = .personal
    public var destination: DestinationID = .librivox

    // Step 2 — rights
    public var rightsBasis: RightsBasis = .personalUseOnly
    public var sourceURLText = ""
    public var editionYearText = ""
    public var evidenceNotes = ""
    public var attest = false

    public var step: WizardStep = .details
    public private(set) var createdProject: AudiobookProject?
    public private(set) var error: String?
    /// Where the wizard would create the package; set only on finish.
    public private(set) var chosenDirectory: URL?

    public var canProceed: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty &&
        !author.trimmingCharacters(in: .whitespaces).isEmpty &&
        !narrator.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// §8.2: a public-domain-community purpose requires a source edition URL.
    public var canEnterRights: Bool {
        canProceed
    }

    public var canFinish: Bool {
        canProceed &&
        (purpose != .publicDomainCommunity || !sourceURLText.trimmingCharacters(in: .whitespaces).isEmpty) &&
        attest
    }

    public init() {}

    public var sourceURL: URL? {
        let trimmed = sourceURLText.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : URL(string: trimmed)
    }

    public var editionYear: Int? {
        Int(editionYearText.trimmingCharacters(in: .whitespaces))
    }

    public func next() {
        switch step {
        case .details: step = .rights
        case .rights: step = .location
        case .location: break
        }
    }

    public func back() {
        switch step {
        case .details: break
        case .rights: step = .details
        case .location: step = .rights
        }
    }

    /// Finishes the wizard (§8.2). Cancelling before this creates nothing on
    /// disk — the package is only created here.
    public func createProject(using library: ProjectLibraryModel, at directory: URL) async {
        do {
            let ids = UUIDGenerator()
            let clock = SystemClock()
            let profile = ProductionProfile(
                purpose: purpose,
                intendedDestination: destination
            )
            let rights = RightsEvidence(
                basis: rightsBasis,
                sourceURL: sourceURL,
                editionYear: editionYear,
                evidenceNotes: evidenceNotes,
                attestedAt: attest ? clock.now : nil,
                attestedBy: attest ? "wizard" : nil
            )
            createdProject = try await library.createAndPersistProject(
                title: title.trimmingCharacters(in: .whitespaces),
                author: author.trimmingCharacters(in: .whitespaces),
                narrator: narrator.trimmingCharacters(in: .whitespaces),
                purpose: purpose,
                destination: destination,
                rights: rights,
                at: directory,
                ids: ids,
                clock: clock
            )
            chosenDirectory = directory
            error = nil
        } catch {
            self.error = "Failed to create project: \(error.localizedDescription)"
        }
    }

    public func dismissError() {
        error = nil
    }
}
