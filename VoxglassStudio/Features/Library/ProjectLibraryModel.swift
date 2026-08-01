import Foundation
import Observation
import VoxglassCore

@MainActor
@Observable
public final class ProjectLibraryModel {
    public var store: any ProductionStore
    public private(set) var recents: RecentsStore
    public var showOpenPanel = false
    public var pendingProjectURL: URL?
    public private(set) var error: String?
    public var onProjectOpened: ((AudiobookProject, any ProductionStore) -> Void)?
    public var onAutosaveRecoveryAvailable: ((URL) -> Void)?

    private let seed: UITestSeed?
    private let isTestEnvironment: Bool

    public init(
        store: any ProductionStore = InMemoryProductionStore(),
        recents: RecentsStore = RecentsStore(),
        seed: UITestSeed? = nil,
        isTestEnvironment: Bool = false
    ) {
        self.store = store
        self.recents = recents
        self.seed = seed
        self.isTestEnvironment = isTestEnvironment
    }

    public func openProject(at url: URL) async {
        guard url.startAccessingSecurityScopedResource() else {
            error = "Cannot access project at \(url.lastPathComponent)"
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let package = try await ProjectPackage.open(url)
            let sqlite = SQLiteProductionStore(databaseURL: package.databaseURL)
            let project = try await sqlite.load()
            self.store = sqlite
            pendingProjectURL = url
            recents.add(url: url)
            onProjectOpened?(project, sqlite)
            if !package.integrityFindings.isEmpty {
                let blocking = package.integrityFindings.filter { $0.severity == .blocking }.count
                if blocking > 0 {
                    error = "Project opened with \(blocking) blocking integrity finding(s)."
                }
            }
            if package.hasAutosaveRecovery {
                onAutosaveRecoveryAvailable?(url)
            }
        } catch {
            self.error = "Failed to open project: \(error.localizedDescription)"
        }
    }

    public func newProject(title: String, author: String, narrator: String,
                            purpose: ProjectPurpose, destination: DestinationID) -> AudiobookProject {
        let ids = UUIDGenerator()
        let clock = SystemClock()
        let rec = RecordingDefaults()
        let asm = AssemblySettings()
        let profile = ProductionProfile(
            purpose: purpose,
            recording: rec,
            assembly: asm,
            intendedDestination: destination
        )
        let project = AudiobookProject(
            id: ids.next(),
            metadata: BookMetadata(title: title, author: author, narrator: narrator),
            profile: profile,
            chapters: [],
            createdAt: clock.now,
            modifiedAt: clock.now
        )
        return project
    }

    public func createAndPersistProject(
        title: String, author: String, narrator: String,
        purpose: ProjectPurpose, destination: DestinationID,
        at directory: URL
    ) async throws -> AudiobookProject {
        let ids = UUIDGenerator()
        let clock = SystemClock()
        let project = newProject(
            title: title, author: author, narrator: narrator,
            purpose: purpose, destination: destination
        )

        let package = try await ProjectPackage.create(
            title: title, author: author, narrator: narrator,
            at: directory, clock: clock, ids: ids
        )

        let sqlite = SQLiteProductionStore(databaseURL: package.databaseURL)
        try await sqlite.save(project)

        self.store = sqlite
        pendingProjectURL = directory
        recents.add(url: directory)
        return project
    }

    public func seedIfNeeded() async {
        guard isTestEnvironment, let seed else { return }
        switch seed {
        case .empty:
            recents.clear()
        case .onePreviewProject, .oneFlaggedQueue, .watchQueue, .librivoxReady:
            if recents.recentURLs.isEmpty {
                #if DEBUG
                let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("voxglass-test-seed")
                try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let projectURL = tempDir.appendingPathComponent("seed.voxproject")
                try? FileManager.default.removeItem(at: projectURL)
                do {
                    let project = try await createAndPersistProject(
                        title: "Seed Project", author: "Author", narrator: "Narrator",
                        purpose: .personal, destination: .librivox,
                        at: projectURL
                    )
                    onProjectOpened?(project, store)
                } catch {
                    self.error = "Failed to seed project: \(error.localizedDescription)"
                }
                #endif
            }
        }
    }

    public func dismissError() {
        error = nil
    }
}
